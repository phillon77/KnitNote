# Knitting Calculator Build 2 Release Hardening Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a reproducible `1.0.0 (2)` Knitting Calculator candidate whose screenshots show only real Release-reachable UI, bind the uploaded artifact to one immutable source SHA, update the App Store Connect primary language and screenshots, and prepare a local clean release branch with no private device or tester identifiers.

**Architecture:** Keep screenshot launching under `#if DEBUG`, but replace its UI-removal flags with explicit navigation, deterministic user-enterable drafts, and real scroll positions. Treat repository metadata, screenshot manifest, build provenance, physical-device evidence, and App Store Connect read-back as separate gates. Create the clean release branch only after the exact Build 2 candidate and remote configuration pass, then reproduce the verified calculator net change as one sanitized commit on the approved mainline baseline.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XcodeGen, XCTest/xcodebuild, Bash, Python 3 unittest, Pillow, `simctl`, `xcodebuild`, App Store distribution signing, App Store Connect web UI.

## Global Constraints

- Work only in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitting-calculator-independent-project`, except for Task 6's read/build-only detached candidate worktree and Task 8's explicit clean release worktree.
- Preserve the current branch `codex/knitting-calculator-independent-project` as the local backup. Do not rewrite, delete, merge, or push it.
- Preserve these user-owned untracked paths and never stage them:
  - `.superpowers/brainstorm/`
  - `AppStore/KnittingCalculator/Screenshots/Raw/`
  - `AppStore/KnittingCalculator/Screenshots/__pycache__/`
  - `AppStore/Verification/__pycache__/`
- Do not click **Add for Review**, create a review submission, submit, release, publish the App, merge, or push.
- The user has authorized only these remote changes: upload and attach Build `1.0.0 (2)`, set English (U.S.) as primary language, and replace the 18 screenshots with the verified package.
- Stop immediately if Git SHA, archive, IPA, installed build, App Store Connect build, locale, screenshot order, or physical-device observations disagree.
- Use TDD for every source or script behavior change: add a failing test, run it and confirm the intended failure, implement the smallest fix, then rerun the focused test.
- The existing unrelated KnitNote keyword-duplication failure is an approved Plan B exception. Record a full-suite result as `855/856` if and only if that remains the sole failure; never report the full suite as passing.
- Do not write tester email addresses, device UDIDs, CoreDevice IDs, provisioning UUIDs, app-container paths, or process IDs into tracked evidence.

---

### Task 1: Make every screenshot scene truthfully Release-reachable

**Files:**
- Modify: `KnittingCalculatorTests/CalculatorStoreScreenshotModeTests.swift`
- Modify: `KnittingCalculator/App/CalculatorStoreScreenshotMode.swift`
- Modify: `KnittingCalculator/App/CalculatorStoreScreenshotRootView.swift`
- Modify: `KnittingCalculator/Home/CalculatorHomeView.swift`
- Modify: `KnittingCalculator/Settings/CalculatorSettingsView.swift`
- Modify: `KnittingCalculator/Adjustment/AdjustmentCalculatorScreen.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift`

**Step 1: Add failing behavior and integration-contract tests**

- Replace the expectations that `.home` and `.privacy` set `showsKnitNotePromotion: false`.
- Define presentation state only in terms of actions a user can perform:
  - destination;
  - deterministic draft values;
  - adjustment tab and detail expansion;
  - a semantic scroll target such as `.top`, `.privacy`, or `.promotion`.
- Add observable behavior tests that render or inspect the screenshot
  presentation result and prove:
  - Home and Settings screenshot scenes retain the normal Release promotion;
  - screenshot root uses the same default Home and Settings hierarchy as Release;
  - scroll targets change only the visible position, never whether
    `KnitNotePromotionCard` exists.
- Do not test these requirements by searching Swift source text.

**Step 2: Run the focused tests and confirm RED**

Run:

```bash
xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:KnittingCalculatorTests/CalculatorStoreScreenshotModeTests
swift test --filter KnittingCalculatorStoreScreenshotContractTests
```

Expected: failures reference the current `showsKnitNotePromotion` presentation behavior and conditional card rendering.

**Step 3: Implement the smallest truth-preserving presentation model**

- Remove `showsKnitNotePromotion` from `CalculatorStoreScreenshotPresentation`.
- Remove the conditional-promotion initializers and branches from Home and Settings.
- Keep all screenshot-only compilation under `#if DEBUG`.
- Add stable anchors to the actual scrollable Release UI and have screenshot scenes scroll to them without changing the hierarchy.
- Keep `.promotion` on the real Home promotion card and `.privacyPromotion` on the real Settings promotion/support region.
- Preserve `.adjustment` as `.acrossRows` with expanded details because both are normal user actions.

