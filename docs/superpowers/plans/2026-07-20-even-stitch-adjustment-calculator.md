# Even Stitch Adjustment Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a localized calculator that evenly distributes one-row increases or decreases and presents both a summary and expandable instructions.

**Architecture:** Implement deterministic distribution and structured steps in `KnitNoteCore`, with no SwiftUI or localized text dependencies. Add one SwiftUI calculator view and one calculator-menu view; reuse the existing gauge calculator, route the project card through the menu, and keep direct Settings links.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, String Catalog localization, iOS 18/macOS 15.

## Global Constraints

- Inputs are current stitch count and target stitch count, both positive integers.
- Current and target stitch counts must each be at most exactly 100,000.
- Automatically choose increase, decrease, or unchanged.
- Use only generic operations: increase one stitch and decrease the next two stitches into one.
- Provide an edge-stitch toggle, enabled by default, reserving exactly one stitch on each side.
- Show a summary first and collapsed complete steps in a `DisclosureGroup`.
- Ordinary segment lengths differ by at most one and longer segments are deterministically spread across the row.
- Return a multiple-row failure instead of partial instructions when a one-row operation is impossible.
- The project page keeps one Watercolor calculator card between counters and notes; that card opens the calculator menu.
- Settings directly lists both calculators under the existing calculator section.
- Support exact English and Traditional Chinese localization, VoiceOver, Dynamic Type, iPhone single-column layout, and a 620-point content cap on iPad/macOS.
- Do not persist calculator input or modify project data in V1.

---

### Task 1: Deterministic core distribution and structured steps

**Files:**
- Create: `Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift`
- Create: `Tests/KnitNoteCoreTests/EvenStitchAdjustmentCalculatorTests.swift`

**Interfaces:**
- Produces: `EvenStitchAdjustmentInput`, `EvenStitchOperation`, `EvenStitchStep`, `EvenStitchAdjustmentResult`, `EvenStitchAdjustmentFailure`, and `EvenStitchAdjustmentCalculator.calculate(_:)`.
- Produces: `EvenStitchAdjustmentCalculator.fieldNeedsValidation(_:groupStarted:)` for integer fields.

- [ ] **Step 1: Write failing core tests**

```swift
import Testing
@testable import KnitNoteCore

@Test func evenlyIncreasesWithReservedEdges() throws {
    let result = try EvenStitchAdjustmentCalculator.calculate(
        .init(current: 80, target: 92, reservesEdgeStitches: true)
    )
    #expect(result.operation == .increase)
    #expect(result.adjustmentCount == 12)
    #expect(result.edgeStitches == 1)
    #expect(result.plainSegments == Array(repeating: 6, count: 13))
    #expect(result.steps.first == .edge(1))
    #expect(result.steps.last == .edge(1))
    #expect(result.steps.filter { $0 == .increaseOne }.count == 12)
}

@Test func evenlyDecreasesAndConservesStitches() throws {
    let result = try EvenStitchAdjustmentCalculator.calculate(
        .init(current: 80, target: 68, reservesEdgeStitches: true)
    )
    #expect(result.operation == .decrease)
    #expect(result.adjustmentCount == 12)
    #expect(Set(result.plainSegments).isSubset(of: [4, 5]))
    #expect(result.plainSegments.reduce(0, +) + 24 + 2 == 80)
    #expect(result.steps.filter { $0 == .decreaseOne }.count == 12)
}

@Test func unchangedAndImpossibleCasesAreExplicit() throws {
    #expect(try EvenStitchAdjustmentCalculator.calculate(
        .init(current: 40, target: 40, reservesEdgeStitches: true)
    ).operation == .unchanged)
    #expect(throws: EvenStitchAdjustmentFailure.requiresMultipleRows) {
        try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 6, target: 12, reservesEdgeStitches: true)
        )
    }
    #expect(throws: EvenStitchAdjustmentFailure.cannotPreserveEdges) {
        try EvenStitchAdjustmentCalculator.calculate(
            .init(current: 4, target: 1, reservesEdgeStitches: true)
        )
    }
}

@Test func unevenSegmentsAreBalancedAndSpread() throws {
    let result = try EvenStitchAdjustmentCalculator.calculate(
        .init(current: 21, target: 24, reservesEdgeStitches: true)
    )
    #expect(result.plainSegments.max()! - result.plainSegments.min()! <= 1)
    #expect(result.plainSegments.reduce(0, +) == 19)
    #expect(result.plainSegments != result.plainSegments.sorted())
    #expect(result.plainSegments != result.plainSegments.sorted(by: >))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter EvenStitchAdjustmentCalculatorTests`
