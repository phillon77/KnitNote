# Gauge Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a localized, immediately updating gauge calculator for stitches and optional rows, reachable from Settings and each project.

**Architecture:** Put all numeric validation, unit conversion, density calculation, and rounding in a pure `KnitNoteCore` type. Build one SwiftUI calculator screen over that API and navigate to the same view from both existing entry points; inputs remain ephemeral and do not change `StoredProject`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, String Catalog localization, iOS 18/macOS 15.

## Global Constraints

- Support Traditional Chinese and English for every new user-facing string.
- Support centimeters and inches, defaulting to centimeters.
- Row inputs are optional as a complete group; incomplete started groups show validation.
- Show the exact result and a nearest-integer recommendation using ordinary half-up rounding for nonnegative values.
- Unit changes convert dimensional inputs using exactly 2.54 centimeters per inch and never change stitch/row counts.
- Keep a single-column, Dynamic-Type-safe UI with a maximum readable width on iPad/macOS.
- Do not persist calculator inputs or modify project data in V1.

---

### Task 1: Pure gauge calculation model

**Files:**
- Create: `Sources/KnitNoteCore/Calculators/GaugeCalculator.swift`
- Create: `Tests/KnitNoteCoreTests/GaugeCalculatorTests.swift`

**Interfaces:**
- Produces: `GaugeLengthUnit`, `GaugeInput`, `GaugeResult`, and `GaugeCalculator.calculate(_:)` for the UI.
- Produces: `GaugeCalculator.convertLength(_:from:to:) -> Double` for unit switching.

- [ ] **Step 1: Write failing calculation tests**

```swift
import Testing
@testable import KnitNoteCore

@Test func calculatesStitchesAndRoundsHalfUp() throws {
    let result = try #require(GaugeCalculator.calculate(
        GaugeInput(sampleLength: 10, sampleCount: 19, targetLength: 43)
    ))
    #expect(result.density == 1.9)
    #expect(abs(result.exactCount - 81.7) < 0.000_001)
    #expect(result.recommendedCount == 82)
}

@Test func rejectsNonPositiveAndNonFiniteInputs() {
    #expect(GaugeCalculator.calculate(.init(sampleLength: 0, sampleCount: 20, targetLength: 40)) == nil)
    #expect(GaugeCalculator.calculate(.init(sampleLength: 10, sampleCount: .infinity, targetLength: 40)) == nil)
}

@Test func convertsLengthWithoutChangingCounts() {
    #expect(abs(GaugeCalculator.convertLength(10, from: .centimeters, to: .inches) - 3.937_007_874) < 0.000_001)
    #expect(abs(GaugeCalculator.convertLength(4, from: .inches, to: .centimeters) - 10.16) < 0.000_001)
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail**

Run: `swift test --filter GaugeCalculatorTests`
Expected: FAIL because `GaugeCalculator`, `GaugeInput`, and `GaugeLengthUnit` do not exist.

- [ ] **Step 3: Implement the pure calculation API**

```swift
public enum GaugeLengthUnit: String, CaseIterable, Sendable {
    case centimeters
    case inches
}

public struct GaugeInput: Equatable, Sendable {
    public let sampleLength: Double
    public let sampleCount: Double
    public let targetLength: Double

    public init(sampleLength: Double, sampleCount: Double, targetLength: Double) {
        self.sampleLength = sampleLength
        self.sampleCount = sampleCount
        self.targetLength = targetLength
    }
}

public struct GaugeResult: Equatable, Sendable {
    public let density: Double
    public let exactCount: Double
    public let recommendedCount: Int
}

public enum GaugeCalculator {
    public static func calculate(_ input: GaugeInput) -> GaugeResult? {
        let values = [input.sampleLength, input.sampleCount, input.targetLength]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let density = input.sampleCount / input.sampleLength
        let exact = density * input.targetLength
        guard exact.isFinite, exact <= Double(Int.max) else { return nil }
        return GaugeResult(density: density, exactCount: exact, recommendedCount: Int(exact.rounded(.toNearestOrAwayFromZero)))
    }

    public static func convertLength(_ value: Double, from: GaugeLengthUnit, to: GaugeLengthUnit) -> Double {
        guard from != to else { return value }
        return from == .centimeters ? value / 2.54 : value * 2.54
    }
}
```

- [ ] **Step 4: Run calculator and full core tests**

Run: `swift test --filter GaugeCalculatorTests && swift test`
Expected: focused tests PASS, then all existing suites PASS.

- [ ] **Step 5: Commit the model**

```bash
git add Sources/KnitNoteCore/Calculators/GaugeCalculator.swift Tests/KnitNoteCoreTests/GaugeCalculatorTests.swift
git commit -m "feat: add gauge calculation core"
```

### Task 2: Calculator screen and input behavior

**Files:**
- Create: `KnitNote/Calculators/GaugeCalculatorView.swift`
- Create: `Tests/KnitNoteCoreTests/GaugeCalculatorViewContractTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `GaugeLengthUnit`, `GaugeInput`, `GaugeResult`, `GaugeCalculator.calculate(_:)`, and `convertLength` from Task 1.
- Produces: `GaugeCalculatorView` for both navigation entry points.