**Step 4: Run focused tests and confirm GREEN**

Repeat the two commands from Step 2. Expected: all focused tests pass.

**Step 5: Commit**

```bash
git add KnittingCalculatorTests/CalculatorStoreScreenshotModeTests.swift \
  KnittingCalculator/App/CalculatorStoreScreenshotMode.swift \
  KnittingCalculator/App/CalculatorStoreScreenshotRootView.swift \
  KnittingCalculator/Home/CalculatorHomeView.swift \
  KnittingCalculator/Settings/CalculatorSettingsView.swift \
  KnittingCalculator/Adjustment/AdjustmentCalculatorScreen.swift \
  Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift
git commit -m "fix: keep calculator screenshots release truthful"
```

---

### Task 2: Pin the exact simulator runtime, device types, and capture matrix

**Files:**
- Modify: `AppStore/KnittingCalculator/Screenshots/manifest.json`
- Modify: `AppStore/KnittingCalculator/Screenshots/capture.sh`
- Modify: `AppStore/KnittingCalculator/Screenshots/compose.py`
- Modify: `AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py`
- Modify: `AppStore/KnittingCalculator/Screenshots/README.md`

**Step 1: Add failing capture tests**

Extend the fake `simctl list devices --json` fixture and add tests that prove capture exits before erase/install when:

- either device is under a runtime other than the exact manifest runtime;
- the `deviceTypeIdentifier` is a substring lookalike rather than an exact allowed identifier;
- a scene/filename pair is not in the exact approved locale/platform matrix;
- the iPhone or iPad manifest runtime/device fields are missing;
- the iPad compositor crop policy would expose the live calendar/date region.

Also assert the successful path validates both devices before the first destructive simulator operation.
Add a compositor pixel test with a uniquely colored/date-region fixture that
proves the declared crop removes those source pixels rather than merely
checking the Boolean policy.

**Step 2: Confirm RED**

Run:

```bash
python3 -m unittest AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py
```

Expected: new runtime, exact-device, and matrix tests fail against substring matching and unpinned manifest data.

**Step 3: Add an environment section to the manifest**

Use this canonical structure after confirming the identifiers exist locally:

```json
{
  "schemaVersion": 2,
  "captureEnvironment": {
    "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    "iphoneDeviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max",
    "ipadDeviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    "statusBarTime": "9:41",
    "cropSystemDate": true
  },
  "frames": []
}
```

Use the identifiers confirmed by `xcrun simctl list --json`; do not guess or silently accept alternatives.

**Step 4: Harden `capture.sh`**

- Parse and validate the entire manifest before simulator shutdown/erase.
- Resolve each UDID to exactly one runtime key and exact device type.
- Reject unavailable, non-dedicated, duplicate, mismatched, or unexpected devices.
- Keep the fixed status bar time.
- Never edit calendar text in pixels; make the crop policy remove the date-bearing system region consistently.
- Keep the selected scene and locale in launch arguments and the readiness-token wait.
- Reject non-exact iPhone/iPad frame dimensions before shutdown or erase.
- Make `compose.py` consume the validated crop policy and crop the iPad source
  region before scaling/pasting; do not synthesize or repaint status text.

**Step 5: Confirm GREEN and document the invocation**

Run:

```bash
python3 -m unittest AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py
bash -n AppStore/KnittingCalculator/Screenshots/capture.sh
python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json --manifest-only
```

Update README with exact runtime/device creation, build, capture, compose, and validation commands.

**Step 6: Commit**

```bash
git add AppStore/KnittingCalculator/Screenshots/manifest.json \
  AppStore/KnittingCalculator/Screenshots/capture.sh \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py \
  AppStore/KnittingCalculator/Screenshots/README.md
git commit -m "fix: pin calculator screenshot environment"
```

