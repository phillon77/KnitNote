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

wait_for_ready() {
  local udid="$1"
  for _ in {1..20}; do
    if xcrun simctl spawn "$udid" log show --last 10s --style compact \
      --predicate 'eventMessage CONTAINS "storeScreenshot.ready"' 2>/dev/null | grep -q 'storeScreenshot.ready'; then
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for storeScreenshot.ready on $udid" >&2
  return 1
}

capture_simulator() {
  local platform="$1" scene="$2" filename="$3"
  local udid app bundle
  case "$platform" in
    iphone) udid="$IPHONE_UDID"; app="$IOS_APP"; bundle="com.phillon.KnitNote" ;;
    ipad) udid="$IPAD_UDID"; app="$IOS_APP"; bundle="com.phillon.KnitNote" ;;
    watch) udid="$WATCH_UDID"; app="$WATCH_APP"; bundle="com.phillon.KnitNote.watch" ;;
    *) echo "unsupported simulator platform: $platform" >&2; return 2 ;;
  esac

  [[ -d "$app" ]] || { echo "missing built app: $app" >&2; return 2; }
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl install "$udid" "$app"
  xcrun simctl status_bar "$udid" override \
    --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" \
    -storeScreenshotMode YES \
    -storeScreenshotScene "$scene" \
    -storeScreenshotLanguage "$LOCALE" >/dev/null
  wait_for_ready "$udid"
  mkdir -p "$(dirname "$filename")"
  xcrun simctl io "$udid" screenshot "$filename"
}

capture_mac() {
  local scene="$1" filename="$2"
  [[ -d "$MAC_APP" ]] || { echo "missing built app: $MAC_APP" >&2; return 2; }
  [[ -n "${MAC_CAPTURE_RECT:-}" ]] || {
    echo "MAC_CAPTURE_RECT (x,y,width,height for a 16:10 window) is required" >&2
    return 2
  }
  pkill -x KnitNote >/dev/null 2>&1 || true
  open -n "$MAC_APP" --args \
    -storeScreenshotMode YES \
    -storeScreenshotScene "$scene" \
    -storeScreenshotLanguage "$LOCALE"
  sleep 3
  mkdir -p "$(dirname "$filename")"
  screencapture -x -R "$MAC_CAPTURE_RECT" "$filename"
}

require_variable IPHONE_UDID
require_variable IPAD_UDID
require_variable WATCH_UDID

while IFS=$'\t' read -r platform scene filename; do
  output="$ROOT/Raw/$LOCALE/$platform/$filename"
  echo "Capturing $LOCALE $platform $scene"
  if [[ "$platform" == "mac" ]]; then
    capture_mac "$scene" "$output"
  else
    capture_simulator "$platform" "$scene" "$output"
  fi
done < <(python3 - "$MANIFEST" "$LOCALE" <<'PY'
import json, sys
manifest, locale = sys.argv[1:]
for frame in json.load(open(manifest, encoding="utf-8"))["frames"]:
    if frame["locale"] == locale:
        print(frame["platform"], frame["scene"], frame["filename"], sep="\t")
PY
)

echo "Raw captures complete for $LOCALE"
