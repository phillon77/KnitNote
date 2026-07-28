# Free Knitting Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a separate, completely free iPhone and iPad knitting calculator containing KnitNote's gauge and even increase/decrease tools while unobtrusively introducing users to KnitNote.

**Architecture:** Add an independent `KnittingCalculator` iOS application target to the existing KnitNote repository. Compile only the four pure calculator source files from `KnitNoteCore` into the new target, keep all UI and local preferences under `KnittingCalculator/`, and give the product its own bundle identifier, scheme, privacy manifest, assets, metadata, and release audit.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XCTest for app-target behavior, String Catalogs, XcodeGen, iOS/iPadOS 18.

## Global Constraints

- The display name is `編織計算器`; the App Store subtitle is `密度與加減針工具`.
- The English display name is `Knitting Calculator`; verify final App Store name availability before creating the App Store Connect record.
- The app is completely free, with no ads, in-app purchases, account, analytics SDK, tracking, data upload, or feature lock.
- The app requests no camera, photo, notification, location, contacts, iCloud, or file permissions.
- All calculations, help, saved drafts, copying, and share-text generation work offline.
- The first release supports iPhone and iPad on iOS/iPadOS 18 or later; it supports portrait, landscape, iPad multitasking, Traditional Chinese, and English.
- The first release does not include the row counter, projects, yarn inventory, patterns, journal, calculation history, favorites, Apple Watch, Mac, widgets, App Clips, OCR, notifications, or cross-app data transfer.
- Gauge results show density, exact count, nearest-integer recommendation using `toNearestOrAwayFromZero`, and a pattern-repeat/edge-stitch caution.
- Gauge rows remain an optional complete group; changing centimeters/inches converts only length fields and preserves counts.
- One-row adjustment defaults to reserving exactly one edge stitch on each side and states the edge choice in the result.
- Adjustment results show a concise summary first and complete neutral knitting/crochet steps in a collapsed disclosure.
- The app remembers only the last draft for each calculator, the unit preference, valid calculation count, and per-version rating-attempt state.
- KnitNote promotion appears only on the home screen and Settings; it never appears in results or blocks calculation.
- The KnitNote copy is `需要管理作品、排數、毛線、織圖與編織日記？認識 KnitNote。` and must not call KnitNote an upgrade or full version.
- The existing KnitNote App Store product URL is `https://apps.apple.com/app/id6793023054`.
- Shared calculation code remains the single source of truth for KnitNote and the free app.
- Automated success cannot replace physical iPhone and iPad acceptance.

---

## File Map

### Project and target configuration

- `project.yml` — defines the new app/test targets and schemes; adds the `knitnote` URL scheme to the existing KnitNote target.
- `KnittingCalculator/Info.plist` — free app bundle metadata.
- `KnittingCalculator/PrivacyInfo.xcprivacy` — no tracking/collection; UserDefaults required-reason declaration only.
- `KnittingCalculator/Localization/InfoPlist.xcstrings` — localized display name.
- `KnittingCalculator/Localization/Localizable.xcstrings` — all app UI and formatted share text.

### App composition

- `KnittingCalculator/App/KnittingCalculatorApp.swift` — app entry, locale, shared stores.
- `KnittingCalculator/App/CalculatorRootView.swift` — root navigation.
- `KnittingCalculator/Model/CalculatorPreferencesStore.swift` — last drafts, unit, reset, calculation/rating counters.
- `KnittingCalculator/Model/LocalizedNumberCodec.swift` — strict locale-aware parsing and display formatting.
- `KnittingCalculator/Model/CalculatorShareText.swift` — deterministic localized copy/share payloads.
- `KnittingCalculator/Model/KnitNoteLinkRouter.swift` — installed-app launch and App Store fallback.
- `KnittingCalculator/Model/RatingEligibility.swift` — five-calculation and once-per-version policy.

### UI

- `KnittingCalculator/Theme/CalculatorTheme.swift` — watercolor palette, background, and card surfaces.
- `KnittingCalculator/Components/CalculatorField.swift` — labeled numeric field and inline error.
- `KnittingCalculator/Components/CalculatorResultActions.swift` — copy/share actions for valid results.
- `KnittingCalculator/Home/CalculatorHomeView.swift` — two tool cards and one KnitNote card.
- `KnittingCalculator/Gauge/GaugeCalculatorScreen.swift` — gauge inputs, results, conversion, and help.
- `KnittingCalculator/Adjustment/AdjustmentCalculatorScreen.swift` — one-row/across-rows mode picker.
- `KnittingCalculator/Adjustment/OneRowAdjustmentView.swift` — one-row inputs, failures, summary, steps.
- `KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift` — across-rows inputs, failures, summary, schedule.
- `KnittingCalculator/Help/CalculatorHelpSheet.swift` — short gauge and adjustment examples.
- `KnittingCalculator/Settings/CalculatorSettingsView.swift` — unit, reset, KnitNote, feedback, privacy, version.

### Assets and release material

- `KnittingCalculator/Assets.xcassets/AppIcon.appiconset/` — approved B yarn/needle/gauge icon.
- `KnittingCalculator/Assets.xcassets/Contents.json` — asset catalog root.
- `AppStore/KnittingCalculator/Metadata/en-US.md` — English listing.
- `AppStore/KnittingCalculator/Metadata/zh-Hant.md` — Traditional Chinese listing.
- `AppStore/KnittingCalculator/PrivacyPolicy.md` — bilingual product privacy policy.
- `AppStore/SupportSite/knitting-calculator.html` — bilingual support page.
- `AppStore/SupportSite/knitting-calculator-privacy.html` — bilingual privacy page.
- `AppStore/Verification/knitting_calculator_release_audit.sh` — product-specific static/archive audit.
- `AppStore/Verification/KnittingCalculatorPhysicalVerification.md` — physical acceptance record.

### Tests

- `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift` — XcodeGen, source boundary, bundle, scheme, privacy, and release contracts.
- `Tests/KnitNoteCoreTests/KnittingCalculatorLocalizationContractTests.swift` — complete English/Traditional Chinese catalogs and format placeholders.
- `Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift` — navigation, accessibility, promotion placement, and result-action contracts.
- `KnittingCalculatorTests/CalculatorPreferencesStoreTests.swift` — draft persistence/reset and locale defaults.
- `KnittingCalculatorTests/LocalizedNumberCodecTests.swift` — locale parsing/formatting.
- `KnittingCalculatorTests/CalculatorShareTextTests.swift` — localized deterministic result text.
- `KnittingCalculatorTests/KnitNoteLinkRouterTests.swift` — open/fallback decisions without calling external UI.
- `KnittingCalculatorTests/RatingEligibilityTests.swift` — valid calculation threshold and version limit.

---

### Task 1: Independent app and test targets

**Files:**
- Create: `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`
- Modify: `project.yml`
- Create: `KnittingCalculator/Info.plist`
- Create: `KnittingCalculator/PrivacyInfo.xcprivacy`
- Create: `KnittingCalculator/Localization/InfoPlist.xcstrings`
- Create: `KnittingCalculator/App/KnittingCalculatorApp.swift`
- Create: `KnittingCalculator/App/CalculatorRootView.swift`
- Create: `KnittingCalculator/Assets.xcassets/Contents.json`
- Create: `KnittingCalculatorTests/TargetSmokeTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Create through XcodeGen: `KnitNote.xcodeproj/xcshareddata/xcschemes/KnittingCalculator.xcscheme`

**Interfaces:**
- Consumes: `GaugeCalculator`, `EvenStitchAdjustmentCalculator`, `EvenStitchAdjustmentInputParser`, and `RowIntervalAdjustmentCalculator` from `Sources/KnitNoteCore/Calculators/`.
- Produces: buildable `KnittingCalculator` and `KnittingCalculatorTests` targets and a shared `KnittingCalculator` scheme.

- [ ] **Step 1: Write the failing project contract**

```swift
import Foundation
import Testing

@Suite struct KnittingCalculatorProjectContractTests {
    @Test func projectDefinesIsolatedFreeAppAndTestTargets() throws {
        let yaml = try source("project.yml")
        #expect(yaml.contains("  KnittingCalculator:\n    type: application\n    platform: iOS"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnittingCalculator"))
        #expect(yaml.contains("MARKETING_VERSION: 1.0.0"))
        #expect(yaml.contains("CURRENT_PROJECT_VERSION: 1"))
        #expect(yaml.contains("  KnittingCalculatorTests:\n    type: bundle.unit-test"))
        #expect(yaml.contains("- target: KnittingCalculator"))
        #expect(yaml.contains("  KnittingCalculator:\n    build:"))
    }

    @Test func freeAppCompilesOnlyCalculatorCoreFiles() throws {
        let yaml = try source("project.yml")
        for path in [
            "Sources/KnitNoteCore/Calculators/GaugeCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentInputParser.swift",
            "Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift",
        ] {
            #expect(yaml.contains("- path: \(path)"))
        }
        let target = try #require(
            yaml.split(separator: "  KnittingCalculatorTests:").first?
                .split(separator: "  KnittingCalculator:").last
        )
        #expect(!target.contains("Sources/KnitNoteCore/Projects"))
        #expect(!target.contains("Sources/KnitNoteCore/Yarn"))
        #expect(!target.contains("KnitNoteWatch"))
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: path),
            encoding: .utf8
        )
    }
}
```

- [ ] **Step 2: Run the contract and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorProjectContractTests
```