Expected: compilation fails because the calculator types do not exist.

- [ ] **Step 3: Implement public types and validation**

```swift
public struct EvenStitchAdjustmentInput: Equatable, Sendable {
    public let current: Int
    public let target: Int
    public let reservesEdgeStitches: Bool

    public init(current: Int, target: Int, reservesEdgeStitches: Bool) {
        self.current = current
        self.target = target
        self.reservesEdgeStitches = reservesEdgeStitches
    }
}

public enum EvenStitchOperation: Equatable, Sendable { case increase, decrease, unchanged }
public enum EvenStitchStep: Equatable, Sendable {
    case edge(Int), knit(Int), increaseOne, decreaseOne
}
public enum EvenStitchAdjustmentFailure: Error, Equatable, Sendable {
    case invalidCounts, exceedsSupportedLimit, cannotPreserveEdges, requiresMultipleRows
}
public struct EvenStitchAdjustmentResult: Equatable, Sendable {
    public let operation: EvenStitchOperation
    public let adjustmentCount: Int
    public let edgeStitches: Int
    public let plainSegments: [Int]
    public let steps: [EvenStitchStep]
}
```

Implement `public static let maximumSupportedStitches = 100_000`. Reject either input above that limit with `.exceedsSupportedLimit` before calculating adjustment counts or allocating arrays. Implement `fieldNeedsValidation(_ value: Int?, groupStarted: Bool)` so untouched groups are quiet and nil/nonpositive values are invalid after the group starts; the separate supported-limit failure remains a calculation result so the UI can explain it precisely.

- [ ] **Step 4: Implement balanced gaps and step construction**

Use `gapCount = adjustments + 1`, `base = total / gapCount`, and `remainder = total % gapCount`. Spread the remainder with centered cumulative error:

```swift
private static func balancedSegments(total: Int, count: Int) -> [Int] {
    let base = total / count
    let remainder = total % count
    return (0..<count).map { index in
        let before = (index * remainder + count / 2) / count
        let after = ((index + 1) * remainder + count / 2) / count
        return base + (after > before ? 1 : 0)
    }
}
```

For increases, require `working >= adjustments + 1`, distribute `working`, and interleave `.increaseOne`. For decreases, compute `plain = working - 2 * adjustments`, reject negative values, distribute plain stitches, and interleave `.decreaseOne`. Omit `.knit(0)`. Add `.edge(1)` to both ends only when requested. Use checked subtraction/order comparisons before arithmetic so hostile `Int.max` inputs cannot overflow.

- [ ] **Step 5: Run focused and full core tests**

Run: `CLANG_MODULE_CACHE_PATH=/tmp/knitnote-even-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-even-swiftpm swift test --disable-sandbox --filter EvenStitchAdjustmentCalculatorTests && CLANG_MODULE_CACHE_PATH=/tmp/knitnote-even-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-even-swiftpm swift test --disable-sandbox`
Expected: focused tests and the complete suite PASS.

### Task 2: Even adjustment calculator screen

**Files:**
- Create: `KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift`
- Create: `Tests/KnitNoteCoreTests/EvenStitchAdjustmentViewContractTests.swift`

**Interfaces:**
- Consumes: all Task 1 result and step types.
- Produces: `EvenStitchAdjustmentCalculatorView` for navigation in Task 3.

- [ ] **Step 1: Write a failing view contract**

```swift
@Test func evenAdjustmentViewUsesCoreAndApprovedLayout() throws {
    let source = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")
    #expect(source.contains("EvenStitchAdjustmentCalculator.calculate"))
    #expect(source.contains("@State private var reservesEdgeStitches = true"))
    #expect(source.contains("DisclosureGroup"))
    #expect(source.contains("WatercolorCard"))
    #expect(source.contains("frame(maxWidth: 620)"))
    #expect(source.contains("keyboardType(.numberPad)"))
    #expect(source.contains("calculator.adjustment.validation.positiveInteger"))
}
```

Add the same repository-root `appSource(_:)` helper used by the gauge contracts.

- [ ] **Step 2: Run the contract and verify RED**

