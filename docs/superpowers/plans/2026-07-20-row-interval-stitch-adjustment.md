# Row-Interval Stitch Adjustment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing even increase/decrease tool with a second mode that distributes single-sided or symmetric stitch changes evenly across a requested number of rows.

**Architecture:** Keep the existing one-row calculator unchanged. Add a pure `RowIntervalAdjustmentCalculator` in KnitNoteCore, then let `EvenStitchAdjustmentCalculatorView` switch between its existing one-row form and a new cross-row form. The UI formats typed results through bilingual String Catalog keys; all scheduling rules remain in the pure core type.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, String Catalog (`.xcstrings`), XcodeGen.

## Global Constraints

- Preserve every existing `EvenStitchAdjustmentCalculator` behavior and entry point.
- Support both `singleSide` (one stitch per event) and `bothSides` (two stitches per event).
- Schedule event `i` at `ceil(i * totalRows / eventCount)` without floating-point arithmetic.
- Every schedule is strictly increasing, ends at `totalRows`, and has interval spread no greater than one row.
- Reject odd total stitch changes in `bothSides` mode; do not round.
- Reject event counts greater than total rows; never schedule two events on one row.
- Accept only positive whole numbers no greater than 100,000.
- Ship exact English and Traditional Chinese localizations and VoiceOver text.
- Do not add start-row options, odd/even-row filters, stitch-technique teaching, history, or project-counter mutation.

---

### Task 1: Pure Row-Interval Scheduling Model

**Files:**
- Create: `Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift`
- Create: `Tests/KnitNoteCoreTests/RowIntervalAdjustmentCalculatorTests.swift`

**Interfaces:**
- Consumes: no app UI; uses only Swift standard library.
- Produces: `RowIntervalAdjustmentOperation`, `RowIntervalAdjustmentStyle`, `RowIntervalAdjustmentInput`, `RowIntervalAdjustmentResult`, `RowIntervalAdjustmentFailure`, and `RowIntervalAdjustmentCalculator.calculate(_:)`.

- [ ] **Step 1: Write failing examples for the two approved 20-row schedules**

```swift
import Testing
@testable import KnitNoteCore

@Suite struct RowIntervalAdjustmentCalculatorTests {
    @Test func schedulesTenSingleSideDecreasesAcrossTwentyRows() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 20,
            totalStitches: 10,
            operation: .decrease,
            style: .singleSide
        ))
        #expect(result.eventCount == 10)
        #expect(result.stitchesPerEvent == 1)
        #expect(result.adjustmentRows == [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        #expect(result.minimumInterval == 2)
        #expect(result.maximumInterval == 2)
    }

    @Test func schedulesTenSymmetricDecreasesAcrossTwentyRows() throws {
        let result = try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 20,
            totalStitches: 10,
            operation: .decrease,
            style: .bothSides
        ))
        #expect(result.eventCount == 5)
        #expect(result.stitchesPerEvent == 2)
        #expect(result.adjustmentRows == [4, 8, 12, 16, 20])
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter RowIntervalAdjustmentCalculatorTests`

Expected: FAIL because `RowIntervalAdjustmentCalculator` and its related types do not exist.

- [ ] **Step 3: Implement the minimal public model and integer-only scheduler**

