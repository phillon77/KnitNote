# Knitting Calculator App Store Submission Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce and verify the bilingual iPhone/iPad App Store package for Knitting Calculator `1.0.0 (1)`, populate App Store Connect through the saved-ready state, and stop before adding the version for review.

**Architecture:** Keep the shipped Release product unchanged and add a `#if DEBUG` deterministic screenshot host that renders the same production views with seeded local drafts. A calculator-specific manifest, capture script, compositor, and validator produce 18 opaque App Store images. App Store Connect changes are applied in small independently verifiable groups, with a fresh read-back and a written evidence record after each group.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen, Swift Testing, Xcode/iOS Simulator 26.5, `xcrun simctl`, Bash, Python 3, Pillow, App Store Connect web UI.

## Global Constraints

- App Store Connect Apple ID is exactly `6795877892`.
- Bundle ID is exactly `com.phillon.KnittingCalculator`.
- The only acceptable candidate is version/build `1.0.0 (1)`.
- The app remains free, offline, account-free, ad-free, IAP-free, analytics-free, and tracking-free.
- The row counter remains a separate product; this app contains only gauge and even increase/decrease tools.
- Traditional Chinese and English (U.S.) product pages are both required.
- Each locale requires 5 iPhone screenshots and 4 iPad screenshots.
- Use the approved B visual direction: branded headline plus truthful production UI.
- KnitNote appears only in the final, low-priority promotional screenshot and remains a separate app.
- Do not advertise uncompleted VoiceOver, maximum Dynamic Type, Mac, or Vision Pro verification.
- The 1.0 availability scope is iPhone and iPad only; do not actively offer Apple Silicon Mac or Vision Pro compatibility.
- App Review release control is manual.
- Do not click “Add for Review”, submit for review, release, alter KnitNote, or replace the candidate Build.
- Any identity, Build, screenshot, URL, pricing, privacy, or saved-state mismatch is a stop condition.

---

## File Map

### Create

- `KnittingCalculator/App/CalculatorStoreScreenshotMode.swift` — DEBUG-only launch-argument parser and deterministic draft seeding.
- `KnittingCalculator/App/CalculatorStoreScreenshotRootView.swift` — DEBUG-only scene router built from production calculator views.
- `Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift` — source and isolation contracts for screenshot mode.
- `AppStore/KnittingCalculator/Screenshots/manifest.json` — canonical 18-frame bilingual screenshot definition.
- `AppStore/KnittingCalculator/Screenshots/capture.sh` — dedicated-simulator capture and dimension checks.
- `AppStore/KnittingCalculator/Screenshots/compose.py` — approved B frame composition.
- `AppStore/KnittingCalculator/Screenshots/validate.py` — manifest, image, opacity, locale, and privacy validation.
- `AppStore/KnittingCalculator/Screenshots/requirements.txt` — pinned Pillow dependency range.
- `AppStore/KnittingCalculator/Screenshots/README.md` — reproducible capture and review instructions.
- `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md` — immutable local and App Store Connect evidence.

### Modify

- `KnittingCalculator/App/KnittingCalculatorApp.swift` — select the DEBUG screenshot root only when valid screenshot arguments are present.
- `AppStore/Verification/KnittingCalculatorPhysicalVerification.md` — link the final screenshot/App Store preparation evidence without widening physical acceptance claims.

### Generated and committed after visual approval

- `AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/*.png`
- `AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/*.png`
- `AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/*.png`
- `AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/*.png`
- `AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/contact-sheet.jpg`
- `AppStore/KnittingCalculator/Screenshots/Generated/en/contact-sheet.jpg`

### Never commit

- `AppStore/KnittingCalculator/Screenshots/Raw/`
- `.superpowers/brainstorm/`
- simulator containers, DerivedData, temporary Python environments, or browser session data

---

### Task 1: Lock the screenshot manifest and validator

**Files:**
- Create: `AppStore/KnittingCalculator/Screenshots/manifest.json`
- Create: `AppStore/KnittingCalculator/Screenshots/validate.py`
- Create: `AppStore/KnittingCalculator/Screenshots/requirements.txt`
- Create: `Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift`