Run: `swift test --filter EvenStitchAdjustmentViewContractTests`
Expected: FAIL because the view source file does not exist.

- [ ] **Step 3: Implement locale-safe integer inputs and immediate calculation**

Use `@Environment(\.locale)`, string states `currentStitches` and `targetStitches`, and a default-true edge toggle. Parse with a strict decimal `NumberFormatter`, reject fractions by confirming `number.doubleValue == Double(number.intValue)`, and call:

```swift
private var result: Result<EvenStitchAdjustmentResult, EvenStitchAdjustmentFailure>? {
    guard let current = parseInteger(currentStitches),
          let target = parseInteger(targetStitches) else { return nil }
    return Result {
        try EvenStitchAdjustmentCalculator.calculate(
            .init(current: current, target: target, reservesEdgeStitches: reservesEdgeStitches)
        )
    }
}
```

Show per-field validation only after either input is started. Use `.numberPad` inside `#if os(iOS)` and a normal text field on macOS. Map `.exceedsSupportedLimit` to a localized message that states the 100,000-stitch maximum.

- [ ] **Step 4: Implement summary, failures, and collapsed structured steps**

Use a Watercolor result card. Switch on `result.operation` for unchanged/increase/decrease summaries. Display the segment range from `plainSegments.min()` and `.max()`, the edge summary when enabled, and a collapsed `DisclosureGroup("calculator.adjustment.steps.show")`. Render each `EvenStitchStep` through a switch using stable named String Catalog format keys and `String.localizedStringWithFormat`; never concatenate translated fragments. Failure cases map to separate static localization keys for invalid counts, edge preservation, and multiple rows.

- [ ] **Step 5: Run contracts and cross-platform build**

Run: `swift test --filter EvenStitchAdjustmentViewContractTests && xcodegen generate && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteEvenView CODE_SIGNING_ALLOWED=NO build`
Expected: contracts PASS, Xcode project contains the new view, and macOS build exits 0.

### Task 3: Calculator menu and navigation integration