```swift
public enum RowIntervalAdjustmentOperation: Equatable, Sendable {
    case increase
    case decrease
}

public enum RowIntervalAdjustmentStyle: Equatable, Sendable {
    case singleSide
    case bothSides
}

public struct RowIntervalAdjustmentInput: Equatable, Sendable {
    public let totalRows: Int
    public let totalStitches: Int
    public let operation: RowIntervalAdjustmentOperation
    public let style: RowIntervalAdjustmentStyle

    public init(
        totalRows: Int,
        totalStitches: Int,
        operation: RowIntervalAdjustmentOperation,
        style: RowIntervalAdjustmentStyle
    ) {
        self.totalRows = totalRows
        self.totalStitches = totalStitches
        self.operation = operation
        self.style = style
    }
}

public enum RowIntervalAdjustmentFailure: Error, Equatable, Sendable {
    case invalidCounts
    case exceedsSupportedLimit
    case symmetricRequiresEvenStitches
    case insufficientRows
}

public struct RowIntervalAdjustmentResult: Equatable, Sendable {
    public let operation: RowIntervalAdjustmentOperation
    public let style: RowIntervalAdjustmentStyle
    public let totalRows: Int
    public let totalStitches: Int
    public let eventCount: Int
    public let stitchesPerEvent: Int
    public let adjustmentRows: [Int]
    public let minimumInterval: Int
    public let maximumInterval: Int
}

public enum RowIntervalAdjustmentCalculator {
    public static let maximumSupportedValue = 100_000

    public static func calculate(
        _ input: RowIntervalAdjustmentInput
    ) throws -> RowIntervalAdjustmentResult {
        guard input.totalRows > 0, input.totalStitches > 0 else {
            throw RowIntervalAdjustmentFailure.invalidCounts
        }
        guard input.totalRows <= maximumSupportedValue,
              input.totalStitches <= maximumSupportedValue else {
            throw RowIntervalAdjustmentFailure.exceedsSupportedLimit
        }
        if input.style == .bothSides, !input.totalStitches.isMultiple(of: 2) {
            throw RowIntervalAdjustmentFailure.symmetricRequiresEvenStitches
        }
        let stitchesPerEvent = input.style == .bothSides ? 2 : 1
        let eventCount = input.totalStitches / stitchesPerEvent
        guard eventCount <= input.totalRows else {
            throw RowIntervalAdjustmentFailure.insufficientRows
        }
        let rows = (1...eventCount).map { event in
            let product = event * input.totalRows
            return product / eventCount + (product.isMultiple(of: eventCount) ? 0 : 1)
        }
        let intervals = zip([0] + rows, rows).map { previous, current in
            current - previous
        }
        return RowIntervalAdjustmentResult(
            operation: input.operation,
            style: input.style,
            totalRows: input.totalRows,
            totalStitches: input.totalStitches,
            eventCount: eventCount,
            stitchesPerEvent: stitchesPerEvent,
            adjustmentRows: rows,
            minimumInterval: intervals.min()!,
            maximumInterval: intervals.max()!
        )
    }
}
```

Before using `event * totalRows`, the 100,000 limits make the product at most 10,000,000,000, which is safe on every supported 64-bit Apple platform.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `swift test --filter RowIntervalAdjustmentCalculatorTests`

Expected: both tests PASS.

- [ ] **Step 5: Add failing validation and invariant tests**

```swift
@Test func spreadsRemaindersAndEndsOnTheFinalRow() throws {
    let result = try RowIntervalAdjustmentCalculator.calculate(.init(
        totalRows: 20, totalStitches: 6, operation: .increase, style: .singleSide
    ))
    #expect(result.adjustmentRows == [4, 7, 10, 14, 17, 20])
    #expect(result.minimumInterval == 3)
    #expect(result.maximumInterval == 4)
    #expect(result.adjustmentRows.last == 20)
}

@Test func increaseAndDecreaseShareOnlyTheSchedule() throws {
    let increase = try RowIntervalAdjustmentCalculator.calculate(.init(
        totalRows: 13, totalStitches: 4, operation: .increase, style: .singleSide
    ))
    let decrease = try RowIntervalAdjustmentCalculator.calculate(.init(
        totalRows: 13, totalStitches: 4, operation: .decrease, style: .singleSide
    ))
    #expect(increase.adjustmentRows == decrease.adjustmentRows)
    #expect(increase.operation == .increase)
    #expect(decrease.operation == .decrease)
}

@Test func rejectsInvalidUnsafeOddAndOvercrowdedInputs() {
    #expect(throws: RowIntervalAdjustmentFailure.invalidCounts) {
        try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 0, totalStitches: 1, operation: .decrease, style: .singleSide
        ))
    }
    #expect(throws: RowIntervalAdjustmentFailure.exceedsSupportedLimit) {
        try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: .max, totalStitches: .max, operation: .decrease, style: .singleSide
        ))
    }
    #expect(throws: RowIntervalAdjustmentFailure.symmetricRequiresEvenStitches) {
        try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 20, totalStitches: 9, operation: .decrease, style: .bothSides
        ))
    }
    #expect(throws: RowIntervalAdjustmentFailure.insufficientRows) {
        try RowIntervalAdjustmentCalculator.calculate(.init(
            totalRows: 5, totalStitches: 6, operation: .increase, style: .singleSide
        ))
    }
}
```

Add a loop over representative row/event combinations and assert every successful schedule is unique, strictly increasing, inside `1...totalRows`, ends at the final row, and has `maximumInterval - minimumInterval <= 1`.

- [ ] **Step 6: Run the focused and full core suites**

Run: `swift test --filter RowIntervalAdjustmentCalculatorTests && swift test`

Expected: all new tests and the existing 286-test baseline PASS.

- [ ] **Step 7: Record the task checkpoint**

Append the passing test count to `.superpowers/sdd/progress.md`. Do not stage unrelated dirty-workspace files.

---

### Task 2: Cross-Row Form and Result Card