**Interfaces:**
- Produces: manifest schema version 1 with fields `locale`, `platform`, `scene`, `device`, `width`, `height`, `headline`, `subheadline`, and `filename`.
- Produces: `validate.py <manifest> --manifest-only` and `validate.py <manifest>` commands.
- Consumes: approved locales `zh-Hant` and `en`, platforms `iphone` and `ipad`.

- [ ] **Step 1: Write the failing manifest contract test**

Add a Swift Testing case that loads the future manifest and asserts:

```swift
@Test func calculatorScreenshotManifestPinsApprovedBilingualScope() throws {
    let data = try Data(contentsOf: repositoryURL(
        "AppStore/KnittingCalculator/Screenshots/manifest.json"
    ))
    let payload = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let frames = try #require(payload["frames"] as? [[String: Any]])

    #expect(payload["schemaVersion"] as? Int == 1)
    #expect(frames.count == 18)
    #expect(frames.filter { $0["locale"] as? String == "zh-Hant" }.count == 9)
    #expect(frames.filter { $0["locale"] as? String == "en" }.count == 9)
    #expect(frames.filter { $0["platform"] as? String == "iphone" }.count == 10)
    #expect(frames.filter { $0["platform"] as? String == "ipad" }.count == 8)
    #expect(frames.allSatisfy { $0["width"] as? Int == 1284 || $0["width"] as? Int == 2064 })
}
```

Also add a `repositoryURL(_:)` helper that resolves three parents above
`#filePath`, matching the repository helpers in neighboring contract tests.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorStoreScreenshotContractTests
```

Expected: FAIL because `manifest.json` does not exist.

- [ ] **Step 3: Create the exact 18-frame manifest**

Use iPhone size `1284 × 2778` and iPad size `2064 × 2752`.

The iPhone scene order for both locales is:

```text
01-home.png        home
02-gauge.png       gauge
03-adjustment.png  adjustment
04-privacy.png     privacy
05-knitnote.png    promotion
```

The iPad scene order for both locales is:

```text
01-home.png        home
02-gauge.png       gauge
03-adjustment.png  adjustment
04-privacy-knitnote.png privacyPromotion
```

Use these Traditional Chinese headline/subheadline pairs:

```text
編織尺寸，一算就懂 / 免費・離線・不需帳號
密度、針數、排數 / 輸入樣本，立即換算尺寸
平均安排加針減針 / 單行或跨排都能算
不登入，也不追蹤 / 草稿只留在你的裝置
想記錄完整作品？ / 認識獨立 App：KnitNote
```

Use these English pairs:

```text
Knitting math, made clear / Free, offline, no account
Gauge, stitches, and rows / Enter a swatch and get the count
Space increases and decreases / In one row or across many
No sign-in. No tracking. / Drafts stay on your device
Want to track the whole project? / Meet the separate KnitNote app
```

The iPad fourth frame uses the privacy headline and a subheadline that includes
the separate KnitNote relationship:

```text
不登入，也不追蹤 / 編織計算器可獨立使用，也能認識 KnitNote
No sign-in. No tracking. / Use it alone, or discover the separate KnitNote app
```

- [ ] **Step 4: Implement manifest validation**

`validate.py` must:

```python
EXPECTED_COUNTS = {"iphone": 5, "ipad": 4}
EXPECTED_SIZES = {"iphone": (1284, 2778), "ipad": (2064, 2752)}
LOCALES = {"zh-Hant", "en"}
DENYLIST = ("lzz.1999", "/Users/", "IMG_", "截圖", "GPSLatitude", "GPSLongitude")
```

It must reject:

- a schema other than 1;
- a total other than 18 frames;
- per-locale platform counts other than 5/4;
- duplicate filenames within a locale/platform;
- missing fields;
- incorrect dimensions;
- non-Chinese `zh-Hant` headlines;
- non-ASCII English headlines;
- any denylisted marker in JSON or encoded image bytes;
- missing raw/generated images outside `--manifest-only`;
- generated images that are not opaque RGB.

On success, print exactly:

```text
18 screenshot definitions valid
```

or:

```text
18 screenshots valid
```

- [ ] **Step 5: Pin the compositor dependency**

Create `requirements.txt`:

```text
Pillow>=11.0,<12
```

- [ ] **Step 6: Run the validator and Swift contract**

Run:

```bash
python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json --manifest-only
swift test --filter KnittingCalculatorStoreScreenshotContractTests
```

Expected: validator prints `18 screenshot definitions valid`; Swift test PASS.

- [ ] **Step 7: Commit Task 1**

```bash
git add \
  AppStore/KnittingCalculator/Screenshots/manifest.json \
  AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/requirements.txt \
  Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift
git commit -m "test: lock calculator screenshot package"
```

---

### Task 2: Add the isolated DEBUG screenshot host

**Files:**
- Create: `KnittingCalculator/App/CalculatorStoreScreenshotMode.swift`
- Create: `KnittingCalculator/App/CalculatorStoreScreenshotRootView.swift`
- Modify: `KnittingCalculator/App/KnittingCalculatorApp.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift`

**Interfaces:**
- Produces: `CalculatorStoreScreenshotMode.resolve(processInfo:) -> CalculatorStoreScreenshotResolution`.
- Produces: `CalculatorStoreScreenshotScene` cases `home`, `gauge`, `adjustment`, `privacy`, `promotion`, and `privacyPromotion`.
- Produces: `CalculatorStoreScreenshotRootView(mode:)`.
- Consumes: production `CalculatorHomeView`, `GaugeCalculatorScreen`, `AdjustmentCalculatorScreen`, `CalculatorSettingsView`, and `CalculatorPreferencesStore`.

- [ ] **Step 1: Extend the contract test and verify RED**

Add assertions that:

```swift
#expect(mode.contains("#if DEBUG"))
#expect(mode.contains("case home, gauge, adjustment, privacy, promotion, privacyPromotion"))
#expect(mode.contains("-storeScreenshotScene"))
#expect(mode.contains("-storeScreenshotLanguage"))
#expect(mode.contains("-storeScreenshotToken"))
#expect(root.contains("GaugeCalculatorScreen()"))
#expect(root.contains("AdjustmentCalculatorScreen()"))
#expect(root.contains("CalculatorSettingsView()"))
#expect(app.contains("CalculatorStoreScreenshotMode.resolve"))
#expect(app.contains("case .notRequested"))
#expect(app.contains("case .ready(let mode)"))
```

Run:

```bash
swift test --filter KnittingCalculatorStoreScreenshotContractTests
```

Expected: FAIL because the DEBUG host files and app integration do not exist.

- [ ] **Step 2: Implement strict DEBUG-only argument resolution**

In `CalculatorStoreScreenshotMode.swift`, define:

```swift
#if DEBUG
import Foundation
import KnittingCalculatorCore

enum CalculatorStoreScreenshotScene: String, CaseIterable {
    case home, gauge, adjustment, privacy, promotion, privacyPromotion
}

enum CalculatorStoreScreenshotLanguage: String {
    case zhHant = "zh-Hant"
    case en

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

struct CalculatorStoreScreenshotMode: Equatable {
    let scene: CalculatorStoreScreenshotScene
    let language: CalculatorStoreScreenshotLanguage
    let readinessToken: String

