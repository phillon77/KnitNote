#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${CALC_SCREENSHOT_MANIFEST:-$SCRIPT_ROOT/manifest.json}"
OUTPUT_ROOT="$(cd "$(dirname "$MANIFEST")" && pwd)"
APP="${CALC_SCREENSHOT_APP:-/tmp/KnittingCalculatorScreenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app}"
PYTHON="${SCREENSHOT_PYTHON:-python3}"
BUNDLE_ID="com.phillon.KnittingCalculator"
LOCALE="${1:-}"

if [[ "$LOCALE" != "zh-Hant" && "$LOCALE" != "en" ]]; then
  echo "usage: $0 zh-Hant|en" >&2
  exit 2
fi

require_variable() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name must identify a dedicated Knitting Calculator screenshot simulator" >&2
    exit 2
  fi
}

verify_capture_environment() {
  if ! "$PYTHON" - "$CALC_IPHONE_UDID" "$CALC_IPAD_UDID" "$MANIFEST" <<'PY'
import json
import subprocess
import sys

iphone_udid, ipad_udid, manifest_path = sys.argv[1:]
environment = {
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "iphoneDeviceTypeIdentifier": (
        "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max"
    ),
    "ipadDeviceTypeIdentifier": (
        "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
    ),
    "statusBarTime": "9:41",
    "cropSystemDate": True,
}
expected_devices = {
    "iphone": (
        iphone_udid,
        "Knitting Calculator Store iPhone",
        environment["iphoneDeviceTypeIdentifier"],
    ),
    "ipad": (
        ipad_udid,
        "Knitting Calculator Store iPad",
        environment["ipadDeviceTypeIdentifier"],
    ),
}

try:
    with open(manifest_path, encoding="utf-8") as manifest_file:
        payload = json.load(manifest_file)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid screenshot manifest: {error}")

if not isinstance(payload, dict) or payload.get("schemaVersion") != 2:
    raise SystemExit("invalid screenshot manifest: schemaVersion must be 2")
if payload.get("captureEnvironment") != environment:
    raise SystemExit("invalid screenshot manifest: captureEnvironment must pin the approved environment")

payload = json.loads(
    subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"])
)
devices = payload.get("devices", {})
for platform, (udid, expected_name, expected_type) in expected_devices.items():
    matches = [
        (runtime, item)
        for runtime, runtime_devices in devices.items()
        for item in runtime_devices
        if item.get("udid") == udid
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"screenshot {platform} simulator must resolve exactly once: {udid}"
        )
    runtime, device = matches[0]
    if runtime != environment["runtimeIdentifier"]:
        raise SystemExit(
            f"wrong {platform} screenshot runtime: {runtime}; "
            f"expected {environment['runtimeIdentifier']}"
        )
    if device.get("isAvailable") is not True:
        raise SystemExit(f"unknown or unavailable screenshot simulator: {udid}")
    if device.get("name") != expected_name:
        raise SystemExit(
            f"refusing unexpected screenshot simulator {device.get('name')!r}; "
            f"expected {expected_name!r}"
        )
    if device.get("deviceTypeIdentifier") != expected_type:
        raise SystemExit(
            f"wrong {platform} screenshot device: "
            f"{device.get('deviceTypeIdentifier') or device.get('name')}"
        )
PY
  then
    exit 2
  fi
}

prepare_device() {
  local udid="$1"
  local platform="$2"
  local region
  case "$LOCALE" in
    zh-Hant) region="zh_TW" ;;
    en) region="en_US" ;;
  esac

  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl erase "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLanguages -array "$LOCALE"
  xcrun simctl spawn "$udid" defaults write NSGlobalDomain AppleLocale "$region"

  if [[ "$platform" == "iphone" ]]; then
    xcrun simctl status_bar "$udid" override \
      --time 9:41 --batteryState charged --batteryLevel 100 \
      --wifiBars 3 --cellularBars 4
  else
    xcrun simctl status_bar "$udid" override \
      --time 9:41 --batteryState charged --batteryLevel 100 \
      --wifiBars 3
  fi
}

wait_for_ready() {
  local udid="$1"
  local token="$2"
  local marker="storeScreenshot.ready.$token"
  local attempts="${SCREENSHOT_READY_ATTEMPTS:-30}"
  local attempt
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    if xcrun simctl spawn "$udid" log show --last 30s --style compact \
      --predicate "eventMessage CONTAINS '$marker'" 2>/dev/null |
      grep -Fq "$marker"; then
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for $marker on $udid" >&2
  return 1
}

verify_dimensions() {
  local path="$1"
  local expected_width="$2"
  local expected_height="$3"
  "$PYTHON" - "$path" "$expected_width" "$expected_height" <<'PY'
import sys
from PIL import Image

path, expected_width, expected_height = sys.argv[1:]
with Image.open(path) as image:
    actual = image.size
expected = (int(expected_width), int(expected_height))
if actual != expected:
    raise SystemExit(
        f"wrong raw dimensions for {path}: {actual[0]}x{actual[1]}, "
        f"expected {expected[0]}x{expected[1]}"
    )
PY
}

