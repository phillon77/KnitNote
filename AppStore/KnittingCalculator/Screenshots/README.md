# Knitting Calculator App Store screenshots

This package captures deterministic DEBUG-only scenes from two dedicated,
disposable simulators, then places the real UI into the approved B-style
watercolor frame. The capture script erases both simulators for every locale;
never supply a personal simulator.

`manifest.json` pins the public iOS runtime and device-type identifiers, the
fixed 9:41 status-bar time, and the iPad date crop policy. Before any shutdown
or erase, `capture.sh` validates the full locale/platform scene matrix and
resolves both supplied UDIDs exactly once from `simctl`; it rejects a runtime,
device type, name, availability, or duplicate mismatch.

## One-time setup

Create the exact dedicated devices:

```bash
xcrun simctl create \
  'Knitting Calculator Store iPhone' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl create \
  'Knitting Calculator Store iPad' \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

Confirm that the local simulator inventory exposes the same public identifiers
before exporting the two creation-command UDIDs:

```bash
xcrun simctl list devices --json
```

Create an isolated Pillow environment:

```bash
python3 -m venv /tmp/knitting-calculator-screenshots-venv
/tmp/knitting-calculator-screenshots-venv/bin/pip install \
  -r AppStore/KnittingCalculator/Screenshots/requirements.txt
```

## Build, capture, compose, and validate

Build the DEBUG simulator app at the path expected by `capture.sh`:

```bash
xcodebuild \
  -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnittingCalculatorScreenshots \
  CODE_SIGNING_ALLOWED=NO build
```

Export the identifiers returned by the creation commands, select the isolated
Python environment for image checks, and capture both languages:

```bash
export CALC_IPHONE_UDID='<dedicated iPhone 13 Pro Max UDID>'
export CALC_IPAD_UDID='<dedicated iPad Pro 13-inch UDID>'
export SCREENSHOT_PYTHON=/tmp/knitting-calculator-screenshots-venv/bin/python
AppStore/KnittingCalculator/Screenshots/capture.sh zh-Hant
AppStore/KnittingCalculator/Screenshots/capture.sh en
```

The compositor consistently crops away the date-bearing system region; do not
edit a calendar or date string in image pixels.

Compose the opaque PNG assets and validate the complete package:

```bash
/tmp/knitting-calculator-screenshots-venv/bin/python \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
/tmp/knitting-calculator-screenshots-venv/bin/python \
  AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
```

Raw captures are written to `Raw/<locale>/<platform>/`, final assets to
`Generated/<locale>/<platform>/`, and each locale also receives a
`Generated/<locale>/contact-sheet.png` in manifest order.

## Static verification

```bash
bash -n AppStore/KnittingCalculator/Screenshots/capture.sh
/tmp/knitting-calculator-screenshots-venv/bin/python -m py_compile \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/validate.py
/tmp/knitting-calculator-screenshots-venv/bin/python -m unittest \
  AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py
/tmp/knitting-calculator-screenshots-venv/bin/python \
  AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json --manifest-only
```
