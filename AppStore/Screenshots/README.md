# KnitNote App Store screenshots

This directory produces 168 screenshot definitions: 14 each for English, Traditional Chinese, Simplified Chinese, German, French, Japanese, Norwegian Bokmål, Swedish, Finnish, Danish, Korean, and Greek. Captures use deterministic synthetic app data, never read the live Application Support store, and never use family photos. Every release locale reuses the same English user-authored fixture text while the app chrome follows the selected locale, so the tooling does not imply that language switching translates user data.

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
   CANDIDATE_COMMIT="$(git rev-parse HEAD)"
   xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath /tmp/KnitNoteScreenshots \
     KNITNOTE_SOURCE_REVISION="$CANDIDATE_COMMIT" build
   xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug \
     -destination 'generic/platform=watchOS Simulator' \
     -derivedDataPath /tmp/KnitNoteScreenshotsWatch \
     KNITNOTE_SOURCE_REVISION="$CANDIDATE_COMMIT" build
   xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
     -destination 'generic/platform=macOS' \
     -derivedDataPath /tmp/KnitNoteScreenshotsMac \
     KNITNOTE_SOURCE_REVISION="$CANDIDATE_COMMIT" build
   ```

## Capture and compose

Export the three dedicated simulator identifiers. Mac capture launches a separate screenshot process, sizes only its KnitNote window to 16:10, identifies that window by PID, and captures it without the desktop. Every raw device capture is checked against the manifest before composition; wrong models, dimensions, status-bar setup, languages, or readiness tokens stop the run.

```bash
export IPHONE_UDID='<dedicated iPhone 17 Pro Max UDID>'
export IPAD_UDID='<dedicated iPad Pro 13-inch UDID>'
export WATCH_UDID='<dedicated Apple Watch 46mm UDID>'
CANDIDATE_COMMIT="$(git rev-parse HEAD)"
CANDIDATE_VERSION='1.4.1'
CANDIDATE_BUILD='8'
AppStore/Screenshots/capture.sh --all-locales "$CANDIDATE_COMMIT" "$CANDIDATE_VERSION" "$CANDIDATE_BUILD"
/tmp/knitnote-screenshots-venv/bin/python AppStore/Screenshots/compose.py AppStore/Screenshots/manifest.json
/tmp/knitnote-screenshots-venv/bin/python AppStore/Screenshots/validate.py \
  AppStore/Screenshots/manifest.json \
  --expected-commit "$CANDIDATE_COMMIT" \
  --expected-version "$CANDIDATE_VERSION" \
  --expected-build "$CANDIDATE_BUILD"
```

The all-locales command refuses a dirty or different revision and requires canonical identifiers plus exact `1.4.1 (8)` and `KnitNoteSourceRevision` in the iOS, Watch, and Mac products. It hashes all three executables before capture, rechecks product identity and hashes afterward, binds all 168 raw files and the exact manifest bytes, then atomically publishes `Raw/` with its provenance. Composition authenticates that evidence, renders into staging, and atomically publishes `Generated/` with durable provenance and hashes for all 168 upload images. Full validation independently requires the expected immutable commit, version, and build, so a self-consistent screenshot set from an older candidate is rejected. A failed capture or composition preserves the prior complete directory.

`KNITNOTE_SCREENSHOT_CAPTURE_RUNNER` is a test-only fault-injection seam. Production capture rejects it; repository tests must opt in with `capture.sh --test-only`.

To check all 168 definitions before raw captures exist, append `--manifest-only`.

Raw captures are written under `Raw/`. Final opaque RGB files are written under `Generated/<locale>/<platform>/`. The composition keeps at least 79% of every frame as real UI, with the headline and restrained watercolor accents limited to the outer margin.

## Review gate

Before upload, inspect every generated frame at 100% and verify:

- all UI and headline text match the selected language;
- status bars are deterministic and no control, pattern, counter, or note is covered;
- no personal names, email addresses, local file paths, photos, or GPS metadata appear;
- the screenshot is a faithful representation of the shipped app;
- `validate.py` prints `168 screenshots valid`.

`Raw/` is transient and must not be committed. Keep `Generated/candidate-provenance.json` beside any approved final images; it retains the authenticated raw inventory and product evidence, so full validation can still verify the final 168-image set after `Raw/` is removed. Commit final `Generated/` files only after visual approval.