Expected: FAIL because `project.yml` has no `KnittingCalculator` target.

- [ ] **Step 3: Add exact target boundaries to `project.yml`**

Add:

```yaml
  KnittingCalculator:
    type: application
    platform: iOS
    info:
      path: KnittingCalculator/Info.plist
      properties:
        CFBundleDisplayName: $(PRODUCT_NAME)
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSApplicationCategoryType: public.app-category.utilities
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
    sources:
      - path: KnittingCalculator
        excludes:
          - Info.plist
          - PrivacyInfo.xcprivacy
          - Localization/InfoPlist.xcstrings
      - path: KnittingCalculator/PrivacyInfo.xcprivacy
        buildPhase: resources
      - path: KnittingCalculator/Localization/InfoPlist.xcstrings
        buildPhase: resources
      - path: Sources/KnitNoteCore/Calculators/GaugeCalculator.swift
      - path: Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift
      - path: Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentInputParser.swift
      - path: Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnittingCalculator
        PRODUCT_MODULE_NAME: KnittingCalculator
        MARKETING_VERSION: 1.0.0
        CURRENT_PROJECT_VERSION: 1
        PRODUCT_NAME: KnittingCalculator
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
  KnittingCalculatorTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: KnittingCalculatorTests
    dependencies:
      - target: KnittingCalculator
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnittingCalculatorTests
        GENERATE_INFOPLIST_FILE: YES
```

Add the scheme:

```yaml
  KnittingCalculator:
    build:
      targets:
        KnittingCalculator: all
        KnittingCalculatorTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - KnittingCalculatorTests
```

- [ ] **Step 4: Create the minimal app, display-name catalog, and privacy manifest**

```swift
import SwiftUI

@main
struct KnittingCalculatorApp: App {
    var body: some Scene {
        WindowGroup {
            CalculatorRootView()
        }
    }
}
```

```swift
import SwiftUI

struct CalculatorRootView: View {
    var body: some View {
        NavigationStack {
            Text("Knitting Calculator")
        }
    }
}
```

Use this privacy-manifest shape, with no collected data or tracking and only the UserDefaults reason:

```xml
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyTrackingDomains</key><array/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>CA92.1</string></array>
  </dict>
</array>
```

Create `InfoPlist.xcstrings` with exactly:

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "CFBundleDisplayName" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Knitting Calculator" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "編織計算器" } }
      }
    }
  },
  "version" : "1.0"
}
```

- [ ] **Step 5: Add the app-test smoke test**

```swift
import XCTest
@testable import KnittingCalculator

final class TargetSmokeTests: XCTestCase {
    func testSharedGaugeCoreIsLinked() {
        let result = GaugeCalculator.calculate(
            .init(sampleLength: 10, sampleCount: 20, targetLength: 40)
        )
        XCTAssertEqual(result?.recommendedCount, 80)
    }
}
```

- [ ] **Step 6: Generate, test, and build**

Run:

```bash
xcodegen generate
swift test --filter KnittingCalculatorProjectContractTests
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorTask1 CODE_SIGNING_ALLOWED=NO
```

Expected: XcodeGen succeeds, the package contract passes, the smoke test passes, and `xcodebuild` exits 0.

- [ ] **Step 7: Commit**

```bash
git add project.yml KnitNote.xcodeproj KnittingCalculator KnittingCalculatorTests Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift
git commit -m "feat: scaffold free knitting calculator target"
```

---

### Task 2: Locale-safe drafts and persistence

**Files:**
- Modify: `Sources/KnitNoteCore/Calculators/GaugeCalculator.swift`
- Modify: `Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift`
- Modify: `Tests/KnitNoteCoreTests/GaugeCalculatorTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RowIntervalAdjustmentCalculatorTests.swift`
- Create: `KnittingCalculator/Model/CalculatorPreferencesStore.swift`
- Create: `KnittingCalculator/Model/LocalizedNumberCodec.swift`
- Create: `KnittingCalculatorTests/CalculatorPreferencesStoreTests.swift`
- Create: `KnittingCalculatorTests/LocalizedNumberCodecTests.swift`
- Modify: `KnittingCalculator/App/KnittingCalculatorApp.swift`

**Interfaces:**
- Produces: `GaugeDraft`, `OneRowAdjustmentDraft`, `RowIntervalAdjustmentDraft`.
- Produces: `@MainActor CalculatorPreferencesStore`, with `gauge`, `oneRow`, `rowInterval`, `validCalculationCount`, `ratingAttemptVersion`, `recordValidCalculation()`, and `resetDrafts()`.
- Produces: `LocalizedNumberCodec.parseDecimal(_:)`, `parsePositiveInteger(_:)`, and `format(_:)`.

- [ ] **Step 1: Add failing persistence and locale tests**

```swift
import XCTest
@testable import KnittingCalculator

@MainActor
final class CalculatorPreferencesStoreTests: XCTestCase {
    func testDraftsRoundTripAndResetWithoutTouchingCounters() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        var store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "zh_TW"))
        store.gauge.sampleWidth = "10"
        store.oneRow.reservesEdgeStitches = false
        store.recordValidCalculation()

        store = CalculatorPreferencesStore(defaults: defaults, locale: Locale(identifier: "zh_TW"))
        XCTAssertEqual(store.gauge.sampleWidth, "10")
        XCTAssertFalse(store.oneRow.reservesEdgeStitches)
        XCTAssertEqual(store.validCalculationCount, 1)

        store.resetDrafts()
        XCTAssertEqual(store.gauge.sampleWidth, "")
        XCTAssertTrue(store.oneRow.reservesEdgeStitches)
        XCTAssertEqual(store.validCalculationCount, 1)
    }

    func testFirstUnitUsesUSRegionOnlyForInches() {
        XCTAssertEqual(CalculatorPreferencesStore.initialUnit(for: Locale(identifier: "en_US")), .inches)
        XCTAssertEqual(CalculatorPreferencesStore.initialUnit(for: Locale(identifier: "zh_TW")), .centimeters)
        XCTAssertEqual(CalculatorPreferencesStore.initialUnit(for: Locale(identifier: "en_GB")), .centimeters)
    }
}
```

```swift
import XCTest
@testable import KnittingCalculator

final class LocalizedNumberCodecTests: XCTestCase {
    func testParsesEitherDecimalSeparatorAndRejectsInvalidValues() {
        let codec = LocalizedNumberCodec(locale: Locale(identifier: "zh_TW"))
        XCTAssertEqual(codec.parseDecimal("10,5"), 10.5)
        XCTAssertEqual(codec.parseDecimal("10.5"), 10.5)
        XCTAssertNil(codec.parseDecimal("0"))
        XCTAssertNil(codec.parseDecimal("-2"))
        XCTAssertNil(codec.parseDecimal("12x"))
        XCTAssertEqual(codec.parsePositiveInteger("12"), 12)
        XCTAssertNil(codec.parsePositiveInteger("12.5"))
    }
}
```

- [ ] **Step 2: Run app tests and verify RED**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorTask2Red CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because the store, drafts, and codec do not exist.

- [ ] **Step 3: Make persisted core option enums Codable**

Change:

```swift
public enum GaugeLengthUnit: String, CaseIterable, Codable, Sendable {
    case centimeters
    case inches
}

public enum RowIntervalAdjustmentOperation: String, Codable, Equatable, Sendable {
    case increase
    case decrease
}

public enum RowIntervalAdjustmentStyle: String, Codable, Equatable, Sendable {
    case singleSide
    case bothSides
}
```

Add package tests that JSON-encode and decode `.inches`, `.decrease`, and `.bothSides`, then run:

```bash
swift test --filter GaugeCalculatorTests
swift test --filter RowIntervalAdjustmentCalculatorTests
```

Expected: PASS.

- [ ] **Step 4: Implement exact draft types and store**

```swift
struct GaugeDraft: Codable, Equatable {
    var unit: GaugeLengthUnit
    var sampleWidth = ""
    var sampleStitches = ""
    var targetWidth = ""
    var sampleHeight = ""
    var sampleRows = ""
    var targetHeight = ""
}

struct OneRowAdjustmentDraft: Codable, Equatable {
    var currentStitches = ""
    var targetStitches = ""
    var reservesEdgeStitches = true
}

struct RowIntervalAdjustmentDraft: Codable, Equatable {
    var totalRows = ""
    var totalStitches = ""
    var operation: RowIntervalAdjustmentOperation = .increase
    var style: RowIntervalAdjustmentStyle = .singleSide
}
```

`CalculatorPreferencesStore` uses injected `UserDefaults`, JSON-encodes each draft under keys prefixed `knittingCalculator.`, and persists in `didSet`. `resetDrafts()` restores empty drafts and preserves the rating/calculation counters. `recordValidCalculation()` uses a saturating increment:

```swift
validCalculationCount = min(validCalculationCount + 1, 5)
```

- [ ] **Step 5: Implement strict localized parsing**

`LocalizedNumberCodec` must set `NumberFormatter.isLenient = false`, disable grouping, normalize the alternate decimal separator, require finite values greater than zero, reject fractional integers, and format with zero through four fraction digits:

```swift
struct LocalizedNumberCodec {
    let locale: Locale