---

### Task 3: Enforce full PNG decode, exact filenames, containment, and deterministic composition

**Files:**
- Modify: `AppStore/KnittingCalculator/Screenshots/validate.py`
- Modify: `AppStore/KnittingCalculator/Screenshots/compose.py`
- Modify: `AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift`

**Step 1: Add failing validator/compositor tests**

Add cases for:

- a truncated PNG with a valid-looking header;
- an unexpected but count-preserving scene or filename;
- wrong scene order;
- a symlinked `Generated`, locale, or platform output parent;
- raw or generated paths resolving outside the manifest root;
- a second composition of identical committed inputs producing different SHA-256;
- extra numbered PNG files not listed in the manifest.

The exact approved scene matrix is:

```text
iphone: 01-home, 02-gauge, 03-adjustment, 04-privacy, 05-knitnote
ipad:   01-home, 02-gauge, 03-adjustment, 04-privacy-knitnote
```

for both `en` and `zh-Hant`.

**Step 2: Confirm RED**

Run:

```bash
python3 -m unittest AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py
swift test --filter KnittingCalculatorStoreScreenshotContractTests
```

Expected: the new decode, exact-matrix, symlink, and determinism cases fail.

**Step 3: Implement strict shared validation**

- Decode every image fully with Pillow `load()` or `verify()` followed by reopen/load.
- Compare the manifest to an ordered constant matrix, not only counts.
- Resolve and check every input/output path remains under its expected root.
- Walk each output parent component with `lstat`; reject symlinks before `mkdir` or write.
- Fail on unlisted numbered PNGs.
- Save output with fixed mode and parameters and compare SHA-256 across two runs in the test.
- Keep contact sheets as untracked local verification artifacts, outside the
  18-file submission matrix and outside the clean release branch.

**Step 4: Confirm GREEN**

Run:

```bash
python3 -m unittest AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py
swift test --filter KnittingCalculatorStoreScreenshotContractTests
python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json --manifest-only
```

**Step 5: Commit**

```bash
git add AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py \
  Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift
git commit -m "fix: verify calculator screenshot package exactly"
```

---

### Task 4: Lock Build 2 identity, metadata, privacy, and production dependency boundaries

**Files:**
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`
- Modify: `KnittingCalculator/project.yml`
- Regenerate: `KnittingCalculator.xcodeproj/project.pbxproj`
- Modify: `AppStore/Verification/metadata_check.py`
- Modify: `AppStore/Verification/metadata_check_test.py`
- Modify: `AppStore/KnittingCalculator/Metadata/en-US.md`
- Modify: `AppStore/KnittingCalculator/Metadata/zh-Hant.md`
- Modify: `AppStore/Verification/site_check.py`
- Modify: `AppStore/Verification/site_check_test.py`
- Modify: `AppStore/Verification/knitting_calculator_release_audit.sh`
- Create: `AppStore/Verification/knitting_calculator_release_audit_test.py`

**Step 1: Add failing contracts**

Add tests requiring:

- `CURRENT_PROJECT_VERSION: 2`;
- both metadata files contain the identical copyright value `© 2026 Chen Chung Lung`;
- metadata includes the exact calculator Apple ID `6795877892`;
- calculator privacy page, not KnitNote's general privacy page, includes the calculator-specific no-collection/no-analytics/no-tracking wording in both languages;
- the audit scans both `KnittingCalculator` and the linked production sources in `Packages/KnittingCalculatorCore/Sources`;
- archive and IPA audits require exact bundle `com.phillon.KnittingCalculator`, marketing version `1.0.0`, Build `2`, and App Store ID `6795877892`;
- commerce, analytics, tracking, networking, dynamic package, and binary-framework additions fail the calculator audit.

Use a temporary fixture repository in `knitting_calculator_release_audit_test.py`; do not weaken the production audit to make fixtures easy.

**Step 2: Confirm RED**

Run:

```bash
swift test --filter KnittingCalculatorProjectContractTests
python3 AppStore/Verification/metadata_check_test.py
python3 AppStore/Verification/site_check_test.py
python3 AppStore/Verification/knitting_calculator_release_audit_test.py
```

Expected: Build 1, missing structured copyright/Apple ID, calculator-page privacy scope, and package-boundary tests fail.

**Step 3: Implement the narrow changes**

- Change only calculator `CURRENT_PROJECT_VERSION` from `1` to `2`.
- Regenerate with:

```bash
xcodegen generate --spec KnittingCalculator/project.yml
```

- Add structured `Copyright` and `Apple ID` fields to both calculator metadata files.
- Keep English copy as the default product language and Traditional Chinese as localization.
- Extend site checks specifically for `knitting-calculator-privacy.html`.
- Scan production source and resolved/linked package declarations without treating test-fixture strings as production dependencies.
- Update audit constants to Build `2` and exact Apple ID.

**Step 4: Confirm GREEN**

Run:

```bash
swift test --filter KnittingCalculatorProjectContractTests
python3 AppStore/Verification/metadata_check_test.py
python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata
python3 AppStore/Verification/site_check_test.py
python3 AppStore/Verification/site_check.py AppStore/SupportSite
python3 AppStore/Verification/knitting_calculator_release_audit_test.py
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
git diff --check
```

**Step 5: Commit the immutable candidate source**

```bash
git add Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift \
  KnittingCalculator/project.yml \
  KnittingCalculator.xcodeproj/project.pbxproj \
  AppStore/Verification/metadata_check.py \
  AppStore/Verification/metadata_check_test.py \
  AppStore/KnittingCalculator/Metadata/en-US.md \
  AppStore/KnittingCalculator/Metadata/zh-Hant.md \
  AppStore/Verification/site_check.py \
  AppStore/Verification/site_check_test.py \
  AppStore/Verification/knitting_calculator_release_audit.sh \
  AppStore/Verification/knitting_calculator_release_audit_test.py
