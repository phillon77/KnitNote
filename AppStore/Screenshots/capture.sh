#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$ROOT/manifest.json"
LOCALE="${1:-}"

if [[ "$LOCALE" != "zh-Hant" && "$LOCALE" != "en" ]]; then
  echo "usage: $0 zh-Hant|en" >&2
  exit 2
fi

IOS_APP="${IOS_APP:-/tmp/KnitNoteScreenshots/Build/Products/Debug-iphonesimulator/KnitNote.app}"
WATCH_APP="${WATCH_APP:-/tmp/KnitNoteScreenshotsWatch/Build/Products/Debug-watchsimulator/KnitNoteWatch.app}"
MAC_APP="${MAC_APP:-/tmp/KnitNoteScreenshotsMac/Build/Products/Debug/KnitNote.app}"

require_variable() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name must identify a dedicated KnitNote screenshot simulator" >&2
    exit 2
  fi
}

verify_dedicated_device() {
  local udid="$1" platform="$2"
  python3 - "$udid" "$platform" <<'PY'
import json, subprocess, sys
udid, platform = sys.argv[1:]
payload = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
device = next((item for values in payload["devices"].values() for item in values if item.get("udid") == udid), None)
if device is None or not device.get("isAvailable", False):
    raise SystemExit(f"unavailable screenshot simulator: {udid}")
name = device.get("name", "")
if not name.startswith("KnitNote Store"):
    raise SystemExit(f"refusing non-dedicated simulator {name!r}; name must start with 'KnitNote Store'")
identifier = device.get("deviceTypeIdentifier", "")
required = {
    "iphone": ("iPhone-17-Pro-Max",),
    "ipad": ("iPad-Pro-13-inch-M4", "iPad-Pro-13-inch-M5"),
    "watch": ("Apple-Watch-Series-10-46mm", "Apple-Watch-Series-11-46mm"),
}[platform]
if not any(value in identifier for value in required):
    raise SystemExit(f"wrong {platform} screenshot device: {identifier or name}")
PY
}

prepare_device() {
  local udid="$1" locale="$2"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl erase "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLanguages -array "$locale"
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLocale "$locale"
}

wait_for_ready() {
  local udid="$1" token="$2"
  for _ in {1..20}; do
    if xcrun simctl spawn "$udid" log show --last 30s --style compact \
      --predicate "eventMessage CONTAINS '$token'" 2>/dev/null | grep -q "$token"; then
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for storeScreenshot.ready on $udid" >&2
  return 1
}

wait_for_mac_ready() {
  local token="$1"
  for _ in {1..20}; do
    if /usr/bin/log show --last 30s --style compact \
      --predicate "eventMessage CONTAINS '$token'" 2>/dev/null | grep -q "$token"; then
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for storeScreenshot.ready.$token on macOS" >&2
  return 1
}

verify_dimensions() {
  local file="$1" expected_width="$2" expected_height="$3"
  local actual_width actual_height
  actual_width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
  actual_height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ {print $2}')"
  if [[ "$actual_width" != "$expected_width" || "$actual_height" != "$expected_height" ]]; then
    echo "wrong raw dimensions for $file: ${actual_width}x${actual_height}, expected ${expected_width}x${expected_height}" >&2
    return 1
  fi
}

capture_simulator() {
  local platform="$1" scene="$2" filename="$3" width="$4" height="$5"
  local udid app bundle
  local token
  token="$(uuidgen)"
  case "$platform" in
    iphone) udid="$IPHONE_UDID"; app="$IOS_APP"; bundle="com.phillon.KnitNote" ;;
    ipad) udid="$IPAD_UDID"; app="$IOS_APP"; bundle="com.phillon.KnitNote" ;;
    watch) udid="$WATCH_UDID"; app="$WATCH_APP"; bundle="com.phillon.KnitNote.watch" ;;
    *) echo "unsupported simulator platform: $platform" >&2; return 2 ;;
  esac

  [[ -d "$app" ]] || { echo "missing built app: $app" >&2; return 2; }
  xcrun simctl install "$udid" "$app"
  if [[ "$platform" == "watch" ]]; then
    xcrun simctl status_bar "$udid" override --time 9:41
  else
    xcrun simctl status_bar "$udid" override \
      --time 9:41 --batteryState charged --batteryLevel 100 \
      --wifiBars 3 --cellularBars 4
  fi
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" \
    -storeScreenshotMode YES \
    -storeScreenshotScene "$scene" \
    -storeScreenshotLanguage "$LOCALE" \
    -storeScreenshotToken "$token" >/dev/null
  wait_for_ready "$udid" "$token"
  mkdir -p "$(dirname "$filename")"
  xcrun simctl io "$udid" screenshot "$filename"
  verify_dimensions "$filename" "$width" "$height"
}