    func parseDecimal(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.isLenient = false
        let decimal = formatter.decimalSeparator ?? "."
        let alternate = decimal == "." ? "," : "."
        let localized = trimmed.replacingOccurrences(of: alternate, with: decimal)
        guard let value = formatter.number(from: localized)?.doubleValue,
              value.isFinite,
              value > 0 else { return nil }
        return value
    }

    func parsePositiveInteger(_ text: String) -> Int? {
        guard let value = parseDecimal(text),
              value.rounded(.towardZero) == value,
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }
}
```

- [ ] **Step 6: Inject the store at the app root**

```swift
@main
struct KnittingCalculatorApp: App {
    @StateObject private var preferences = CalculatorPreferencesStore(
        defaults: .standard,
        locale: .current
    )

    var body: some Scene {
        WindowGroup {
            CalculatorRootView()
                .environmentObject(preferences)
        }
    }
}
```

- [ ] **Step 7: Run focused and full tests**

Run:

```bash
swift test --filter GaugeCalculatorTests
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorTask2 CODE_SIGNING_ALLOWED=NO
```

Expected: package and app-target tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/KnitNoteCore/Calculators/GaugeCalculator.swift Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift Tests/KnitNoteCoreTests/GaugeCalculatorTests.swift Tests/KnitNoteCoreTests/RowIntervalAdjustmentCalculatorTests.swift KnittingCalculator/Model KnittingCalculatorTests KnittingCalculator/App/KnittingCalculatorApp.swift
git commit -m "feat: persist calculator drafts locally"
```

---

### Task 3: Gauge calculator screen

**Files:**
- Create: `KnittingCalculator/Components/CalculatorField.swift`
- Create: `KnittingCalculator/Gauge/GaugeCalculatorScreen.swift`
- Create: `Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift`
- Create: `KnittingCalculatorTests/GaugeDraftBehaviorTests.swift`

**Interfaces:**
- Consumes: `CalculatorPreferencesStore.gauge`, `LocalizedNumberCodec`, `GaugeCalculator`.
- Produces: `GaugeCalculatorScreen` and `GaugeShareSnapshot?`.

- [ ] **Step 1: Write failing gauge behavior and source contracts**

```swift
@Test func gaugeScreenShowsExactRecommendationAndOptionalRows() throws {
    let source = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
    #expect(source.contains("GaugeCalculator.calculate"))
    #expect(source.contains("result.exactCount"))
    #expect(source.contains("result.recommendedCount"))
    #expect(source.contains("rowsWereStarted"))
    #expect(source.contains("GaugeCalculator.convertLength"))
    #expect(source.contains("calculator.gauge.patternCaution"))
    #expect(source.contains("accessibilityElement(children: .combine)"))
}
```

```swift
import XCTest
@testable import KnittingCalculator

final class GaugeDraftBehaviorTests: XCTestCase {
    func testConvertingUnitChangesLengthsButNotCounts() {
        var draft = GaugeDraft(
            unit: .centimeters,
            sampleWidth: "10",
            sampleStitches: "20",
            targetWidth: "40",
            sampleHeight: "5",
            sampleRows: "12",
            targetHeight: "30"
        )
        GaugeDraftConverter.convert(
            &draft,
            to: .inches,
            codec: LocalizedNumberCodec(locale: Locale(identifier: "en_US"))
        )
        XCTAssertEqual(draft.sampleStitches, "20")
        XCTAssertEqual(draft.sampleRows, "12")
        XCTAssertEqual(draft.unit, .inches)
        XCTAssertEqual(Double(draft.sampleWidth)!, 3.937, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorViewContractTests
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorGaugeRed CODE_SIGNING_ALLOWED=NO
```

Expected: tests fail because the gauge screen, field, and converter do not exist.

- [ ] **Step 3: Implement the reusable field**

`CalculatorField` accepts `LocalizedStringKey`, a string binding, decimal/integer keyboard choice, and optional localized validation text. It places the error immediately below the field, uses `.textFieldStyle(.roundedBorder)`, a minimum 44-point hit height, and never uses placeholder-only labeling.

```swift
struct CalculatorField: View {
    enum InputKind { case decimal, integer }
    let title: LocalizedStringKey
    @Binding var text: String
    let kind: InputKind
    let validationKey: LocalizedStringKey?
}
```

- [ ] **Step 4: Implement gauge calculation and conversion**

Bind directly to `preferences.gauge`. Use two cards: stitches and optional rows. Calculate a group only when all three values parse. Mark every field invalid only after its group is started. `GaugeDraftConverter.convert` parses and converts the four length strings only:

```swift
enum GaugeDraftConverter {
    static func convert(
        _ draft: inout GaugeDraft,
        to newUnit: GaugeLengthUnit,
        codec: LocalizedNumberCodec
    ) {
        let oldUnit = draft.unit
        guard oldUnit != newUnit else { return }
        for keyPath in [
            \GaugeDraft.sampleWidth,
            \GaugeDraft.targetWidth,
            \GaugeDraft.sampleHeight,
            \GaugeDraft.targetHeight,
        ] {
            if let value = codec.parseDecimal(draft[keyPath: keyPath]) {
                draft[keyPath: keyPath] = codec.format(
                    GaugeCalculator.convertLength(value, from: oldUnit, to: newUnit)
                )
            }
        }
        draft.unit = newUnit
    }
}
```

- [ ] **Step 5: Show complete, accessible results and count distinct valid calculations**

Define the share snapshot in `GaugeCalculatorScreen.swift`:

```swift
struct GaugeShareSnapshot: Equatable {
    struct Rows: Equatable {
        let sampleLength: Double
        let sampleCount: Double
        let targetLength: Double
        let result: GaugeResult
    }

    let unit: GaugeLengthUnit
    let sampleLength: Double
    let sampleCount: Double
    let targetLength: Double
    let result: GaugeResult
    let rows: Rows?
}
```

For each valid group display density, exact count, recommended count, and the pattern caution. Keep the result in a combined VoiceOver element with an explicit accessibility label. Expose `GaugeShareSnapshot?` only when the stitches group is valid; include `rows` only when the optional group is valid.

Track the last valid snapshot in view-local state and count only a changed non-nil snapshot:

```swift
@State private var lastCountedSnapshot: GaugeShareSnapshot?

.onChange(of: shareSnapshot) { _, newValue in
    guard let newValue, newValue != lastCountedSnapshot else { return }
    lastCountedSnapshot = newValue
    preferences.recordValidCalculation()
}
```

- [ ] **Step 6: Run tests and both device-size builds**

Run:

```bash
swift test --filter KnittingCalculatorViewContractTests
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorGauge CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath /tmp/KnittingCalculatorGaugePad CODE_SIGNING_ALLOWED=NO
```

Expected: contracts and app tests pass; both builds exit 0.

- [ ] **Step 7: Commit**

```bash
git add KnittingCalculator/Components/CalculatorField.swift KnittingCalculator/Gauge KnittingCalculatorTests/GaugeDraftBehaviorTests.swift Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift
git commit -m "feat: add persistent gauge calculator"
```

---

### Task 4: One-row and across-rows adjustment screens

**Files:**
- Create: `KnittingCalculator/Adjustment/AdjustmentCalculatorScreen.swift`
- Create: `KnittingCalculator/Adjustment/OneRowAdjustmentView.swift`
- Create: `KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift`
- Create: `KnittingCalculatorTests/AdjustmentPresentationTests.swift`

**Interfaces:**
- Consumes: persisted adjustment drafts and all three existing adjustment parser/calculator APIs.
- Produces: `AdjustmentCalculatorScreen`, `OneRowShareSnapshot?`, and `RowIntervalShareSnapshot?`.

- [ ] **Step 1: Add failing adjustment contracts**

```swift
@Test func adjustmentScreensKeepBothModesAndNeutralSteps() throws {
    let root = try freeAppSource("Adjustment/AdjustmentCalculatorScreen.swift")
    let oneRow = try freeAppSource("Adjustment/OneRowAdjustmentView.swift")
    let rows = try freeAppSource("Adjustment/RowIntervalAdjustmentView.swift")
    #expect(root.contains("adjustment.mode.oneRow"))
    #expect(root.contains("adjustment.mode.acrossRows"))
    #expect(oneRow.contains("reservesEdgeStitches"))
    #expect(oneRow.contains("DisclosureGroup"))
    #expect(oneRow.contains("EvenStitchAdjustmentCalculator.calculate"))
    #expect(rows.contains("RowIntervalAdjustmentCalculator.calculate"))
    #expect(rows.contains("RowIntervalAdjustmentStyle.bothSides"))
    #expect(!oneRow.contains("Knit "))
}
```

Add the exact neutral presentation types:

```swift
enum AdjustmentStepToken: Equatable {
    case edge(Int)
    case work(Int)
    case increaseOne
    case decreaseOne
}

enum AdjustmentStepText {
    static func token(for step: EvenStitchStep) -> AdjustmentStepToken {
        switch step {
        case .edge(let count): .edge(count)
        case .knit(let count): .work(count)
        case .increaseOne: .increaseOne
        case .decreaseOne: .decreaseOne
        }
    }
}
```

Add presentation tests that assert:

```swift
XCTAssertEqual(AdjustmentStepText.token(for: .increaseOne), .increaseOne)
XCTAssertEqual(AdjustmentStepText.token(for: .decreaseOne), .decreaseOne)
XCTAssertEqual(AdjustmentStepText.token(for: .knit(7)), .work(7))
XCTAssertEqual(AdjustmentStepText.token(for: .edge(1)), .edge(1))
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter adjustmentScreensKeepBothModesAndNeutralSteps
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorAdjustmentRed CODE_SIGNING_ALLOWED=NO
```

Expected: missing-file/type failures.

- [ ] **Step 3: Implement the mode container**

`AdjustmentCalculatorScreen` owns only a local segmented selection:

```swift
enum AdjustmentMode: String, CaseIterable, Identifiable {
    case oneRow, acrossRows
    var id: Self { self }
}
```

Switch between the two focused child views. Draft data remains in `CalculatorPreferencesStore`, so changing modes does not clear values.

- [ ] **Step 4: Implement one-row inputs, failures, summary, and steps**

Use the existing strict input parser and calculator. Default `reservesEdgeStitches` is true. Map every failure separately:

```swift
switch failure {
case .invalidCounts: "calculator.adjustment.failure.invalidCounts"
case .exceedsSupportedLimit: "calculator.adjustment.failure.exceedsSupportedLimit"
case .cannotPreserveEdges: "calculator.adjustment.failure.cannotPreserveEdges"
case .requiresMultipleRows: "calculator.adjustment.failure.requiresMultipleRows"
}
```

The result card states whether edges are reserved. A collapsed `DisclosureGroup` renders `.edge`, `.knit`, `.increaseOne`, and `.decreaseOne` using neutral localized phrases. Do not concatenate sentence fragments.

Define:

```swift
struct OneRowShareSnapshot: Equatable {
    let current: Int
    let target: Int
    let reservesEdgeStitches: Bool
    let result: EvenStitchAdjustmentResult
}
```

Count a changed non-nil `OneRowShareSnapshot` with the same view-local `lastCountedSnapshot` pattern used by the gauge screen.

- [ ] **Step 5: Implement across-rows inputs and schedule**

Provide segmented increase/decrease selection and adaptive single-side/both-sides selection. Parse positive whole numbers. Display event count, stitches per event, exact or ranged interval, and adjustment rows. Map `.symmetricRequiresEvenStitches`, `.insufficientRows`, `.invalidCounts`, and `.exceedsSupportedLimit` to separate actionable localized errors.

Define:

```swift
struct RowIntervalShareSnapshot: Equatable {
    let input: RowIntervalAdjustmentInput
    let result: RowIntervalAdjustmentResult
}
```

Count a changed non-nil snapshot once using view-local state.

- [ ] **Step 6: Run core, contracts, and app tests**

Run:

```bash
swift test --filter EvenStitchAdjustmentCalculatorTests
swift test --filter RowIntervalAdjustmentCalculatorTests
swift test --filter KnittingCalculatorViewContractTests
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorAdjustment CODE_SIGNING_ALLOWED=NO
```

Expected: all focused suites pass.

- [ ] **Step 7: Commit**

```bash
git add KnittingCalculator/Adjustment KnittingCalculatorTests/AdjustmentPresentationTests.swift Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift
git commit -m "feat: add even increase and decrease tools"
```

---

### Task 5: Deterministic copy and system sharing

**Files:**
- Create: `KnittingCalculator/Model/CalculatorShareText.swift`
- Create: `KnittingCalculator/Components/CalculatorResultActions.swift`
- Create: `KnittingCalculatorTests/CalculatorShareTextTests.swift`
- Modify: `KnittingCalculator/Gauge/GaugeCalculatorScreen.swift`
- Modify: `KnittingCalculator/Adjustment/OneRowAdjustmentView.swift`
- Modify: `KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift`

**Interfaces:**
- Produces: `CalculatorShareText.gauge(_:locale:)`, `oneRow(_:locale:)`, and `rowInterval(_:locale:)`.
- Produces: `CalculatorResultActions(text:onSuccessfulAction:)`.

- [ ] **Step 1: Write failing share-text tests**

```swift
final class CalculatorShareTextTests: XCTestCase {
    func testGaugeShareContainsInputsResultAttributionAndFreeAppURL() {
        let text = CalculatorShareText.gauge(
            .init(unit: .centimeters, sampleLength: 10, sampleCount: 20,
                  targetLength: 40, density: 2, exactCount: 80, recommendedCount: 80),
            locale: Locale(identifier: "zh_Hant")
        )
        XCTAssertTrue(text.contains("10"))
        XCTAssertTrue(text.contains("80"))
        XCTAssertTrue(text.contains("由編織計算器計算"))
        XCTAssertTrue(text.contains(CalculatorProductLinks.freeApp.absoluteString))
        XCTAssertFalse(text.contains("KnitNote"))
    }
}
```

The numeric App Store URL cannot exist before App Store Connect creates the record. Use the product's public landing page during development:

```swift
enum CalculatorProductLinks {
    static let freeApp = URL(
        string: "https://phillon77.github.io/KnitNote/knitting-calculator.html"
    )!
}
```

Task 12 replaces this valid development link with the assigned App Store product URL and requires `https://apps.apple.com/app/id` followed by digits before release.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorShareRed CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because share types do not exist.

- [ ] **Step 3: Implement localized complete-sentence share builders**

Use `String(localized:locale:)` and `String.localizedStringWithFormat`. Share output includes tool name, input summary, result, edge/interval details, attribution, and free-app URL. It never includes the KnitNote name or URL.

```swift
enum CalculatorShareText {
    static func gauge(_ snapshot: GaugeShareSnapshot, locale: Locale) -> String
    static func oneRow(_ snapshot: OneRowShareSnapshot, locale: Locale) -> String
    static func rowInterval(_ snapshot: RowIntervalShareSnapshot, locale: Locale) -> String
}
```

- [ ] **Step 4: Implement copy/share actions**

`CalculatorResultActions` uses a `ShareLink(item: text)` and a copy button that writes to `UIPasteboard.general.string` inside `#if os(iOS)`. Both buttons have explicit VoiceOver labels and 44-point hit targets. Calculation counting already occurs when each screen produces a changed valid snapshot; copy/share actions must not increment the counter again.

- [ ] **Step 5: Run tests and contract checks**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorShare CODE_SIGNING_ALLOWED=NO
swift test --filter KnittingCalculatorViewContractTests
```

Expected: share-text tests and view contracts pass.

- [ ] **Step 6: Commit**

```bash
git add KnittingCalculator/Model/CalculatorShareText.swift KnittingCalculator/Components/CalculatorResultActions.swift KnittingCalculator/Gauge KnittingCalculator/Adjustment KnittingCalculatorTests/CalculatorShareTextTests.swift Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift
git commit -m "feat: copy and share calculator results"
```

---

### Task 6: Watercolor home, help, and navigation

**Files:**
- Create: `KnittingCalculator/Theme/CalculatorTheme.swift`
- Create: `KnittingCalculator/Home/CalculatorHomeView.swift`
- Create: `KnittingCalculator/Help/CalculatorHelpSheet.swift`
- Modify: `KnittingCalculator/App/CalculatorRootView.swift`
- Modify: `KnittingCalculator/Gauge/GaugeCalculatorScreen.swift`
- Modify: `KnittingCalculator/Adjustment/AdjustmentCalculatorScreen.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift`

**Interfaces:**
- Produces: `CalculatorTheme`, `CalculatorWatercolorBackground`, `CalculatorCard`, `CalculatorHomeView`, and `CalculatorHelpSheet`.

- [ ] **Step 1: Add failing visual/navigation contracts**

```swift
@Test func homeHasExactlyTwoToolDestinationsAndOnePromotionSlot() throws {
    let source = try freeAppSource("Home/CalculatorHomeView.swift")
    #expect(source.components(separatedBy: "NavigationLink").count - 1 == 2)
    #expect(source.contains("GaugeCalculatorScreen()"))
    #expect(source.contains("AdjustmentCalculatorScreen()"))
    #expect(source.components(separatedBy: "KnitNotePromotionCard").count - 1 == 1)
    #expect(source.contains("frame(maxWidth: 620)"))
}

@Test func toolScreensExposeSinglePageHelp() throws {
    let gauge = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
    let adjustment = try freeAppSource("Adjustment/AdjustmentCalculatorScreen.swift")
    #expect(gauge.contains("CalculatorHelpSheet(tool: .gauge)"))
    #expect(adjustment.contains("CalculatorHelpSheet(tool: .adjustment)"))
}
```

- [ ] **Step 2: Run contract and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorViewContractTests
```

Expected: FAIL because home, help, and theme files do not exist.

- [ ] **Step 3: Implement the approved visual system**

Use:

```swift
enum CalculatorTheme {
    static let ink = Color(red: 0.20, green: 0.17, blue: 0.25)
    static let berry = Color(red: 0.43, green: 0.29, blue: 0.61)
    static let lavender = Color(red: 0.76, green: 0.67, blue: 0.91)
    static let sky = Color(red: 0.73, green: 0.83, blue: 0.98)
    static let blush = Color(red: 0.96, green: 0.87, blue: 0.94)
}
```

The watercolor background uses low-opacity radial gradients over the system background. Cards retain solid or material-backed readable surfaces. Verify text contrast in light/dark/high-contrast modes; never place text directly over decorative gradients.

- [ ] **Step 4: Implement home and root navigation**

The root is a `NavigationStack` containing `CalculatorHomeView`. Home has the localized heading, exactly two vertically stacked tool cards, one promotion card below them, and a toolbar Settings button. Cap readable content at 620 points and keep a single column at every size.

- [ ] **Step 5: Implement one-page contextual help**

`CalculatorHelpSheet.Tool` has `.gauge` and `.adjustment`. Each sheet contains a short purpose, one exact worked example, and a dismiss button. It must not collect input or become onboarding.

- [ ] **Step 6: Run contracts and builds**

Run:

```bash
swift test --filter KnittingCalculatorViewContractTests
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorHomePhone CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath /tmp/KnittingCalculatorHomePad CODE_SIGNING_ALLOWED=NO
```

Expected: contracts pass and both builds exit 0.

- [ ] **Step 7: Commit**

```bash
git add KnittingCalculator/Theme KnittingCalculator/Home KnittingCalculator/Help KnittingCalculator/App/CalculatorRootView.swift KnittingCalculator/Gauge KnittingCalculator/Adjustment Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift
git commit -m "feat: build watercolor calculator navigation"
```

---

### Task 7: KnitNote routing and Settings

**Files:**
- Modify: `project.yml`
- Create: `KnittingCalculator/Model/KnitNoteLinkRouter.swift`
- Create: `KnittingCalculator/Home/KnitNotePromotionCard.swift`
- Create: `KnittingCalculator/Settings/CalculatorSettingsView.swift`
- Create: `KnittingCalculatorTests/KnitNoteLinkRouterTests.swift`
- Modify: `KnittingCalculator/Home/CalculatorHomeView.swift`
- Modify: `KnittingCalculator/App/CalculatorRootView.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift`

**Interfaces:**
- Produces: `KnitNoteLinkDestination`, `KnitNoteLinkRouter.destination(after:)`, and `KnitNotePromotionCard`.
- Consumes: `CalculatorPreferencesStore.resetDrafts()`.

- [ ] **Step 1: Write failing routing and placement tests**

```swift
final class KnitNoteLinkRouterTests: XCTestCase {
    func testFallsBackOnlyWhenCustomSchemeCannotOpen() {
        XCTAssertEqual(KnitNoteLinkRouter.destination(after: true), .finished)
        XCTAssertEqual(
            KnitNoteLinkRouter.destination(after: false),
            .openStore(URL(string: "https://apps.apple.com/app/id6793023054")!)
        )
    }
}
```

```swift
@Test func promotionExistsOnlyOnHomeAndSettings() throws {
    let home = try freeAppSource("Home/CalculatorHomeView.swift")
    let settings = try freeAppSource("Settings/CalculatorSettingsView.swift")
    let gauge = try freeAppSource("Gauge/GaugeCalculatorScreen.swift")
    let oneRow = try freeAppSource("Adjustment/OneRowAdjustmentView.swift")
    #expect(home.contains("KnitNotePromotionCard"))
    #expect(settings.contains("KnitNotePromotionCard"))
    #expect(!gauge.contains("KnitNotePromotionCard"))
    #expect(!oneRow.contains("KnitNotePromotionCard"))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorLinksRed CODE_SIGNING_ALLOWED=NO
swift test --filter promotionExistsOnlyOnHomeAndSettings
```

Expected: missing router/card/settings failures.

- [ ] **Step 3: Register the existing KnitNote launch scheme**

Add to the existing `KnitNote` target info properties:

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: com.phillon.KnitNote
            CFBundleURLSchemes:
              - knitnote
```

The free app opens `knitnote://` first. Use `UIApplication.shared.open(_:options:completionHandler:)`; on `false`, open the exact App Store URL. Do not use `canOpenURL`, so no `LSApplicationQueriesSchemes` declaration is needed.

Use these exact routing types so the fallback decision remains unit-testable:

```swift
enum KnitNoteLinkDestination: Equatable {
    case finished
    case openStore(URL)
}

enum KnitNoteLinkRouter {
    static let launchURL = URL(string: "knitnote://")!
    static let storeURL = URL(string: "https://apps.apple.com/app/id6793023054")!

    static func destination(after opened: Bool) -> KnitNoteLinkDestination {
        opened ? .finished : .openStore(storeURL)
    }
}
```

- [ ] **Step 4: Implement the card and Settings**

The promotion card displays the approved copy and one localized action. Settings contains:

- unit picker bound to `preferences.gauge.unit`
- reset button with a destructive confirmation dialog
- the same KnitNote promotion card
- `mailto:lzz.1999@icloud.com`
- `https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html`
- app version/build read from `Bundle.main`

Reset calls only `preferences.resetDrafts()`.

- [ ] **Step 5: Regenerate and verify both products**

Run:

```bash
xcodegen generate
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorLinks CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteURLScheme CODE_SIGNING_ALLOWED=NO
swift test --filter KnittingCalculatorViewContractTests
```

Expected: free-app tests pass, KnitNote still builds, and contracts pass.

- [ ] **Step 6: Commit**

```bash
git add project.yml KnitNote.xcodeproj KnittingCalculator/Model/KnitNoteLinkRouter.swift KnittingCalculator/Home KnittingCalculator/Settings KnittingCalculator/App/CalculatorRootView.swift KnittingCalculatorTests/KnitNoteLinkRouterTests.swift Tests/KnitNoteCoreTests/KnittingCalculatorViewContractTests.swift
git commit -m "feat: add respectful KnitNote promotion"
```

---

### Task 8: Rating eligibility

**Files:**
- Create: `KnittingCalculator/Model/RatingEligibility.swift`
- Create: `KnittingCalculatorTests/RatingEligibilityTests.swift`
- Modify: `KnittingCalculator/App/KnittingCalculatorApp.swift`
- Modify: `KnittingCalculator/App/CalculatorRootView.swift`
- Modify: `KnittingCalculator/Model/CalculatorPreferencesStore.swift`

**Interfaces:**
- Produces: `RatingEligibility.shouldRequest(validCount:attemptVersion:currentVersion:)`.
- Produces: `RatingRequestCoordinator.considerRequest()` using `AppStore.requestReview(in:)`.

- [ ] **Step 1: Write failing policy tests**

```swift
final class RatingEligibilityTests: XCTestCase {
    func testRequiresFiveCalculationsAndOncePerVersion() {
        XCTAssertFalse(RatingEligibility.shouldRequest(
            validCount: 4, attemptVersion: nil, currentVersion: "1.0.0"
        ))
        XCTAssertTrue(RatingEligibility.shouldRequest(
            validCount: 5, attemptVersion: nil, currentVersion: "1.0.0"
        ))
        XCTAssertFalse(RatingEligibility.shouldRequest(
            validCount: 5, attemptVersion: "1.0.0", currentVersion: "1.0.0"
        ))
        XCTAssertTrue(RatingEligibility.shouldRequest(
            validCount: 5, attemptVersion: "1.0.0", currentVersion: "1.1.0"
        ))
    }
}
```

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorRatingRed CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `RatingEligibility` does not exist.

- [ ] **Step 3: Implement pure policy and coordinator**

```swift
enum RatingEligibility {
    static func shouldRequest(
        validCount: Int,
        attemptVersion: String?,
        currentVersion: String
    ) -> Bool {
        validCount >= 5 && attemptVersion != currentVersion
    }
}
```

Add this store method:

```swift
func markRatingAttempt(version: String) {
    ratingAttemptVersion = version
}
```

Implement:

```swift
import StoreKit
import UIKit

@MainActor
final class RatingRequestCoordinator: ObservableObject {
    private let preferences: CalculatorPreferencesStore

    init(preferences: CalculatorPreferencesStore) {
        self.preferences = preferences
    }

    func considerRequest(in scene: UIWindowScene) {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        guard RatingEligibility.shouldRequest(
            validCount: preferences.validCalculationCount,
            attemptVersion: preferences.ratingAttemptVersion,
            currentVersion: version
        ) else { return }
        preferences.markRatingAttempt(version: version)
        AppStore.requestReview(in: scene)
    }
}
```

Each calculator screen sets a view-local `hadValidResult` when it produces a result. On disappearing, it calls the coordinator only when `hadValidResult` is true. The coordinator never displays a custom rating prompt.

Construct both shared objects from the same store instance:

```swift
@main
struct KnittingCalculatorApp: App {
    @StateObject private var preferences: CalculatorPreferencesStore
    @StateObject private var ratingCoordinator: RatingRequestCoordinator

    init() {
        let preferences = CalculatorPreferencesStore(
            defaults: .standard,
            locale: .current
        )
        _preferences = StateObject(wrappedValue: preferences)
        _ratingCoordinator = StateObject(
            wrappedValue: RatingRequestCoordinator(preferences: preferences)
        )
    }

    var body: some Scene {
        WindowGroup {
            CalculatorRootView()
                .environmentObject(preferences)
                .environmentObject(ratingCoordinator)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorRating CODE_SIGNING_ALLOWED=NO
```

Expected: rating policy tests pass.

- [ ] **Step 5: Commit**

```bash
git add KnittingCalculator/Model/RatingEligibility.swift KnittingCalculator/Model/CalculatorPreferencesStore.swift KnittingCalculator/App/KnittingCalculatorApp.swift KnittingCalculator/App/CalculatorRootView.swift KnittingCalculatorTests/RatingEligibilityTests.swift
git commit -m "feat: add restrained review request policy"
```

---

### Task 9: Complete localization and accessibility contracts

**Files:**
- Create: `KnittingCalculator/Localization/Localizable.xcstrings`
- Modify: `KnittingCalculator/Localization/InfoPlist.xcstrings`
- Create: `Tests/KnitNoteCoreTests/KnittingCalculatorLocalizationContractTests.swift`
- Modify: `KnittingCalculator/App/CalculatorRootView.swift`
- Modify: `KnittingCalculator/Components/CalculatorField.swift`
- Modify: `KnittingCalculator/Components/CalculatorResultActions.swift`
- Modify: `KnittingCalculator/Home/CalculatorHomeView.swift`
- Modify: `KnittingCalculator/Home/KnitNotePromotionCard.swift`
- Modify: `KnittingCalculator/Gauge/GaugeCalculatorScreen.swift`
- Modify: `KnittingCalculator/Adjustment/AdjustmentCalculatorScreen.swift`
- Modify: `KnittingCalculator/Adjustment/OneRowAdjustmentView.swift`
- Modify: `KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift`
- Modify: `KnittingCalculator/Help/CalculatorHelpSheet.swift`
- Modify: `KnittingCalculator/Settings/CalculatorSettingsView.swift`

**Interfaces:**
- Produces: complete `en` and `zh-Hant` values for every free-app key and format variation.

- [ ] **Step 1: Write the failing catalog completeness test**

```swift
import Foundation
import Testing

@Test func everyFreeAppStringHasEnglishAndTraditionalChinese() throws {
    let strings = try stringEntries(
        at: "KnittingCalculator/Localization/Localizable.xcstrings"
    )
    for (key, entry) in strings {
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for locale in ["en", "zh-Hant"] {
            let localized = try #require(localizations[locale])
            let values = leafValues(in: localized)
            #expect(!values.isEmpty, "Missing \(locale): \(key)")
            #expect(values.allSatisfy { !$0.isEmpty }, "Empty \(locale): \(key)")
        }
        let english = leafValues(in: try #require(localizations["en"]))
        let chinese = leafValues(in: try #require(localizations["zh-Hant"]))
        #expect(
            english.flatMap(formatTokens).sorted()
                == chinese.flatMap(formatTokens).sorted(),
            "Format mismatch: \(key)"
        )
    }
}

@Test func displayNameIsLocalized() throws {
    let entry = try #require(
        stringEntries(at: "KnittingCalculator/Localization/InfoPlist.xcstrings")
            ["CFBundleDisplayName"]
    )
    let localizations = try #require(entry["localizations"] as? [String: Any])
    #expect(leafValues(in: try #require(localizations["en"])) == ["Knitting Calculator"])
    #expect(leafValues(in: try #require(localizations["zh-Hant"])) == ["編織計算器"])
}

private func stringEntries(at relativePath: String) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: localizationRepositoryRoot.appending(path: relativePath))
    let root = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    return try #require(root["strings"] as? [String: [String: Any]])
}

private func leafValues(in value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        let direct = dictionary["value"] as? String
        return (direct.map { [$0] } ?? [])
            + dictionary.flatMap { key, child in
                key == "value" ? [] : leafValues(in: child)
            }
    }
    if let array = value as? [Any] {
        return array.flatMap(leafValues)
    }
    return []
}

private func formatTokens(in value: String) -> [String] {
    let expression = try! NSRegularExpression(
        pattern: #"%(\d+\$)?[-+ #0]*(\d+|\*)?(\.\d+)?(hh|h|ll|l|L|z|t|j)?[@diuoxXfFeEgGaAcCsSp]"#
    )
    let range = NSRange(value.startIndex..., in: value)
    return expression.matches(in: value, range: range).compactMap {
        Range($0.range, in: value).map { String(value[$0]) }
    }
}

private let localizationRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
```

- [ ] **Step 2: Run localization tests and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorLocalizationContractTests
```

Expected: FAIL because the catalogs do not exist.

- [ ] **Step 3: Add the exact English and Traditional Chinese catalog**

Add these static keys:

| Key | English | Traditional Chinese |
|---|---|---|
| `app.home.title` | What would you like to calculate? | 今天要計算什麼？ |
| `app.settings.title` | Settings | 設定 |
| `calculator.gauge.title` | Gauge Calculator | 密度計算 |
| `calculator.adjustment.title` | Even Increase / Decrease | 等距加針／減針 |
| `calculator.adjustment.mode.oneRow` | One Row | 單行 |
| `calculator.adjustment.mode.acrossRows` | Across Rows | 跨段 |
| `calculator.unit.title` | Unit | 單位 |
| `calculator.unit.centimeters` | Centimeters | 公分 |
| `calculator.unit.inches` | Inches | 英吋 |
| `calculator.gauge.stitches` | Stitches | 針數 |
| `calculator.gauge.rows.optional` | Rows (Optional) | 排數（選填） |
| `calculator.gauge.sampleWidth` | Swatch width | 試片寬度 |
| `calculator.gauge.sampleStitches` | Swatch stitches | 試片針數 |
| `calculator.gauge.targetWidth` | Target width | 目標寬度 |
| `calculator.gauge.sampleHeight` | Swatch height | 試片高度 |
| `calculator.gauge.sampleRows` | Swatch rows | 試片排數 |
| `calculator.gauge.targetHeight` | Target height | 目標高度 |
| `calculator.gauge.patternCaution` | Adjust the final count for pattern repeats and edge stitches. | 最終針數仍需依花樣倍數與邊針調整。 |
| `calculator.adjustment.current` | Current stitches | 目前針數 |
| `calculator.adjustment.target` | Target stitches | 目標針數 |
| `calculator.adjustment.reservesEdges` | Reserve one edge stitch on each side | 左右各保留 1 針 |
| `calculator.adjustment.rows.totalRows` | Total rows | 總排數 |
| `calculator.adjustment.rows.totalStitches` | Total stitches to adjust | 總調整針數 |
| `calculator.adjustment.rows.operation` | Operation | 調整方式 |
| `calculator.adjustment.rows.increase` | Increase | 加針 |
| `calculator.adjustment.rows.decrease` | Decrease | 減針 |
| `calculator.adjustment.rows.style` | Sides | 調整側 |
| `calculator.adjustment.rows.singleSide` | One side | 單側 |
| `calculator.adjustment.rows.bothSides` | Both sides | 雙側 |
| `calculator.result.title` | Result | 結果 |
| `calculator.result.steps.show` | Show Complete Steps | 查看完整步驟 |
| `calculator.validation.positiveNumber` | Enter a number greater than 0. | 請輸入大於 0 的數字。 |
| `calculator.validation.positiveInteger` | Enter a whole number greater than 0. | 請輸入大於 0 的整數。 |
| `calculator.failure.tooLarge` | Enter a value of 100,000 or less. | 請輸入不超過 100,000 的數值。 |
| `calculator.failure.cannotPreserveEdges` | These counts cannot reserve one stitch at each edge. Turn off edge stitches or change the counts. | 這組針數無法左右各保留 1 針，請關閉邊針或調整針數。 |
| `calculator.failure.requiresMultipleRows` | This adjustment cannot fit in one row. Use Across Rows. | 這次調整無法在單行完成，請改用跨段。 |
| `calculator.failure.symmetricEven` | Both-sides adjustment requires an even stitch count. | 雙側調整需要偶數的調整針數。 |
| `calculator.failure.insufficientRows` | There are not enough rows for this many adjustments. | 排數不足以安排這麼多次調整。 |
| `calculator.action.copy` | Copy | 複製 |
| `calculator.action.share` | Share | 分享 |
| `calculator.action.copied` | Copied | 已複製 |
| `calculator.help.title` | How It Works | 使用說明 |
| `calculator.help.gauge` | Measure a swatch, enter its size and stitch count, then enter your target size. Example: 20 stitches across 10 cm becomes 80 stitches across 40 cm. | 量好試片後輸入尺寸與針數，再輸入目標尺寸。例如：10 公分 20 針，40 公分建議 80 針。 |
| `calculator.help.adjustment` | Enter the current and target stitch counts for one row, or spread a total adjustment across rows. Example: increasing from 80 to 90 adds 10 stitches evenly. | 單行可輸入目前與目標針數，也可把總調整分配到多排。例如：80 針增加到 90 針，會平均安排 10 次加針。 |
| `calculator.help.dismiss` | Done | 完成 |
| `knitnote.promotion.body` | Need projects, counters, yarn, patterns, and a knitting journal? Discover KnitNote. | 需要管理作品、排數、毛線、織圖與編織日記？認識 KnitNote。 |
| `knitnote.promotion.action` | Open KnitNote | 開啟 KnitNote |
| `knitnote.promotion.failure` | KnitNote or the App Store could not be opened. | 無法開啟 KnitNote 或 App Store。 |
| `settings.reset.title` | Clear Remembered Inputs | 清除已記住的輸入 |
| `settings.reset.message` | This clears saved calculator values and unit choices on this device. KnitNote is not affected. | 這會清除本裝置儲存的計算數值與單位選擇，不會影響 KnitNote。 |
| `settings.reset.confirm` | Clear | 清除 |
| `settings.cancel` | Cancel | 取消 |
| `settings.feedback` | Send Feedback | 傳送意見 |
| `settings.privacy` | Privacy Policy | 隱私權政策 |
| `settings.version` | Version | 版本 |
| `share.attribution` | Calculated with Knitting Calculator | 由編織計算器計算 |

Add these formatted keys with identical placeholder order in both locales:

| Key | English | Traditional Chinese |
|---|---|---|
| `calculator.gauge.density.format` | Density: %1$@ per %2$@ | 密度：每 %2$@ 為 %1$@ |
| `calculator.gauge.exact.format` | Exact result: %@ | 精確結果：%@ |
| `calculator.gauge.recommendation.stitches.format` | Recommended: %lld stitches | 建議：%lld 針 |
| `calculator.gauge.recommendation.rows.format` | Recommended: %lld rows | 建議：%lld 排 |
| `calculator.adjustment.summary.increase.format` | Increase %lld stitches evenly. | 平均增加 %lld 針。 |
| `calculator.adjustment.summary.decrease.format` | Decrease %lld stitches evenly. | 平均減少 %lld 針。 |
| `calculator.adjustment.summary.unchanged` | No increases or decreases are needed. | 不需要加針或減針。 |
| `calculator.adjustment.edge.reserved` | One edge stitch is reserved on each side. | 左右各保留 1 針。 |
| `calculator.adjustment.edge.notReserved` | No edge stitches are reserved. | 未保留邊針。 |
| `calculator.adjustment.step.edge.format` | Edge: %lld stitch | 邊針：%lld 針 |
| `calculator.adjustment.step.work.format` | Work %lld stitches | 進行 %lld 針 |
| `calculator.adjustment.step.increase` | Increase 1 stitch | 加 1 針 |
| `calculator.adjustment.step.decrease` | Decrease the next 2 stitches to 1 | 將接下來 2 針減為 1 針 |
| `calculator.adjustment.rows.every.format` | Adjust every %lld rows. | 每 %lld 排調整一次。 |
| `calculator.adjustment.rows.range.format` | Adjust every %1$lld–%2$lld rows. | 每 %1$lld–%2$lld 排調整一次。 |
| `calculator.adjustment.rows.list.format` | Adjustment rows: %@ | 調整排數：%@ |
| `settings.version.format` | Version %@ (%@) | 版本 %@（%@） |

Share builders must assemble complete localized lines from the keys above and join them with newline characters; they must not concatenate translated sentence fragments.

- [ ] **Step 4: Audit accessibility implementation**

Add or verify:

```swift
VStack {
    Text(resultTitle)
    Text(resultSummary)
}
.accessibilityElement(children: .combine)
.accessibilityLabel(Text(resultAccessibilityLabel))