capture_frame() {
  local platform="$1"
  local scene="$2"
  local filename="$3"
  local width="$4"
  local height="$5"
  local udid
  local token
  local output

  case "$platform" in
    iphone) udid="$CALC_IPHONE_UDID" ;;
    ipad) udid="$CALC_IPAD_UDID" ;;
    *) echo "unsupported screenshot platform: $platform" >&2; return 2 ;;
  esac

  token="$(uuidgen)"
  output="$OUTPUT_ROOT/Raw/$LOCALE/$platform/$filename"
  mkdir -p "$(dirname "$output")"
  xcrun simctl install "$udid" "$APP"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$BUNDLE_ID" \
    -storeScreenshotMode YES \
    -storeScreenshotScene "$scene" \
    -storeScreenshotLanguage "$LOCALE" \
    -storeScreenshotToken "$token" >/dev/null
  wait_for_ready "$udid" "$token"
  sleep "${SCREENSHOT_SETTLE_SECONDS:-2}"
  xcrun simctl io "$udid" screenshot "$output"
  verify_dimensions "$output" "$width" "$height"
}

require_variable CALC_IPHONE_UDID
require_variable CALC_IPAD_UDID
[[ -f "$MANIFEST" ]] || { echo "missing screenshot manifest: $MANIFEST" >&2; exit 2; }
[[ -d "$APP" ]] || { echo "missing built app: $APP" >&2; exit 2; }

ROWS_FILE="$(mktemp "${TMPDIR:-/tmp}/knitting-calculator-frames.XXXXXX")"
trap 'rm -f "$ROWS_FILE"' EXIT
if ! "$PYTHON" - "$MANIFEST" "$LOCALE" >"$ROWS_FILE" <<'PY'
import json
import sys

manifest_path, locale = sys.argv[1:]


def safe_component(value, field):
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or value.startswith("/")
        or "/" in value
        or "\\" in value
        or any(character in value for character in "\t\r\n")
    ):
        raise ValueError(f"{field} must be a single safe path component")


try:
    with open(manifest_path, encoding="utf-8") as manifest_file:
        payload = json.load(manifest_file)
    expected_environment = {
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "iphoneDeviceTypeIdentifier": (
            "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max"
        ),
        "ipadDeviceTypeIdentifier": (
            "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
        ),
        "statusBarTime": "9:41",
        "cropSystemDate": True,
    }
    approved_matrix = {
        (locale, platform, scene, filename)
        for locale in ("zh-Hant", "en")
        for platform, scenes in {
            "iphone": (
                ("home", "01-home.png"),
                ("gauge", "02-gauge.png"),
                ("adjustment", "03-adjustment.png"),
                ("privacy", "04-privacy.png"),
                ("promotion", "05-knitnote.png"),
            ),
            "ipad": (
                ("home", "01-home.png"),
                ("gauge", "02-gauge.png"),
                ("adjustment", "03-adjustment.png"),
                ("privacyPromotion", "04-privacy-knitnote.png"),
            ),
        }.items()
        for scene, filename in scenes
    }
    if (
        not isinstance(payload, dict)
        or payload.get("schemaVersion") != 2
        or payload.get("captureEnvironment") != expected_environment
        or not isinstance(payload.get("frames"), list)
    ):
        raise ValueError("payload must pin the approved captureEnvironment and frames array")
    frames = payload["frames"]
    expected_sizes = {"iphone": (1284, 2778), "ipad": (2064, 2752)}
    selected = []
    actual_matrix = set()
    for index, frame in enumerate(frames, 1):
        if not isinstance(frame, dict):
            raise ValueError(f"frame {index} must be an object")
        for field in ("locale", "platform", "filename"):
            safe_component(frame.get(field), field)
        if frame["platform"] not in {"iphone", "ipad"}:
            raise ValueError(f"frame {index} has unsupported platform")
        for field in ("scene", "filename"):
            if not isinstance(frame.get(field), str) or not frame[field]:
                raise ValueError(f"frame {index} has invalid {field}")
        width, height = frame.get("width"), frame.get("height")
        if (
            not isinstance(width, int)
            or isinstance(width, bool)
            or not isinstance(height, int)
            or isinstance(height, bool)
            or width <= 0
            or height <= 0
        ):
            raise ValueError(f"frame {index} has invalid dimensions")
        if (width, height) != expected_sizes[frame["platform"]]:
            raise ValueError(f"frame {index} has incorrect dimensions")
        actual_matrix.add((frame["locale"], frame["platform"], frame["scene"], frame["filename"]))
        if frame["locale"] == locale:
            selected.append(frame)
    if len(frames) != len(approved_matrix) or actual_matrix != approved_matrix:
        raise ValueError("manifest scene and filename pairs are not the approved capture matrix")
    if not selected:
        raise ValueError(f"manifest contains no frames for locale {locale}")
    for frame in selected:
        print(
            frame["platform"],
            frame["scene"],
            frame["filename"],
            frame["width"],
            frame["height"],
            sep="\t",
        )
except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid screenshot manifest: {error}")
PY
then
  exit 2
fi

verify_capture_environment
prepare_device "$CALC_IPHONE_UDID" iphone
prepare_device "$CALC_IPAD_UDID" ipad

while IFS=$'\t' read -r platform scene filename width height; do
  echo "Capturing $LOCALE $platform $scene"
  capture_frame "$platform" "$scene" "$filename" "$width" "$height"
done <"$ROWS_FILE"

echo "Raw captures complete for $LOCALE"