capture_mac() {
  local scene="$1" filename="$2" width="$3" height="$4"
  local token
  token="$(uuidgen)"
  [[ -d "$MAC_APP" ]] || { echo "missing built app: $MAC_APP" >&2; return 2; }
  if pgrep -x KnitNote >/dev/null; then
    echo "Close the normal KnitNote app before isolated Mac capture" >&2
    return 2
  fi
  "$MAC_APP/Contents/MacOS/KnitNote" \
    -storeScreenshotMode YES \
    -storeScreenshotScene "$scene" \
    -storeScreenshotLanguage "$LOCALE" \
    -storeScreenshotToken "$token" >/tmp/knitnote-store-screenshot-mac.log 2>&1 &
  local app_pid=$!
  trap "kill '$app_pid' >/dev/null 2>&1 || true; wait '$app_pid' 2>/dev/null || true" EXIT
  local window_configured=0
  for _ in {1..20}; do
    if osascript - "$app_pid" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set targetPID to item 1 of argv as integer
  tell application "System Events"
    tell first application process whose unix id is targetPID
      set frontmost to true
      set position of window 1 to {20, 50}
      set size of window 1 to {1440, 900}
    end tell
  end tell
end run
APPLESCRIPT
    then
      window_configured=1
      break
    fi
    sleep 0.5
  done
  [[ "$window_configured" == 1 ]] || { echo "unable to size the isolated KnitNote window" >&2; return 1; }
  wait_for_mac_ready "$token"
  local window_id
  window_id="$(swift -module-cache-path /tmp/knitnote-screenshot-swift-cache "$ROOT/mac_window_id.swift" "$app_pid")"
  [[ -n "$window_id" ]] || { echo "unable to identify isolated KnitNote window" >&2; return 1; }
  mkdir -p "$(dirname "$filename")"
  screencapture -x -o -l "$window_id" "$filename"
  verify_dimensions "$filename" "$width" "$height"
  kill "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" 2>/dev/null || true
  trap - EXIT
}

require_variable IPHONE_UDID
require_variable IPAD_UDID
require_variable WATCH_UDID
verify_dedicated_device "$IPHONE_UDID" iphone
verify_dedicated_device "$IPAD_UDID" ipad
verify_dedicated_device "$WATCH_UDID" watch
prepare_device "$IPHONE_UDID" "$LOCALE"
prepare_device "$IPAD_UDID" "$LOCALE"
prepare_device "$WATCH_UDID" "$LOCALE"

while IFS=$'\t' read -r platform scene filename width height; do
  output="$ROOT/Raw/$LOCALE/$platform/$filename"
  echo "Capturing $LOCALE $platform $scene"
  if [[ "$platform" == "mac" ]]; then
    capture_mac "$scene" "$output" "$width" "$height"
  else
    capture_simulator "$platform" "$scene" "$output" "$width" "$height"
  fi
done < <(python3 - "$MANIFEST" "$LOCALE" <<'PY'
import json, sys
manifest, locale = sys.argv[1:]
for frame in json.load(open(manifest, encoding="utf-8"))["frames"]:
    if frame["locale"] == locale:
        print(frame["platform"], frame["scene"], frame["filename"], frame["width"], frame["height"], sep="\t")
PY
)

echo "Raw captures complete for $LOCALE"
