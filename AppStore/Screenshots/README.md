# KnitNote App Store screenshots

This directory produces the 28 approved screenshots (14 Traditional Chinese and 14 English) from deterministic synthetic app data. It never reads the live Application Support store and never uses family photos.

## One-time setup

1. Install Python dependencies into a temporary virtual environment:

   ```bash
   python3 -m venv /tmp/knitnote-screenshots-venv
   /tmp/knitnote-screenshots-venv/bin/python -m pip install --upgrade pip
   /tmp/knitnote-screenshots-venv/bin/pip install -r AppStore/Screenshots/requirements.txt
   ```

2. Create dedicated iPhone 17 Pro Max, iPad Pro 13-inch (M4/M5), and Apple Watch Series 10/11 46mm simulators. Their names must begin with `KnitNote Store` (for example, `KnitNote Store iPhone`). The capture script refuses any other simulator and erases these dedicated devices before each locale, so never point the variables at a personal test simulator.

3. Build the Debug screenshot binaries:

   ```bash
   xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath /tmp/KnitNoteScreenshots build
   xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug \
     -destination 'generic/platform=watchOS Simulator' \
     -derivedDataPath /tmp/KnitNoteScreenshotsWatch build
   xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
     -destination 'generic/platform=macOS' \
     -derivedDataPath /tmp/KnitNoteScreenshotsMac build
   ```

## Capture and compose

Export the three dedicated simulator identifiers. Mac capture launches a separate screenshot process, sizes only its KnitNote window to 16:10, identifies that window by PID, and captures it without the desktop. Every raw device capture is checked against the manifest before composition; wrong models, dimensions, status-bar setup, languages, or readiness tokens stop the run.

```bash
export IPHONE_UDID='<dedicated iPhone 17 Pro Max UDID>'
export IPAD_UDID='<dedicated iPad Pro 13-inch UDID>'
export WATCH_UDID='<dedicated Apple Watch 46mm UDID>'
AppStore/Screenshots/capture.sh zh-Hant
AppStore/Screenshots/capture.sh en
/tmp/knitnote-screenshots-venv/bin/python AppStore/Screenshots/compose.py AppStore/Screenshots/manifest.json
/tmp/knitnote-screenshots-venv/bin/python AppStore/Screenshots/validate.py AppStore/Screenshots/manifest.json
```

To check all 28 definitions before raw captures exist, append `--manifest-only`.

Raw captures are written under `Raw/`. Final opaque RGB files are written under `Generated/<locale>/<platform>/`. The composition keeps at least 79% of every frame as real UI, with the headline and restrained watercolor accents limited to the outer margin.

## Review gate

Before upload, inspect every generated frame at 100% and verify:

- all UI and headline text match the selected language;
- status bars are deterministic and no control, pattern, counter, or note is covered;
- no personal names, email addresses, local file paths, photos, or GPS metadata appear;
- the screenshot is a faithful representation of the shipped app;
- `validate.py` prints `28 screenshots valid`.

`Raw/` is transient and must not be committed. Commit final `Generated/` files only after visual approval.