- [ ] **Step 1: Write a source contract test for required behavior**

```swift
@Test func gaugeCalculatorViewUsesCoreAndKeepsRowsOptional() throws {
    let source = try appSource("KnitNote/Calculators/GaugeCalculatorView.swift")
    #expect(source.contains("GaugeCalculator.calculate"))
    #expect(source.contains("GaugeCalculator.convertLength"))
    #expect(source.contains("rowsWereStarted"))
    #expect(source.contains("WatercolorCard"))
    #expect(source.contains("keyboardType(.decimalPad)"))
    #expect(source.contains("frame(maxWidth: 620)"))
}
```

Include an `appSource(_:)` helper that resolves the repository root from `#filePath`, matching existing contract-test helpers.

- [ ] **Step 2: Run the contract test and confirm it fails**

Run: `swift test --filter GaugeCalculatorViewContractTests`
Expected: FAIL because `GaugeCalculatorView.swift` does not exist.

- [ ] **Step 3: Implement the screen**

Create a `ScrollView` over `WatercolorBackground` with:

```swift
@State private var unit: GaugeLengthUnit = .centimeters
@State private var sampleWidth = ""
@State private var sampleStitches = ""
@State private var targetWidth = ""
@State private var sampleHeight = ""
@State private var sampleRows = ""
@State private var targetHeight = ""

private var stitchResult: GaugeResult? {
    makeResult(length: sampleWidth, count: sampleStitches, target: targetWidth)
}

private var rowsWereStarted: Bool {
    [sampleHeight, sampleRows, targetHeight].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}
```

Use a segmented picker at the top. Build two `WatercolorCard` sections with reusable private field/result helpers; the row card title uses `calculator.gauge.rows.optional`. Parse numbers with `NumberFormatter` configured from `@Environment(\.locale)` so both `.` and locale decimal separators work. On unit change, convert only the four dimensional strings (`sampleWidth`, `targetWidth`, `sampleHeight`, `targetHeight`) and format them with at most four fractional digits. Show validation only when any field in its group has been started. Apply `.keyboardType(.decimalPad)` on iOS-compatible text fields, `.frame(maxWidth: 620)`, and accessibility labels for the recommendation.

- [ ] **Step 4: Regenerate the Xcode project and verify tests/build**