git commit -m "fix: lock calculator Build 2 release contracts"
```

Record the resulting SHA as `BUILD_SOURCE_SHA`. No production source, project setting, metadata, or release script may change after this point without invalidating and rebuilding the candidate.

---

### Task 5: Generate and visually accept the replacement 18-screenshot package

**Files:**
- Replace tracked outputs: `AppStore/KnittingCalculator/Screenshots/Generated/en/{iphone,ipad}/*.png`
- Replace tracked outputs: `AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/{iphone,ipad}/*.png`
- Produce local-only contact sheets: `AppStore/KnittingCalculator/Screenshots/Generated/{en,zh-Hant}/contact-sheet.png`
- Create: `AppStore/Verification/KnittingCalculatorBuild2ScreenshotVerification.md`

**Step 1: Build the DEBUG screenshot host from `BUILD_SOURCE_SHA`**

Verify `git status --short` contains only the preserved untracked paths, then build into a task-local DerivedData directory:

```bash
xcodebuild -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath /tmp/KnittingCalculatorBuild2Screenshots build
```

**Step 2: Capture both locales on the exact manifest environment**

Export `CALC_IPHONE_UDID` and `CALC_IPAD_UDID` in the shell from the two
validated dedicated simulators; never place their values in a command log or
tracked file. Then run:

```bash
CALC_SCREENSHOT_APP=/tmp/KnittingCalculatorBuild2Screenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app \
AppStore/KnittingCalculator/Screenshots/capture.sh en

CALC_SCREENSHOT_APP=/tmp/KnittingCalculatorBuild2Screenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app \
AppStore/KnittingCalculator/Screenshots/capture.sh zh-Hant
```

**Step 3: Compose twice and prove determinism**

```bash
python3 AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
find AppStore/KnittingCalculator/Screenshots/Generated -type f -name '*.png' \
  -exec shasum -a 256 {} + | sort
```

Save the hash list outside the repository, rerun composition, and require an exact diff match.

**Step 4: Validate and inspect visually**

```bash
python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
```

Inspect both contact sheets at full resolution and each of the 18 PNGs. Verify:

- no clipped text, half-screen layout, live date, debug label, or private identifier;
- Home/Settings promotion content matches the Release hierarchy;
- the first four frames do not visually foreground KnitNote;
- the final promotion frame clearly says KnitNote is a separate App;
- correct language, device family, order, and dimensions.

**Step 5: Record non-sensitive evidence and commit the screenshot package**

The verification document records manifest SHA, 18 output hashes, screenshot-host source SHA, exact runtime/device type identifiers, validation commands, and visual PASS. It must not record simulator UDIDs.

```bash
git add AppStore/KnittingCalculator/Screenshots/Generated/en/iphone \
  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad \
  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone \
  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad \
  AppStore/Verification/KnittingCalculatorBuild2ScreenshotVerification.md
git commit -m "assets: replace calculator release screenshots"
```

Record this SHA separately as `SCREENSHOT_PACKAGE_SHA`.

---

### Task 6: Archive and export the exact immutable Build 2 candidate

**Files:**
- Create: `AppStore/Verification/KnittingCalculatorBuild2ArtifactVerification.md`
- Modify: `AppStore/Verification/KnittingCalculatorPhysicalVerification.md`

**Step 1: Recreate a clean candidate worktree at `BUILD_SOURCE_SHA`**

Use a temporary worktree so later screenshot/evidence commits cannot enter the binary:

```bash
git worktree add --detach /tmp/knitting-calculator-build2-source "$BUILD_SOURCE_SHA"
```

Confirm:

```bash
git -C /tmp/knitting-calculator-build2-source status --short
git -C /tmp/knitting-calculator-build2-source rev-parse HEAD
```

Expected: clean and exactly `BUILD_SOURCE_SHA`.

**Step 2: Run candidate tests and archive**

From the detached worktree:

```bash
xcodebuild test -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /tmp/KnittingCalculatorBuild2Tests
xcodebuild archive -project KnittingCalculator.xcodeproj -scheme KnittingCalculator \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/KnittingCalculatorBuild2/KnittingCalculator.xcarchive \
  -derivedDataPath /tmp/KnittingCalculatorBuild2Archive
```

Run the signed archive audit:

```bash
AppStore/Verification/knitting_calculator_release_audit.sh \
  --archive /tmp/KnittingCalculatorBuild2/KnittingCalculator.xcarchive
```

**Step 3: Export and audit IPA**

Create `/tmp/KnittingCalculatorBuild2/ExportOptions.plist` with this exact
content:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>9CFPAUL5N5</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
```

Lint it, export, require exactly one IPA, and audit that explicit path:

```bash
plutil -lint /tmp/KnittingCalculatorBuild2/ExportOptions.plist
xcodebuild -exportArchive \
  -archivePath /tmp/KnittingCalculatorBuild2/KnittingCalculator.xcarchive \
  -exportPath /tmp/KnittingCalculatorBuild2/Export \
  -exportOptionsPlist /tmp/KnittingCalculatorBuild2/ExportOptions.plist
find /tmp/KnittingCalculatorBuild2/Export -maxdepth 1 -type f -name '*.ipa'
AppStore/Verification/knitting_calculator_release_audit.sh \
  --ipa /tmp/KnittingCalculatorBuild2/Export/KnittingCalculator.ipa
```

**Step 4: Record complete provenance**

Record:

- `BUILD_SOURCE_SHA`;
- archive and IPA absolute paths;
- SHA-256 of archive `Info.plist`, IPA, embedded App executable, and embedded App `Info.plist`;
- bundle ID, version/build, signing identity/team, and audit results;
- Xcode version and archive timestamp.

Do not record provisioning UUIDs, device IDs, emails, container paths, or PIDs.

**Step 5: Run a pre-upload physical smoke test from the exact source SHA**

An App Store Distribution IPA cannot be side-loaded directly because its
profile intentionally has no provisioned device list. Build and install a
Development-signed app from the same detached `BUILD_SOURCE_SHA` on the
existing iPhone and iPad as a pre-upload source/layout check. Ask the user to
verify on each device:

- Settings/About reports `1.0.0 (2)`;
- launch is full-screen with no half-screen clipping;
- one gauge case and one single-row/across-row adjustment case;
- rotation, background/foreground, relaunch, and KnitNote link;
- no unexpected permission prompt.

Record only device model, OS version, source SHA, observed result, and user
acceptance. This proves the source/layout path but does not claim the
distribution artifact itself ran. Any failure blocks upload.

**Step 6: Commit evidence without changing candidate source**

```bash
git add AppStore/Verification/KnittingCalculatorBuild2ArtifactVerification.md \
  AppStore/Verification/KnittingCalculatorPhysicalVerification.md
git commit -m "docs: verify calculator Build 2 candidate"
```

---

### Task 7: Upload Build 2 and replace the App Store Connect candidate

**Files:**
- Modify: `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md`

**Step 1: Preflight the exact upload**

Recompute the IPA SHA-256 and compare it with Task 6. Re-run the IPA audit. Stop if changed.

**Step 2: Upload Build `1.0.0 (2)`**

Upload the exact exported IPA through Xcode/App Store Connect tooling. Wait for processing to complete and confirm:

- Apple ID `6795877892`;
- bundle ID `com.phillon.KnittingCalculator`;
- version/build `1.0.0 (2)`;
- no processing warning changes the candidate boundary.

Do not attach Build 1.

**Step 3: Install the processed Build 2 from TestFlight and obtain distribution acceptance**

After processing, make Build 2 available through the existing internal
TestFlight path without creating a public/external testing submission. Install
`1.0.0 (2)` from TestFlight on the same iPhone and iPad and repeat:

- version/build identity;
- full-screen launch;
- one gauge case;
- single-row and across-row adjustment;
- rotation, background/foreground, relaunch;
- separate KnitNote link and absence of unexpected permissions.

Record the user's result for both devices. This TestFlight installation is the
distribution acceptance gate. Stop before changing the product page or
attaching Build 2 if either device fails.

**Step 4: Set and read back English (U.S.) primary language**

In App Information:

- change Primary Language from Traditional Chinese to English (U.S.);
- save;
- reload the page;
- read back English (U.S.) as primary and Traditional Chinese as localization.

Stop if either localized name/subtitle changes unexpectedly.

**Step 5: Replace all screenshots from the verified package**

For each locale in this order:

1. English (U.S.) iPhone: 5 files in manifest order.
2. English (U.S.) iPad: 4 files in manifest order.
3. Traditional Chinese iPhone: 5 files in manifest order.
4. Traditional Chinese iPad: 4 files in manifest order.

Delete/replace only the existing calculator screenshots. After every family, save/reload and verify count, order, language, and visible thumbnail content.

**Step 6: Attach Build 2 and preserve all other release settings**

Select Build `1.0.0 (2)` and read it back after reload. Reconfirm:

- Free and 175 territories;
- Public;
- Data Not Collected;
- no login;
- Game Center off;
- Apple silicon Mac off;
- Apple Vision Pro off;
- manual release;
- copyright matches repository metadata;
- Add for Review remains unclicked;
- no new App Review submission exists.

**Step 7: Record remote evidence**

Append timestamped read-back evidence, selected build, primary language, screenshot counts/order, preserved settings, and explicit no-submission boundary. Do not record account email or browser/session identifiers.

```bash
git add AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md
git commit -m "docs: record calculator Build 2 store candidate"
```

---

### Task 8: Build a sanitized one-commit local release branch

**Files:**
- Create: `AppStore/Verification/clean_release_history_check.py`
- Create: `AppStore/Verification/clean_release_history_check_test.py`
- Create in clean branch: `AppStore/Verification/KnittingCalculatorCleanReleaseVerification.md`

**Step 1: Add failing history-audit tests**

In a temporary Git repository, create commits containing:

- an unapproved email;
- UUID-shaped UDID/CoreDevice/provisioning values;
- `/Users/.../Containers/...` paths;
- `Process ID`/`PID` evidence;
- the approved public support email and public URLs.

Tests must prove the scanner rejects the first group across any reachable commit while allowing the explicitly approved public support contact and ordinary Git SHA values.

**Step 2: Confirm RED, implement, and confirm GREEN**

Run:

```bash
python3 AppStore/Verification/clean_release_history_check_test.py
```

Implement a scanner that enumerates every reachable commit and tracked blob for the named branch, reports file/commit without echoing the full secret, and uses a narrow allowlist for the intentionally public support email.

Repeat the test and require PASS.

**Step 3: Commit the scanner on the backup branch**

```bash
git add AppStore/Verification/clean_release_history_check.py \
  AppStore/Verification/clean_release_history_check_test.py
git commit -m "test: audit calculator release history"
```

**Step 4: Create the clean branch from the approved mainline baseline**

Use the verified shared baseline `f9a6c043758287a57d7eb583e0855c84d5a20073`, after confirming it is still the intended merge base:

```bash
git merge-base main codex/knitting-calculator-independent-project
git worktree add -b release/knitting-calculator-1.0.0-build2-clean \
  /tmp/knitting-calculator-build2-clean \
  f9a6c043758287a57d7eb583e0855c84d5a20073
```

If the merge base differs, stop and ask the user; do not substitute another baseline.

**Step 5: Apply the verified net change as one sanitized commit**

- Export only the final calculator source, tests, App Store assets/metadata, public support pages, and non-sensitive verification documents from the verified backup branch.
- Exclude Raw screenshots, caches, brainstorm material, old private evidence, and unrelated KnitNote changes.
- Sanitize evidence before staging.
- Run the full focused verification suite in the clean worktree.
- Create exactly one commit:

```bash
git commit -m "release: prepare Knitting Calculator 1.0.0 build 2"
```

**Step 6: Scan the whole clean history**

Run:

```bash
python3 AppStore/Verification/clean_release_history_check.py \
  release/knitting-calculator-1.0.0-build2-clean
git log --oneline --decorate \
  release/knitting-calculator-1.0.0-build2-clean
git status --short
```

Expected: scanner PASS, one calculator release commit on the exact baseline, clean worktree, no push.

**Step 7: Record verification and amend the one clean commit**

Record baseline SHA, clean commit SHA, candidate source SHA, screenshot package SHA, IPA hash, focused test results, remote Build 2 read-back, and no-push/no-submit boundary. Amend only the clean release commit, rerun the history scanner, and record the final amended SHA outside the commit if necessary to avoid a self-referential hash.

---

### Task 9: Run final release evidence and branch reviews

**Files:**
- Verify: `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md`
- Verify: `AppStore/Verification/KnittingCalculatorCleanReleaseVerification.md`

**Step 1: Run the calculator-focused gates on the clean branch**

```bash
swift test --filter KnittingCalculatorMetadataContractTests
swift test --filter KnittingCalculatorLocalizationContractTests
swift test --filter PrivacyManifestContractTests
swift test --filter KnittingCalculatorProjectContractTests
swift test --filter KnittingCalculatorStoreScreenshotContractTests
python3 AppStore/KnittingCalculator/Screenshots/test_screenshot_tools.py
python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
python3 AppStore/Verification/metadata_check_test.py
python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata
python3 AppStore/Verification/site_check_test.py
python3 AppStore/Verification/site_check.py AppStore/SupportSite
python3 AppStore/Verification/knitting_calculator_release_audit_test.py
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
python3 AppStore/Verification/clean_release_history_check_test.py
python3 AppStore/Verification/clean_release_history_check.py \
  release/knitting-calculator-1.0.0-build2-clean
git diff --check
```

**Step 2: Run the full repository suite and report it accurately**

```bash
swift test
```

Expected accepted state: calculator-focused gates all PASS; full suite may remain `855/856` only because of the pre-existing KnitNote keyword-duplication test. Any new failure blocks completion.

**Step 3: Review the clean branch against the approved design**

Review:

- `git diff --stat f9a6c043..release/knitting-calculator-1.0.0-build2-clean`
- `git diff f9a6c043..release/knitting-calculator-1.0.0-build2-clean`
- Build/source/artifact SHA chain;
- 18 screenshot hashes and App Store read-back;
- physical iPhone/iPad acceptance;
- remote Build 2 attachment and English primary language;
- full clean-branch history scan;
- terminal boundary: no Add for Review, submission, release, merge, or push.

Fix any Important finding, rerun the affected gates, and review again.

**Step 4: Hand off without publishing**

Report:

- backup branch and SHA;
- clean local release branch and SHA;
- `BUILD_SOURCE_SHA`, `SCREENSHOT_PACKAGE_SHA`, IPA SHA-256;
- calculator-focused gate results;
- honest full-suite result;
- iPhone/iPad acceptance;
- App Store Connect read-back;
- the exact next decision still requiring user authorization: whether to push/merge and whether to Add for Review.

Do not perform either next action in this plan.