Button(action: copyResult) {
    Label("calculator.action.copy", systemImage: "doc.on.doc")
        .frame(minWidth: 44, minHeight: 44)
}
```

Do not add a restrictive `.dynamicTypeSize` modifier. Ensure errors have text/icons, selected segments expose selected state, decorative watercolor shapes are hidden, and result reading order follows input → error → result → steps.

- [ ] **Step 5: Run localization, core, and build checks**

Run:

```bash
swift test --filter KnittingCalculatorLocalizationContractTests
swift test
xcodegen generate
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorLocalization CODE_SIGNING_ALLOWED=NO
```

Expected: catalogs are complete, full package suite passes, and app tests pass.

- [ ] **Step 6: Commit**

```bash
git add KnittingCalculator/Localization KnittingCalculator Tests/KnitNoteCoreTests/KnittingCalculatorLocalizationContractTests.swift KnitNote.xcodeproj
git commit -m "feat: localize and make calculator accessible"
```

---

### Task 10: Approved B app icon

**Files:**
- Create: `KnittingCalculator/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png`
- Create: required iPhone/iPad icon renditions in `KnittingCalculator/Assets.xcassets/AppIcon.appiconset/`
- Create: `KnittingCalculator/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `Tests/KnitNoteCoreTests/KnittingCalculatorAppIconContractTests.swift`
- Create: `AppStore/KnittingCalculator/Icon/app-icon-contact-sheet.png`

**Interfaces:**
- Produces: a complete opaque sRGB icon set distinct from KnitNote and readable at 29, 40, 60, 76, 83.5, and 1024 points.

- [ ] **Step 1: Write failing icon contracts**

```swift
@Test func freeCalculatorHasIndependentCompleteIconSet() throws {
    let iconRoot = repositoryRoot.appending(path:
        "KnittingCalculator/Assets.xcassets/AppIcon.appiconset")
    let contents = try String(
        contentsOf: iconRoot.appending(path: "Contents.json"),
        encoding: .utf8
    )
    #expect(contents.contains("app-icon-1024.png"))
    #expect(contents.contains("\"idiom\" : \"ios-marketing\""))
    #expect(
        try Data(contentsOf: iconRoot.appending(path: "app-icon-1024.png"))
        != Data(contentsOf: repositoryRoot.appending(path:
            "KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png"))
    )
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
```

- [ ] **Step 2: Run contract and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorAppIconContractTests
```

Expected: FAIL because the icon set does not exist.

- [ ] **Step 3: Generate the master artwork with the approved direction**

Use the image-generation tool with this exact art direction:

```text
Square iOS app icon, no text, no border, opaque background. A clearly readable
lavender watercolor yarn ball centered on a soft powder-blue and blush-lilac
watercolor-paper background. Two simple knitting needles cross behind the yarn
ball. A small clean gauge/ruler mark is integrated at the lower right. Warm,
hand-painted, gentle family resemblance to KnitNote, but no rabbit and no copied
composition. Strong silhouette and contrast at 29-point size; minimal fine
detail; professional App Store finish.
```

Inspect the full-resolution image before accepting it. Reject unreadable needles, text-like artifacts, transparent edges, or a ruler that resembles a calculator keypad.

- [ ] **Step 4: Produce exact renditions and contact sheet**

Use `sips` from the 1024 master to create every filename referenced by `Contents.json`; do not upscale a smaller image. Compose a contact sheet showing 1024, 180, 120, 80, 60, and 29 pixel renditions on light and dark backgrounds.

Run:

```bash
sips -g pixelWidth -g pixelHeight -g hasAlpha KnittingCalculator/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png
```

Expected: 1024 × 1024 and `hasAlpha: no`.

- [ ] **Step 5: Visually inspect and run icon/build contracts**

Open the contact sheet with the local image viewer and confirm the yarn ball, crossed needles, and gauge remain identifiable at the smallest rendition.

Run:

```bash
swift test --filter KnittingCalculatorAppIconContractTests
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnittingCalculatorIcon CODE_SIGNING_ALLOWED=NO
```

Expected: contract passes and asset compilation/build exits 0 without warnings.

- [ ] **Step 6: Commit**

```bash
git add KnittingCalculator/Assets.xcassets AppStore/KnittingCalculator/Icon Tests/KnitNoteCoreTests/KnittingCalculatorAppIconContractTests.swift
git commit -m "feat: add knitting calculator app icon"
```

---

### Task 11: App Store metadata, support, and privacy

**Files:**
- Create: `AppStore/KnittingCalculator/Metadata/en-US.md`
- Create: `AppStore/KnittingCalculator/Metadata/zh-Hant.md`
- Create: `AppStore/KnittingCalculator/PrivacyPolicy.md`
- Create: `AppStore/SupportSite/knitting-calculator.html`
- Create: `AppStore/SupportSite/knitting-calculator-privacy.html`
- Modify: `AppStore/SupportSite/index.html`
- Create: `Tests/KnitNoteCoreTests/KnittingCalculatorMetadataContractTests.swift`

**Interfaces:**
- Produces: complete bilingual listing/support/privacy source and exact public URLs.

- [ ] **Step 1: Write failing metadata contracts**

```swift
import Foundation
import Testing

@Test func freeAppMetadataIsCompleteAndDoesNotMisrepresentKnitNote() throws {
    for locale in ["en-US", "zh-Hant"] {
        let text = try source("AppStore/KnittingCalculator/Metadata/\(locale).md")
        for field in [
            "Name:", "Subtitle:", "Promotional text:", "Keywords:",
            "Description:", "Support URL:", "Privacy URL:"
        ] {
            #expect(text.contains(field))
        }
        #expect(!text.localizedCaseInsensitiveContains("upgrade"))
        #expect(!text.contains("完整版"))
        #expect(text.contains("free") || text.contains("免費"))
    }
}