Run: `xcodegen generate && swift test --filter GaugeCalculatorViewContractTests && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteGauge CODE_SIGNING_ALLOWED=NO build`
Expected: XcodeGen succeeds, test PASS, build ends with `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit the screen**

```bash
git add KnitNote/Calculators/GaugeCalculatorView.swift Tests/KnitNoteCoreTests/GaugeCalculatorViewContractTests.swift project.yml KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: build gauge calculator screen"
```

### Task 3: Settings and project navigation entries

**Files:**
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `Tests/KnitNoteCoreTests/GaugeCalculatorViewContractTests.swift`

**Interfaces:**
- Consumes: `GaugeCalculatorView` from Task 2.
- Produces: two navigation paths to exactly the same calculator view.

- [ ] **Step 1: Add failing navigation contract tests**

```swift
@Test func settingsAndProjectOpenTheSharedGaugeCalculator() throws {
    let settings = try appSource("KnitNote/Settings/SettingsView.swift")
    let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")
    #expect(settings.contains("NavigationLink"))
    #expect(settings.contains("GaugeCalculatorView()"))
    #expect(project.contains("GaugeCalculatorView()"))
    #expect(settings.contains("calculator.tools.title"))
    #expect(project.contains("calculator.gauge.title"))
}
```

- [ ] **Step 2: Run the navigation contract and confirm it fails**

Run: `swift test --filter settingsAndProjectOpenTheSharedGaugeCalculator`
Expected: FAIL because neither entry exists.

- [ ] **Step 3: Add both entries**

In `SettingsView`, add a section with a NavigationLink destination of `GaugeCalculatorView()` and label `calculator.gauge.title`, under section header `calculator.tools.title`. In `ProjectDetailView`, add a compact Watercolor-styled NavigationLink after the optional tool card and before counters:

```swift
NavigationLink {
    GaugeCalculatorView()
} label: {
    Label("calculator.gauge.title", systemImage: "ruler")
        .frame(maxWidth: .infinity, alignment: .leading)
}
```

- [ ] **Step 4: Run contracts and build**

Run: `swift test --filter GaugeCalculatorViewContractTests && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteGaugeNavigation CODE_SIGNING_ALLOWED=NO build`
Expected: tests PASS and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit navigation**

```bash
git add KnitNote/Settings/SettingsView.swift KnitNote/Projects/ProjectDetailView.swift Tests/KnitNoteCoreTests/GaugeCalculatorViewContractTests.swift
git commit -m "feat: link gauge calculator from projects and settings"
```

### Task 4: Traditional Chinese and English localization

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: localization keys used by Tasks 2 and 3.
- Produces: complete `zh-Hant` and `en` UI text.

- [ ] **Step 1: Add a failing catalog coverage test**

```swift
@Test func gaugeCalculatorStringsHaveTraditionalChineseAndEnglish() throws {
    let keys = [
        "calculator.tools.title", "calculator.gauge.title", "calculator.unit.centimeters",
        "calculator.unit.inches", "calculator.gauge.stitches", "calculator.gauge.rows.optional",
        "calculator.gauge.sampleWidth", "calculator.gauge.sampleStitches", "calculator.gauge.targetWidth",
        "calculator.gauge.sampleHeight", "calculator.gauge.sampleRows", "calculator.gauge.targetHeight",
        "calculator.gauge.density", "calculator.gauge.exact", "calculator.gauge.recommended",
        "calculator.validation.positive"
    ]
    let strings = try catalogStrings()
    for key in keys {
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(localizations["en"] != nil)
        #expect(localizations["zh-Hant"] != nil)
    }
}
```

- [ ] **Step 2: Run localization test and confirm it fails**

Run: `swift test --filter gaugeCalculatorStringsHaveTraditionalChineseAndEnglish`
Expected: FAIL on the first missing key.

- [ ] **Step 3: Add exact localized copy**

Add the listed keys with English / Traditional Chinese values, including:

```text
Knitting Calculators / 編織計算工具
Gauge Calculator / 密度計算
Centimeters / 公分
Inches / 英吋
Stitch Calculation / 針數計算
Row Calculation (Optional) / 排數計算（選填）
Enter a value greater than 0. / 請輸入大於 0 的數值。
```

Use natural translations for the remaining field and result labels, and use String Catalog substitutions for result sentences instead of concatenating localized fragments.

- [ ] **Step 4: Validate catalog JSON and run localization tests**

Run: `plutil -lint KnitNote/Localization/Localizable.xcstrings && swift test --filter LocalizationContractTests`
Expected: catalog reports `OK`; localization suite PASS.

- [ ] **Step 5: Commit localization**

```bash
git add KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m "feat: localize gauge calculator"
```

### Task 5: Full verification and device-size acceptance

**Files:**
- Modify only if verification exposes a defect in files owned by Tasks 1-4.

**Interfaces:**
- Consumes: the complete feature.
- Produces: verified iPhone/iPad behavior with no regression.

- [ ] **Step 1: Run all tests from a fresh invocation**

Run: `swift test`
Expected: all suites PASS with zero failures.

- [ ] **Step 2: Run whitespace and build verification**

Run: `git diff --check && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteGaugeFinal CODE_SIGNING_ALLOWED=NO build`
Expected: no diff errors and `BUILD SUCCEEDED`.

- [ ] **Step 3: Exercise acceptance examples on iPhone and iPad simulators**

Verify both navigation entries and enter:

```text
10 cm, 20 stitches, 42 cm => density 2, exact 84, recommended 84
10 cm, 19 stitches, 43 cm => exact 81.7, recommended 82
4 in, 18 stitches, 20 in => density 4.5, exact 90, recommended 90
```

Leave all row fields blank and confirm there is no row error. Enter only one row field and confirm validation appears. Switch cm to inches and back, confirming dimensional values round-trip while stitch/row counts remain unchanged. Test both Traditional Chinese and English and larger Dynamic Type. Confirm iPhone is single-column and iPad content remains centered within 620 points.

- [ ] **Step 4: Review the final diff for scope**

Run: `git status --short && git diff -- Sources/KnitNoteCore/Calculators KnitNote/Calculators KnitNote/Settings/SettingsView.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests project.yml KnitNote.xcodeproj/project.pbxproj`
Expected: only gauge-calculator files and intentional generated project changes are present; unrelated dirty workspace changes remain untouched.

- [ ] **Step 5: Commit any verification-only fixes**

If Step 3 required changes, stage only the affected gauge files and commit:

```bash
git add <only-the-gauge-files-changed-during-verification>
git commit -m "fix: polish gauge calculator validation"
```

If no fixes were required, do not create an empty commit.