**Files:**
- Create: `KnitNote/Calculators/RowIntervalAdjustmentView.swift`
- Modify: `KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift`
- Modify: `Tests/KnitNoteCoreTests/EvenStitchAdjustmentViewContractTests.swift`

**Interfaces:**
- Consumes: `RowIntervalAdjustmentCalculator.calculate(_:)` and existing `EvenStitchAdjustmentInputParser.parse(_:locale:)`.
- Produces: `RowIntervalAdjustmentView`, embedded through a `Picker`-selected mode in `EvenStitchAdjustmentCalculatorView`.

- [ ] **Step 1: Write failing view-contract tests for the approved structure**

```swift
@Test func adjustmentToolSwitchesBetweenOneRowAndAcrossRows() throws {
    let host = try appSource("KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift")
    let rows = try appSource("KnitNote/Calculators/RowIntervalAdjustmentView.swift")

    #expect(host.contains("calculator.adjustment.mode.oneRow"))
    #expect(host.contains("calculator.adjustment.mode.acrossRows"))
    #expect(host.contains("RowIntervalAdjustmentView()"))
    #expect(host.contains(".pickerStyle(.segmented)"))
    #expect(rows.contains("RowIntervalAdjustmentCalculator.calculate"))
    #expect(rows.contains("calculator.adjustment.rows.details.show"))
    #expect(rows.contains("LazyVStack"))
    #expect(rows.contains("accessibilityLabel"))
}
```

- [ ] **Step 2: Run the view contract and verify RED**

Run: `swift test --filter EvenStitchAdjustmentViewContractTests`

Expected: FAIL because the second mode and row view do not exist.

- [ ] **Step 3: Add the host mode picker without changing the old calculation branch**

Add a private mode enum and state:

```swift
private enum DistributionMode: String, CaseIterable, Identifiable {
    case oneRow
    case acrossRows
    var id: Self { self }
}

@State private var distributionMode = DistributionMode.oneRow
```

Inside the existing scroll stack, add a segmented picker before the input card. Its two labels use `calculator.adjustment.mode.oneRow` and `calculator.adjustment.mode.acrossRows`. Move the existing input card and `resultView` into the `.oneRow` switch branch unchanged; render `RowIntervalAdjustmentView()` in `.acrossRows`.

- [ ] **Step 4: Implement the cross-row form using the existing strict parser**

`RowIntervalAdjustmentView` owns:

```swift
@Environment(\.locale) private var locale
@State private var totalRows = ""
@State private var totalStitches = ""
@State private var operation = RowIntervalAdjustmentOperation.decrease
@State private var style = RowIntervalAdjustmentStyle.singleSide
```

Use segmented pickers for operation and style, number-pad text fields for total rows and stitches, and `EvenStitchAdjustmentInputParser` for strict bounded whole-number parsing. If either parser returns `.exceedsSupportedLimit`, surface `.exceedsSupportedLimit`; if a field is empty or invalid after either field was started, show the existing positive-integer validation copy. Recalculate from current state so invalid input never leaves an old result visible.

Render successful results in `WatercolorCard`: localized summary first, localized interval second, then a collapsed `DisclosureGroup("calculator.adjustment.rows.details.show")`. The disclosure uses a `LazyVStack` over `result.adjustmentRows.indices` and formats each row as a separate localized instruction; do not allocate a second copy of the array.

- [ ] **Step 5: Add focused formatting tests through source contracts**

Assert the new source branches on operation, style, and `minimumInterval == maximumInterval`; uses separate localization keys for exact versus ranged intervals; uses `String.localizedStringWithFormat`; keeps the result summary as one accessibility element; and does not call `.joined(separator:)` for the detailed schedule.

- [ ] **Step 6: Run focused tests and build the app**

Run: `swift test --filter EvenStitchAdjustmentViewContractTests && xcodegen generate && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteRowIntervalView CODE_SIGNING_ALLOWED=NO build`

Expected: focused tests PASS and macOS build exits 0.

- [ ] **Step 7: Record the task checkpoint**

Append the focused test/build result to `.superpowers/sdd/progress.md` without staging unrelated files.

---

### Task 3: English, Traditional Chinese, and VoiceOver Copy

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: exact keys referenced by `EvenStitchAdjustmentCalculatorView` and `RowIntervalAdjustmentView`.
- Produces: complete `en` and `zh-Hant` values for every new key.

- [ ] **Step 1: Add failing exact-value localization contracts**

Extend `requiredAdjustmentTranslations` and `requiredAdjustmentFormatTranslations` with exact pairs including:

```swift
"calculator.adjustment.mode.oneRow": ["en": "One Row", "zh-Hant": "單排分配"],
"calculator.adjustment.mode.acrossRows": ["en": "Across Rows", "zh-Hant": "跨段分配"],
"calculator.adjustment.rows.input.title": ["en": "Row Distribution", "zh-Hant": "跨段分配"],
"calculator.adjustment.rows.totalRows": ["en": "Total rows", "zh-Hant": "總段數"],
"calculator.adjustment.rows.totalStitches": ["en": "Total stitches to change", "zh-Hant": "總加減針數"],
"calculator.adjustment.rows.operation.increase": ["en": "Increase", "zh-Hant": "加針"],
"calculator.adjustment.rows.operation.decrease": ["en": "Decrease", "zh-Hant": "減針"],
"calculator.adjustment.rows.style.singleSide": ["en": "1 stitch each time", "zh-Hant": "每次單側 1 針"],
"calculator.adjustment.rows.style.bothSides": ["en": "1 stitch on each side", "zh-Hant": "每次左右各 1 針"],
"calculator.adjustment.rows.details.show": ["en": "Show adjustment rows", "zh-Hant": "查看調整段數"],
"calculator.adjustment.rows.failure.symmetricEven": ["en": "For matching changes on both sides, enter an even number of stitches.", "zh-Hant": "左右對稱加減針時，總針數請輸入偶數。"],
"calculator.adjustment.rows.failure.insufficientRows": ["en": "There are not enough rows to distribute these changes once per row.", "zh-Hant": "指定段數不足，無法以每段最多一次平均完成。"]
```

Also require format keys for exact/ranged single-side and both-sides increase/decrease summaries, a row-number detail, a localized row range, the 100,000 limit error, and the full VoiceOver result. Each format must be a complete sentence in both languages.

- [ ] **Step 2: Run localization tests and verify RED**

Run: `swift test --filter LocalizationContractTests`

Expected: FAIL because the new catalog entries are missing.

- [ ] **Step 3: Add all catalog entries with exact bilingual values**

Edit `Localizable.xcstrings` as valid JSON. Use `%lld` for integer arguments and `%@` only for already-localized interval strings. Provide distinct complete formats for increase/decrease and single-side/both-sides; do not concatenate translated fragments in Swift.

- [ ] **Step 4: Validate JSON and verify GREEN**

Run: `jq empty KnitNote/Localization/Localizable.xcstrings && swift test --filter LocalizationContractTests`

Expected: JSON validation succeeds and localization tests PASS.

- [ ] **Step 5: Run the combined calculator tests**

Run: `swift test --filter RowIntervalAdjustmentCalculatorTests && swift test --filter EvenStitchAdjustmentViewContractTests && swift test --filter LocalizationContractTests`

Expected: all three focused suites PASS.

- [ ] **Step 6: Record the task checkpoint**

Append the localization verification result to `.superpowers/sdd/progress.md`.

---

### Task 4: Regression and Product Verification

**Files:**
- Modify only if verification exposes a defect in files already listed above.
- Modify: `.superpowers/sdd/progress.md`

**Interfaces:**
- Consumes: completed core, UI, and localization work from Tasks 1–3.
- Produces: evidence that the feature is ready for device acceptance.

- [ ] **Step 1: Run the complete Swift test suite**

Run: `CLANG_MODULE_CACHE_PATH=/tmp/knitnote-row-interval-clang SWIFT_MODULECACHE_PATH=/tmp/knitnote-row-interval-swift swift test --disable-sandbox`

Expected: all tests PASS with no failures.

- [ ] **Step 2: Regenerate and build macOS**

Run: `xcodegen generate && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteRowIntervalFinalMac CODE_SIGNING_ALLOWED=NO build`

Expected: exit 0 with no Swift compiler diagnostics.

- [ ] **Step 3: Attempt the iOS code/product build and classify environment failures accurately**

Run: `xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteRowIntervalFinalIOS CODE_SIGNING_ALLOWED=NO build`

Expected when CoreSimulator is healthy: exit 0. If it reports no installed/supported simulator runtimes or an `actool` simulator-service failure without Swift diagnostics, record iPhone/iPad interaction as pending rather than claiming product acceptance.

- [ ] **Step 4: Run catalog and diff integrity checks**

Run: `jq empty KnitNote/Localization/Localizable.xcstrings && git diff --check`

Expected: both exit 0.

- [ ] **Step 5: Complete final review and progress record**

Review exact compliance with `docs/superpowers/specs/2026-07-20-row-interval-stitch-adjustment-design.md`. Append final test count, build status, and any simulator-only acceptance gate to `.superpowers/sdd/progress.md`. Preserve the shared dirty workspace; do not reset, clean, or stage unrelated changes.