@Test func privacyPolicyMatchesNoCollectionManifest() throws {
    let text = try source("AppStore/KnittingCalculator/PrivacyPolicy.md")
    #expect(text.contains("does not collect"))
    #expect(text.contains("不蒐集"))
    #expect(text.contains("on your device"))
    #expect(text.contains("裝置"))
}

private func source(_ relativePath: String) throws -> String {
    try String(
        contentsOf: metadataRepositoryRoot.appending(path: relativePath),
        encoding: .utf8
    )
}

private let metadataRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
```

- [ ] **Step 2: Run contract and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorMetadataContractTests
```

Expected: FAIL because free-app metadata files do not exist.

- [ ] **Step 3: Write exact listing content**

Traditional Chinese:

- Name: `編織計算器`
- Subtitle: `密度與加減針工具`
- Keywords include `編織,棒針,鉤針,密度,加針,減針,針數,排數`
- Lead with free/offline/no-account value.
- Describe both calculators accurately.
- Mention KnitNote only in the final paragraph as the separate project-management app by the same team.

English:

- Name: `Knitting Calculator`
- Subtitle: `Gauge, Increases & Decreases`
- Keywords include `knitting,crochet,gauge,increase,decrease,stitches,rows`
- Preserve the same scope and product relationship.

- [ ] **Step 4: Add bilingual privacy and support pages**

State:

- no account, ads, analytics, tracking, or collected data
- inputs and saved drafts remain in local UserDefaults
- deleting remembered inputs or deleting the app removes local state
- outbound App Store, privacy, and email links leave the app
- support email is `lzz.1999@icloud.com`

Add links from the support-site home without changing existing KnitNote claims.

- [ ] **Step 5: Validate**

Run:

```bash
swift test --filter KnittingCalculatorMetadataContractTests
python3 AppStore/Verification/site_check.py AppStore/SupportSite
git diff --check
```

Expected: metadata contracts pass, site validation passes, and diff check is clean.

- [ ] **Step 6: Commit**

```bash
git add AppStore/KnittingCalculator AppStore/SupportSite Tests/KnitNoteCoreTests/KnittingCalculatorMetadataContractTests.swift
git commit -m "docs: prepare knitting calculator store listing"
```

---

### Task 12: Product-specific release audit and physical acceptance

**Files:**
- Create: `AppStore/Verification/knitting_calculator_release_audit.sh`
- Create: `AppStore/Verification/KnittingCalculatorPhysicalVerification.md`
- Modify: `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PrivacyManifestContractTests.swift`
- Modify: `KnittingCalculator/Model/CalculatorShareText.swift` after App Store Connect assigns the real product ID

**Interfaces:**
- Produces: `knitting_calculator_release_audit.sh [--static-only] [--archive PATH]`.
- Produces: explicit automated and physical evidence without conflating them.

- [ ] **Step 1: Write failing release-audit contracts**

```swift
@Test func freeAppReleaseAuditPinsIdentityAndRejectsSentinels() throws {
    let script = try source("AppStore/Verification/knitting_calculator_release_audit.sh")
    #expect(script.contains("EXPECTED_BUNDLE=\"com.phillon.KnittingCalculator\""))
    #expect(script.contains("EXPECTED_VERSION=\"1.0.0\""))
    #expect(script.contains("EXPECTED_BUILD=\"1\""))
    #expect(script.contains("apps.apple.com/app/id[0-9]+"))
    #expect(script.contains("KnittingCalculator/PrivacyInfo.xcprivacy"))
    #expect(script.contains("KnittingCalculator/Localization/Localizable.xcstrings"))
}
```

Extend the privacy contract to require exactly the UserDefaults `CA92.1` reason and no tracking/collection for the free app.

- [ ] **Step 2: Run contracts and verify RED**

Run:

```bash
swift test --filter KnittingCalculatorProjectContractTests
swift test --filter PrivacyManifestContractTests
```

Expected: FAIL because the audit and free-app privacy assertions are missing.

- [ ] **Step 3: Implement the static audit**

The script must:

```bash
set -euo pipefail
xcodegen dump --type parsed-json
plutil -lint KnittingCalculator/Info.plist KnittingCalculator/PrivacyInfo.xcprivacy
jq -e '
  def complete:
    type == "object"
    and length > 0
    and (
      if has("stringUnit") then
        (.stringUnit.value | type == "string" and length > 0)
      else
        all(.[]; complete)
      end
    );
  (.strings | length) > 0
  and all(
    .strings[];
    (.localizations.en | complete)
    and (.localizations."zh-Hant" | complete)
  )
' KnittingCalculator/Localization/Localizable.xcstrings
if rg -n 'Firebase|Analytics|Telemetry|tracking|URLSession|NWConnection' KnittingCalculator; then
  echo "unexpected analytics, tracking, or network client source" >&2
  exit 1
fi
rg -q 'https://apps\.apple\.com/app/id[0-9]+' KnittingCalculator/Model/CalculatorShareText.swift
git diff --check
```

The network-source scan must allow only the approved literal URLs in `CalculatorProductLinks` and Settings, while rejecting network clients and third-party SDK imports.

- [ ] **Step 4: Create the App Store Connect record and replace the development link**

Before archive validation:

1. Verify `編織計算器` and `Knitting Calculator` availability in App Store Connect.
2. Create the separate free App record with bundle ID `com.phillon.KnittingCalculator`.
3. Copy the assigned numeric App Store ID.
4. Replace the development landing-page value in `CalculatorProductLinks.freeApp` by concatenating the fixed prefix `https://apps.apple.com/app/id` with the numeric App Store ID returned by App Store Connect.
5. Run the share-text tests again.

Expected: the release audit recognizes the numeric App Store URL and shared result text opens the free product page.

- [ ] **Step 5: Implement archive validation**

With `--archive PATH`, verify:

- `Products/Applications/KnittingCalculator.app` exists
- bundle ID is exactly `com.phillon.KnittingCalculator`
- version/build are exactly `1.0.0 (1)`
- `PrivacyInfo.xcprivacy` exists and passes `plutil -lint`
- signed entitlements do not contain app groups, iCloud, push, camera, photos, or file access
- the embedded icon set and both string catalogs exist
- `codesign --verify --deep --strict` passes

- [ ] **Step 6: Run the complete automated gate**

Run:

```bash
swift test --disable-sandbox
xcodegen generate
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorReleaseTests CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnittingCalculatorReleaseBuild CODE_SIGNING_ALLOWED=NO
bash AppStore/Verification/knitting_calculator_release_audit.sh --static-only
git diff --check
```

Expected: all commands exit 0 and the audit prints `KNITTING CALCULATOR RELEASE AUDIT: PASS`.

- [ ] **Step 7: Perform physical iPhone acceptance**

Record device model, OS, commit, build, and PASS/FAIL for:

- clean install opens directly to the two-tool home
- first unit follows device region
- gauge exact/recommended results and unit conversion
- optional row group
- one-row increase/decrease with edge toggle
- across-rows increase/decrease, single/both sides
- every specified failure
- copy and share text
- portrait/landscape
- background, termination, reopen persistence
- reset confirmation and scope
- KnitNote installed launch and uninstalled App Store fallback
- maximum Dynamic Type, VoiceOver, high contrast, reduced motion, light/dark mode
- no unexpected permission prompt

- [ ] **Step 8: Perform physical iPad acceptance**

Repeat the functional matrix on iPad and add:

- landscape and portrait
- one-third, half, and two-thirds Split View widths
- external keyboard numeric entry if available
- share sheet presentation and dismissal
- no clipped cards, fields, errors, results, or disclosures

Physical-device discrepancies override simulator/build evidence and must be fixed before archive.

- [ ] **Step 9: Archive and audit**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnittingCalculator -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/KnittingCalculator-1.0.0-1.xcarchive archive
bash AppStore/Verification/knitting_calculator_release_audit.sh --archive /tmp/KnittingCalculator-1.0.0-1.xcarchive
```

Expected: archive succeeds and product-specific audit passes. Do not upload or submit without a separate explicit release instruction.

- [ ] **Step 10: Commit**

```bash
git add AppStore/Verification KnittingCalculator/Model/CalculatorShareText.swift Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift Tests/KnitNoteCoreTests/PrivacyManifestContractTests.swift
git commit -m "test: add knitting calculator release gates"
```

---

## Final Verification Gate

Before claiming implementation complete:

```bash
git status --short
git diff --check
swift test --disable-sandbox
xcodegen generate
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath /tmp/KnittingCalculatorFinalPhone CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnittingCalculator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath /tmp/KnittingCalculatorFinalPad CODE_SIGNING_ALLOWED=NO
bash AppStore/Verification/knitting_calculator_release_audit.sh --static-only
```

Expected:

- worktree contains only intentional changes before final commit
- no whitespace errors
- complete Swift package suite passes
- free-app test target passes
- phone and iPad builds pass
- static release audit passes
- physical iPhone and iPad verification document records every required row
- no upload, submission, merge, or push has occurred without explicit approval