    static func resolve(
        processInfo: ProcessInfo = .processInfo
    ) -> CalculatorStoreScreenshotResolution
}

enum CalculatorStoreScreenshotResolution: Equatable {
    case notRequested
    case ready(CalculatorStoreScreenshotMode)
    case invalid
}
#endif
```

Resolution is `.notRequested` unless `-storeScreenshotMode YES` is present.
Missing/unknown scene, language, or empty token is `.invalid`; never silently
fall back to a normal app scene after screenshot mode was requested.

- [ ] **Step 3: Seed deterministic local drafts without external data**

Add a `@MainActor` factory:

```swift
func makePreferences() -> CalculatorPreferencesStore {
    let suite = "com.phillon.KnittingCalculator.StoreScreenshots.\(readinessToken)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = CalculatorPreferencesStore(defaults: defaults, locale: language.locale)
    store.gauge = GaugeDraft(
        unit: .centimeters,
        sampleWidth: "10",
        sampleStitches: "20",
        targetWidth: "25",
        sampleHeight: "10",
        sampleRows: "30",
        targetHeight: "20"
    )
    store.oneRow = OneRowAdjustmentDraft(
        currentStitches: "80",
        targetStitches: "92",
        reservesEdgeStitches: true
    )
    store.rowInterval = RowIntervalAdjustmentDraft(
        totalRows: "20",
        totalStitches: "6",
        operation: .increase,
        style: .singleSide
    )
    return store
}
```

This suite is unique per readiness token and never reads `.standard`.

- [ ] **Step 4: Build the screenshot root from production views**

`CalculatorStoreScreenshotRootView` must route:

```swift
switch scene {
case .home, .promotion:
    NavigationStack { CalculatorHomeView() }
case .gauge:
    NavigationStack { GaugeCalculatorScreen() }
case .adjustment:
    NavigationStack { AdjustmentCalculatorScreen() }
case .privacy, .privacyPromotion:
    NavigationStack { CalculatorSettingsView() }
}
```

Set `.environment(\.locale, mode.language.locale)`. Add an almost transparent
`Text("Ready")` with accessibility identifier `storeScreenshot.ready`; after
350 ms, log:

```swift
Logger(
    subsystem: "com.phillon.KnittingCalculator",
    category: "StoreScreenshots"
).notice("storeScreenshot.ready.\(readinessToken, privacy: .public)")
```

- [ ] **Step 5: Integrate without changing Release behavior**

In `KnittingCalculatorApp`, resolve screenshot mode in `init`. Under
`#if DEBUG`, construct the isolated preferences from a valid mode. In
`WindowGroup`, switch:

```swift
#if DEBUG
switch screenshotResolution {
case .ready(let mode):
    CalculatorStoreScreenshotRootView(mode: mode)
case .notRequested:
    CalculatorRootView()
case .invalid:
    ContentUnavailableView("Invalid screenshot configuration", systemImage: "xmark.octagon")
}
#else
CalculatorRootView()
#endif
```

Both valid roots receive the same required preference/rating environment
objects. No screenshot flag, fixture, synthetic file, or scene symbol may be
compiled into the Release branch.

- [ ] **Step 6: Verify focused tests, project regeneration, and both configs**

Run:

```bash
swift test --filter KnittingCalculatorStoreScreenshotContractTests
xcodegen generate --spec KnittingCalculator/project.yml \
  --project-root .
xcodebuild -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnittingCalculatorScreenshots build
xcodebuild -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnittingCalculatorReleaseRecheck \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: focused tests PASS and both builds end with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit Task 2**

```bash
git add \
  KnittingCalculator/App/CalculatorStoreScreenshotMode.swift \
  KnittingCalculator/App/CalculatorStoreScreenshotRootView.swift \
  KnittingCalculator/App/KnittingCalculatorApp.swift \
  KnittingCalculator.xcodeproj/project.pbxproj \
  Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift
git commit -m "feat: add isolated calculator screenshot mode"
```

---

### Task 3: Implement reproducible capture and B-style composition

**Files:**
- Create: `AppStore/KnittingCalculator/Screenshots/capture.sh`
- Create: `AppStore/KnittingCalculator/Screenshots/compose.py`
- Create: `AppStore/KnittingCalculator/Screenshots/README.md`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift`

**Interfaces:**
- Consumes: manifest scenes and DEBUG launch arguments from Tasks 1–2.
- Produces: `capture.sh zh-Hant|en`.
- Produces: `compose.py manifest.json`.
- Produces: raw screenshots in `Raw/<locale>/<platform>/` and final assets in `Generated/<locale>/<platform>/`.

- [ ] **Step 1: Add failing script-isolation contracts**

Assert the future script contains:

```swift
#expect(script.contains("Knitting Calculator Store"))
#expect(script.contains("xcrun simctl erase"))
#expect(script.contains("com.phillon.KnittingCalculator"))
#expect(script.contains("-storeScreenshotMode YES"))
#expect(script.contains("-storeScreenshotToken"))
#expect(script.contains("verify_dimensions"))
#expect(!script.contains("com.phillon.KnitNote\""))
```

Assert the compositor contains:

```swift
#expect(compositor.contains("PALE_BLUE"))
#expect(compositor.contains("LAVENDER"))
#expect(compositor.contains("BLUSH"))
#expect(compositor.contains("frame[\"headline\"]"))
#expect(compositor.contains("frame[\"subheadline\"]"))
```

Run the focused suite and verify FAIL because the scripts do not exist.

- [ ] **Step 2: Implement dedicated simulator safety**

`capture.sh` accepts only `zh-Hant` or `en`. It requires:

```text
CALC_IPHONE_UDID
CALC_IPAD_UDID
```

It queries `xcrun simctl list devices --json` and refuses:

- unknown/unavailable devices;
- names not beginning `Knitting Calculator Store`;
- an iPhone other than `iPhone 13 Pro Max`;
- an iPad other than `iPad Pro 13-inch (M5)` or `iPad Pro 13-inch (M4)`.

For each locale it shuts down, erases, boots, and waits for both devices. Use
`zh_TW` for `zh-Hant` and `en_US` for `en`. Override status bars to 9:41,
charged 100%, full Wi-Fi, and four cellular bars on iPhone.

- [ ] **Step 3: Capture exact scenes**

Build path defaults to:

```text
/tmp/KnittingCalculatorScreenshots/Build/Products/Debug-iphonesimulator/KnittingCalculator.app
```

For every manifest row:

1. install the app;
2. terminate `com.phillon.KnittingCalculator`;
3. launch with mode, scene, language, and a UUID readiness token;
4. poll unified log for `storeScreenshot.ready.<token>`;
5. wait two seconds for rendering;
6. capture with `xcrun simctl io <udid> screenshot`;
7. verify the exact raw pixel dimensions from the manifest.

Any timeout or dimension mismatch exits nonzero.

- [ ] **Step 4: Compose the approved B frame**

Adapt the existing watercolor approach without importing KnitNote assets:

```python
INK = (48, 42, 58)
BERRY = (119, 72, 153)
PALE_BLUE = (235, 242, 255)
LAVENDER = (242, 236, 255)
BLUSH = (252, 232, 246)
SOFT_WHITE = (255, 253, 255)
```

Composition rules:

- output stays at the manifest dimensions;
- real UI occupies at least 82% of frame height;
- headline and subheadline remain above the UI and never cover controls;
- use PingFang for `zh-Hant` and SF/Helvetica for `en`;
- round only the outer UI capture corners;
- save opaque optimized RGB PNG;
- generate one contact sheet per locale in manifest order.

- [ ] **Step 5: Write reproducible README commands**

Document the exact simulator creation commands:

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

Document build, capture, compose, and validation commands using a temporary
virtual environment at `/tmp/knitting-calculator-screenshots-venv`.

- [ ] **Step 6: Verify scripts and static package**

Run:

```bash
bash -n AppStore/KnittingCalculator/Screenshots/capture.sh
python3 -m py_compile \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/validate.py
python3 AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json --manifest-only
swift test --filter KnittingCalculatorStoreScreenshotContractTests
```

Expected: shell syntax succeeds, Python compiles, 18 definitions validate, and
the focused Swift suite passes.

- [ ] **Step 7: Commit Task 3**

```bash
git add \
  AppStore/KnittingCalculator/Screenshots/capture.sh \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/README.md \
  Tests/KnitNoteCoreTests/KnittingCalculatorStoreScreenshotContractTests.swift
git commit -m "feat: automate calculator App Store screenshots"
```

---

### Task 4: Capture, compose, and visually approve all 18 images

**Files:**
- Create: `AppStore/KnittingCalculator/Screenshots/Generated/**`
- Do not commit: `AppStore/KnittingCalculator/Screenshots/Raw/**`

**Interfaces:**
- Consumes: Task 3 build/capture/composition commands.
- Produces: 18 validated opaque PNG files and two contact sheets.

- [ ] **Step 1: Create the two dedicated simulators**

Run the two exact `simctl create` commands from the README. Copy their returned
UUIDs into task-specific variables:

```bash
export CALC_IPHONE_UDID='<returned iPhone UUID>'
export CALC_IPAD_UDID='<returned iPad UUID>'
```

Before continuing, run `xcrun simctl list devices` and verify both names,
device types, availability, and no personal simulator is referenced.

- [ ] **Step 2: Build the DEBUG screenshot binary**

```bash
xcodebuild -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/KnittingCalculatorScreenshots build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Capture both locales**

```bash
CALC_IPHONE_UDID='<explicit iPhone UUID>' \
CALC_IPAD_UDID='<explicit iPad UUID>' \
AppStore/KnittingCalculator/Screenshots/capture.sh zh-Hant

CALC_IPHONE_UDID='<explicit iPhone UUID>' \
CALC_IPAD_UDID='<explicit iPad UUID>' \
AppStore/KnittingCalculator/Screenshots/capture.sh en
```

Expected: 18 raw captures, each with the exact manifest dimensions.

- [ ] **Step 4: Compose and validate**

```bash
python3 -m venv /tmp/knitting-calculator-screenshots-venv
/tmp/knitting-calculator-screenshots-venv/bin/pip install \
  -r AppStore/KnittingCalculator/Screenshots/requirements.txt
/tmp/knitting-calculator-screenshots-venv/bin/python \
  AppStore/KnittingCalculator/Screenshots/compose.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
/tmp/knitting-calculator-screenshots-venv/bin/python \
  AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
```

Expected: `18 screenshots valid`.

- [ ] **Step 5: Perform the visual gate**

Open both contact sheets and inspect each full-size PNG at 100%. Record PASS
only when all are true:

- correct language in UI, headline, and subheadline;
- values match verified cases: gauge 50/60 and across-row 4, 7, 10, 14, 17, 20;
- no half-screen layout, black compatibility bars, cropping, keyboard, focus
  ring, debug text, or transient overlay;
- privacy copy is factual;
- KnitNote is only in the final iPhone frame and combined final iPad frame;
- final KnitNote frame states that the calculator works independently;
- no personal name, email, path, photo, or device identifier.

If any row fails, fix the deterministic host/compositor, recapture the affected
locale/platform, rerun validation, and repeat the full visual gate.

- [ ] **Step 6: Commit only approved generated files**

```bash
git add AppStore/KnittingCalculator/Screenshots/Generated
git commit -m "assets: add calculator App Store screenshots"
```

Confirm `git status --short` still shows `Raw/` as ignored or untracked and not
staged. Never use a broad `git add .`.

---

### Task 5: Verify metadata, privacy facts, and public URLs locally

**Files:**
- Modify only if a mismatch is found:
  - `AppStore/KnittingCalculator/Metadata/zh-Hant.md`
  - `AppStore/KnittingCalculator/Metadata/en-US.md`
  - `AppStore/KnittingCalculator/PrivacyPolicy.md`
- Create: `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md`

**Interfaces:**
- Consumes: existing metadata contracts and the shipped source/privacy manifest.
- Produces: a dated evidence document with exact candidate identity and URL checks.

- [ ] **Step 1: Run all local product and metadata contracts**

```bash
swift test --filter KnittingCalculatorMetadataContractTests
swift test --filter KnittingCalculatorLocalizationContractTests
swift test --filter PrivacyManifestContractTests
swift test --filter KnittingCalculatorProjectContractTests
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
```

Expected: every focused suite PASS and the audit ends with
`KNITTING CALCULATOR RELEASE AUDIT: PASS`.

- [ ] **Step 2: Reconfirm the source privacy facts**

Search the independent app target and linked package for:

```bash
rg -n 'Analytics|Tracking|AdSupport|AppTrackingTransparency|URLSession|CloudKit|StoreKit|Firebase|Telemetry' \
  KnittingCalculator Packages/KnittingCalculatorCore
```

Any actual analytics, tracking, ad, account, server upload, or purchase path is
a stop condition. Apple framework names appearing only in tests/comments must
be documented rather than silently ignored.

- [ ] **Step 3: Verify both public URLs**

Open and confirm HTTP success plus visible calculator-specific content:

```text
https://phillon77.github.io/KnitNote/knitting-calculator.html
https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html
```

The support page must describe this independent calculator. The privacy page
must say no personal data is collected and must not describe KnitNote as the
same app.

- [ ] **Step 4: Create the evidence document**

Record:

- Git SHA;
- branch/worktree;
- Apple ID, Bundle ID, version/build;
- exact test commands and results;
- screenshot manifest SHA-256;
- generated image file list and SHA-256 values;
- public URL check date/time and result;
- explicit remaining boundary: no App Store Connect submission.

- [ ] **Step 5: Commit local verification**

```bash
git add \
  AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md \
  AppStore/KnittingCalculator/Metadata/zh-Hant.md \
  AppStore/KnittingCalculator/Metadata/en-US.md \
  AppStore/KnittingCalculator/PrivacyPolicy.md
git commit -m "docs: verify calculator App Store package"
```

If no metadata/privacy file changed, stage only the evidence document.

---

### Task 6: Populate App information, privacy, pricing, and availability

**Files:**
- Modify remotely: App Store Connect app `6795877892`
- Append evidence: `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md`

**Interfaces:**
- Consumes: approved local metadata and Task 5 evidence.
- Produces: saved App Information, App Privacy, free pricing, worldwide public availability, and iPhone/iPad-only compatibility settings.

- [ ] **Step 1: Fresh identity preflight**

Open App Store Connect and verify:

```text
App name: 編織計算器
Apple ID: 6795877892
Bundle ID: com.phillon.KnittingCalculator
iOS version: 1.0, Prepare for Submission
```

If any value differs, stop before making a remote change.

- [ ] **Step 2: Save App Information**

For Traditional Chinese and English (U.S.), fill the approved name/subtitle
from the corresponding metadata file. Set:

```text
Primary category: Utilities
Secondary category: Lifestyle
```

Complete the age-rating questionnaire strictly from actual app content. Record
the resulting age rating; do not force a target value.

- [ ] **Step 3: Save App Privacy**

Set and publish the App Privacy response to:

```text
Data Not Collected
```

Save the calculator-specific privacy URL for both localizations. Reload the page
and verify the published summary still says no data is collected.

- [ ] **Step 4: Set free worldwide availability**

Create the initial price schedule with price `Free`. Select all publicly
available App Store countries/regions. Keep distribution method `Public`.

Disable:

```text
Make this app available on Apple silicon Macs
Make this app available on Apple Vision Pro
```

Reload the page and confirm free pricing, selected availability, Public
distribution, Mac off, and Vision Pro off.

- [ ] **Step 5: Record and commit the read-back**

Append the visible saved values, timestamps, and any App Store Connect status
labels to the evidence document.

```bash
git add AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md
git commit -m "docs: record calculator store configuration"
```

Do not continue if any saved value changes after reload.

---

### Task 7: Populate both product pages and attach the verified Build

**Files:**
- Upload remotely: 18 generated screenshots
- Modify remotely: iOS version 1.0 product-page metadata and Build
- Append evidence: `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md`

**Interfaces:**
- Consumes: Task 4 screenshots, metadata files, Build `1.0.0 (1)`.
- Produces: two saved localized product pages and an attached candidate Build.

- [ ] **Step 1: Revalidate immediately before upload**

```bash
/tmp/knitting-calculator-screenshots-venv/bin/python \
  AppStore/KnittingCalculator/Screenshots/validate.py \
  AppStore/KnittingCalculator/Screenshots/manifest.json
git status --short
```

Expected: `18 screenshots valid`; no uncommitted source or generated-image
change.

- [ ] **Step 2: Populate Traditional Chinese**

Upload the 5 `zh-Hant/iphone` and 4 `zh-Hant/ipad` files in manifest order.
Copy promotional text, description, keywords, support URL, copyright, and
review-facing text from `Metadata/zh-Hant.md`. Save, reload, and verify:

- screenshot counts 5/4;
- order 01–05 and 01–04;
- character counters are nonnegative;
- no field is blank except optional marketing URL.

- [ ] **Step 3: Populate English (U.S.)**

Repeat with `Generated/en` and `Metadata/en-US.md`. Save and reload with the
same 5/4, order, and nonblank checks.

- [ ] **Step 4: Attach the immutable Build**

Use “Add Build” and select exactly:

```text
1.0.0 (1)
```

Verify its bundle identity remains `com.phillon.KnittingCalculator` and its
export-compliance answer remains the previously confirmed no-relevant-encryption
choice. Do not select another build if this one is missing.

- [ ] **Step 5: Record and commit the read-back**

Append both locale names, screenshot counts, Build, and remote status to the
evidence file.

```bash
git add AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md
git commit -m "docs: record calculator product pages"
```

---

### Task 8: Complete review information and stop at the ready boundary

**Files:**
- Modify remotely: iOS 1.0 review information and release control
- Modify: `AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md`
- Modify: `AppStore/Verification/KnittingCalculatorPhysicalVerification.md`

**Interfaces:**
- Consumes: approved review notes and account-holder contact details.
- Produces: saved no-login review information, manual release, and final not-submitted evidence.

- [ ] **Step 1: Correct App Review information**

Uncheck `Sign-in required`. Leave username and password blank. Fill the valid
account-holder first name, last name, telephone number, and email visible in
the account’s existing App Review contact data. Paste the approved Review Notes
from the localized metadata, preserving these facts:

```text
No sign-in, account, purchase, permission, or network connection is required.
Both calculators work immediately.
Drafts stay on device.
Copy/share is available.
The optional KnitNote link opens a separate app or App Store page.
```

Leave Game Center disabled and do not attach an unnecessary review file.

- [ ] **Step 2: Change release control to manual**

Select:

```text
Manually release this version
```

Save and reload. Verify automatic release is no longer selected.

- [ ] **Step 3: Perform the final remote checklist**

Verify line by line:

```text
Apple ID 6795877892
Bundle com.phillon.KnittingCalculator
Version 1.0
Build 1.0.0 (1)
Traditional Chinese screenshots 5 iPhone / 4 iPad
English screenshots 5 iPhone / 4 iPad
Price Free
Availability worldwide/public
Data Not Collected
Sign-in not required
Manual release
Mac compatibility off
Vision Pro compatibility off
Game Center off
```

Verify the page offers “Add for Review” but do not click it. Verify App Review
submissions contains no new submission for this app.

- [ ] **Step 4: Update final evidence boundaries**

In the preparation evidence, record the final remote checklist, timestamps,
and exact stop state. In the physical verification file, add one link to the
preparation evidence and state that store preparation does not widen untested
physical rows.

- [ ] **Step 5: Run final local verification**

```bash
swift test
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
git diff --check
git status --short
```

Expected: all tests PASS, audit PASS, diff check clean. The only permitted
untracked content is `.superpowers/brainstorm/`, which remains local.

- [ ] **Step 6: Commit the final evidence**

```bash
git add \
  AppStore/Verification/KnittingCalculatorAppStorePreparationVerification.md \
  AppStore/Verification/KnittingCalculatorPhysicalVerification.md
git commit -m "docs: record calculator submission readiness"
```

- [ ] **Step 7: Report the exact terminal state**

Report:

- local Git SHA;
- App Store Connect status and candidate Build;
- screenshot counts/locales/platforms;
- free/privacy/manual-release state;
- explicit statement that the app has not been added for review, submitted,
  approved, released, or made public.

Do not merge, push, add for review, submit, or release without a separate
explicit user instruction.