**Files:**
- Create: `KnitNote/Calculators/KnittingCalculatorsView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `Tests/KnitNoteCoreTests/EvenStitchAdjustmentViewContractTests.swift`

**Interfaces:**
- Consumes: `GaugeCalculatorView` and `EvenStitchAdjustmentCalculatorView`.
- Produces: a project calculator menu and direct Settings navigation.

- [ ] **Step 1: Add failing navigation and ordering contracts**

```swift
@Test func calculatorMenuAndEntriesExposeBothCalculators() throws {
    let menu = try appSource("KnitNote/Calculators/KnittingCalculatorsView.swift")
    let settings = try appSource("KnitNote/Settings/SettingsView.swift")
    let project = try appSource("KnitNote/Projects/ProjectDetailView.swift")
    #expect(menu.contains("GaugeCalculatorView()"))
    #expect(menu.contains("EvenStitchAdjustmentCalculatorView()"))
    #expect(settings.contains("GaugeCalculatorView()"))
    #expect(settings.contains("EvenStitchAdjustmentCalculatorView()"))
    #expect(project.contains("KnittingCalculatorsView()"))
    #expect(!project.contains("GaugeCalculatorView()"))
    let counters = try #require(project.range(of: "CounterSelectorGrid("))
    let tools = try #require(project.range(of: "KnittingCalculatorsView()"))
    let notes = try #require(project.range(of: "\"notes.edit\""))
    #expect(counters.lowerBound < tools.lowerBound && tools.lowerBound < notes.lowerBound)
}
```

- [ ] **Step 2: Run the focused contract and verify RED**

Run: `swift test --filter calculatorMenuAndEntriesExposeBothCalculators`
Expected: FAIL because the menu and second Settings link do not exist.

- [ ] **Step 3: Build the calculator menu**

Create a `ScrollView` over `WatercolorBackground`, with two Watercolor navigation cards: ruler → `GaugeCalculatorView`, and arrow up/down symbol → `EvenStitchAdjustmentCalculatorView`. Apply `.navigationTitle("calculator.tools.title")`, `.frame(maxWidth: 620)`, and Dynamic-Type-safe vertical layout.

- [ ] **Step 4: Rewire project and Settings**

Change only the project card destination to `KnittingCalculatorsView()` and its label to `calculator.tools.title`; preserve its position between counters and notes. In Settings, keep the existing gauge link and add a direct even-adjustment link in the same section.

- [ ] **Step 5: Run navigation contracts and build**

Run: `swift test --filter EvenStitchAdjustmentViewContractTests && xcodegen generate && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteEvenNavigation CODE_SIGNING_ALLOWED=NO build`
Expected: all contracts PASS and build exits 0.

### Task 4: English and Traditional Chinese localization

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: every static key and format key used by Tasks 2-3.
- Produces: exact `en` and `zh-Hant` text with matching placeholders.

- [ ] **Step 1: Add failing localization coverage**

Add a dictionary-based test requiring exact values for all new visible labels, summaries, failure messages, accessibility labels, and step formats. At minimum require:

```swift
let required = [
  "calculator.adjustment.title": ["en": "Even Increase / Decrease", "zh-Hant": "等距加針／減針"],
  "calculator.adjustment.current": ["en": "Current stitches", "zh-Hant": "目前針數"],
  "calculator.adjustment.target": ["en": "Target stitches", "zh-Hant": "目標針數"],
  "calculator.adjustment.reserveEdges": ["en": "Reserve one edge stitch on each side", "zh-Hant": "左右各保留 1 針"],
  "calculator.adjustment.steps.show": ["en": "Show complete steps", "zh-Hant": "查看完整步驟"],
  "calculator.adjustment.validation.positiveInteger": ["en": "Enter a whole number greater than 0.", "zh-Hant": "請輸入大於 0 的整數。"]
]
```

Also require one `%lld` in integer step formats and one `%@` in preformatted segment-range summaries.

- [ ] **Step 2: Run localization tests and verify RED**

Run: `swift test --filter LocalizationContractTests`
Expected: FAIL on the first missing adjustment key.

- [ ] **Step 3: Add all exact catalog entries**

Add `en` and `zh-Hant` for title, inputs, edge toggle, unchanged/increase/decrease summaries, interval range, reserved-edge summary, disclosure label, four step types, three failure reasons, validation, and VoiceOver result summary. Use named `.format` keys with placeholders in translation values and call them through `String(localized:locale:)` plus `String.localizedStringWithFormat`.

- [ ] **Step 4: Validate the catalog and full localization suite**

Run: `jq empty KnitNote/Localization/Localizable.xcstrings && swift test --filter LocalizationContractTests && git diff --check`
Expected: JSON parse exits 0, localization tests PASS, and no whitespace errors.

### Task 5: Full regression and device-size acceptance

**Files:**
- Modify only gauge/even-calculator-owned files if verification exposes a defect.

**Interfaces:**
- Consumes: the complete feature.
- Produces: independently verified calculations, navigation, localization, and layouts.

- [ ] **Step 1: Run fresh complete tests**

Run: `CLANG_MODULE_CACHE_PATH=/tmp/knitnote-even-final-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-even-final-swiftpm swift test --disable-sandbox`
Expected: all suites PASS with zero failures.

- [ ] **Step 2: Verify whitespace and both available platform builds**

Run: `git diff --check && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteEvenFinalMac CODE_SIGNING_ALLOWED=NO build && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteEvenFinalIOS CODE_SIGNING_ALLOWED=NO build`
Expected: diff and both builds exit 0. If CoreSimulator reports `supportedRuntimes=[]`, record iOS/UI acceptance as blocked rather than passed.

- [ ] **Step 3: Exercise core acceptance cases**

Verify 80→92 and 80→68 with edges, unchanged counts, non-divisible balanced gaps, edge toggle, invalid integer input, insufficient increase spacing, excessive decrease, and unsafe integer boundaries. For every successful result, reconstruct consumed current stitches and produced target stitches from structured steps and assert exact equality.

- [ ] **Step 4: Exercise iPhone and iPad UI**

On current builds, verify the project card remains between counters and notes, opens the two-item calculator menu, Settings directly opens both calculators, summaries and collapsed steps are readable in `zh-Hant` and `en`, fields validate beside the input, VoiceOver has complete result labels, iPhone remains single-column, and iPad content is centered within 620 points at large Dynamic Type.

- [ ] **Step 5: Review scoped changes**

Run: `git status --short` and inspect only core calculator files, calculator views, navigation entry files, catalog, tests, generated project inclusion, spec, and plan. Preserve every unrelated dirty-workspace change and create no mixed commit.
