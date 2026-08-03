# Pattern Reader Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a lightweight, session-only four-function calculator to the KnitNote pattern-reader toolbar on iPhone, iPad, and Mac without disturbing any saved reading state.

**Architecture:** Put all arithmetic and canonical decimal input handling in a small `KnitNoteCore` state machine with no UI or persistence dependency. Render that state through one SwiftUI calculator view, then attach it to `PatternReaderView` with an adaptive popover that remains a popover on iPad/Mac and becomes a medium sheet on iPhone. The calculator state belongs only to the current reader instance and never enters pattern, project, store, backup, or preference data.

**Tech Stack:** Swift 6, Foundation `Decimal`, SwiftUI, Swift Testing, XCStrings, XcodeGen, iOS 18, macOS 15.

## Global Constraints

- Target KnitNote 1.3.1; do not modify the approved 1.3.0 Build 6 candidate.
- Support iPhone, iPad, and Mac; do not add an Apple Watch calculator.
- Support `＋`, `－`, `×`, `÷`, `%`, decimal input, sign toggle, `AC`, and `＝` only.
- `%` means current displayed value divided by 100; do not implement operator-dependent commercial-calculator percentage rules.
- Use immediate one-binary-operation-at-a-time semantics; do not add precedence, parentheses, repeated-equals replay, history, memory keys, or scientific functions.
- The toolbar calculator icon opens a medium sheet on iPhone and a compact popover on iPad/Mac.
- Closing and reopening the presentation preserves state only within the same pattern-reader instance; a new reader starts at zero.
- Do not persist calculator state in `PatternReadingState`, `PatternProjectUsage`, projects, UserDefaults, backup files, or `JSONProjectStore`.
- Opening, using, rotating, and dismissing the calculator must not change pattern page, zoom, scroll, viewport, highlight, note, markup, or counters.
- Add exact English and Traditional Chinese localization and usable VoiceOver/Dynamic Type behavior.
- Do not add a dependency or modify StoreKit, pricing, trial, entitlements, privacy metadata, version/build, Git remote state, or App Store Connect state.

---

### Task 1: Build the Pure Decimal Calculator State Machine

**Files:**
- Create: `Sources/KnitNoteCore/Calculators/PatternCalculator.swift`
- Create: `Tests/KnitNoteCoreTests/PatternCalculatorTests.swift`

**Interfaces:**
- Consumes: Foundation `Decimal` only.
- Produces: `PatternCalculatorKey`, `PatternCalculatorOperation`, `PatternCalculatorError`, `PatternCalculatorDisplay`, and `PatternCalculatorState.press(_:)`.
- Later tasks bind directly to `PatternCalculatorState` and render `PatternCalculatorDisplay`; no later task may reach into accumulator or pending-operation storage.

- [ ] **Step 1: Write failing input, arithmetic, and state-transition tests**

Create `PatternCalculatorTests.swift` with explicit examples:

```swift
import Testing
@testable import KnitNoteCore

@Suite struct PatternCalculatorTests {
    @Test func addsSubtractsMultipliesAndDividesDecimals() {
        #expect(result(of: [.digit(1), .digit(2), .operation(.add), .digit(3), .equals]) == "15")
        #expect(result(of: [.digit(9), .operation(.subtract), .digit(4), .equals]) == "5")
        #expect(result(of: [.digit(6), .operation(.multiply), .digit(7), .equals]) == "42")
        #expect(result(of: [.digit(7), .decimal, .digit(5), .operation(.divide), .digit(3), .equals]) == "2.5")
    }

    @Test func percentAndSignOperateOnTheDisplayedValue() {
        #expect(result(of: [.digit(2), .digit(5), .percent]) == "0.25")
        #expect(result(of: [.digit(8), .toggleSign]) == "-8")
        #expect(result(of: [.digit(8), .toggleSign, .toggleSign]) == "8")
    }

    @Test func repeatedDecimalAndExcessDigitsAreIgnored() {
        var state = PatternCalculatorState()
        state.press(.digit(1))
        state.press(.decimal)
        state.press(.decimal)
        for _ in 0..<(PatternCalculatorState.maximumEntryDigits + 4) {
            state.press(.digit(2))
        }
        #expect(state.canonicalDisplay == "1." + String(repeating: "2", count: PatternCalculatorState.maximumEntryDigits - 1))
    }

    @Test func theLastConsecutiveOperatorWins() {
        #expect(result(of: [
            .digit(8), .operation(.add), .operation(.multiply), .digit(3), .equals,
        ]) == "24")
    }

    @Test func divideByZeroEntersErrorAndDigitOrClearRecovers() {
        var state = PatternCalculatorState()
        [.digit(8), .operation(.divide), .digit(0), .equals].forEach { state.press($0) }
        #expect(state.display == .error(.invalidResult))

        state.press(.digit(4))
        #expect(state.canonicalDisplay == "4")
        state.press(.clear)
        #expect(state == PatternCalculatorState())
    }

    @Test func clearResetsEveryPendingValue() {
        var state = PatternCalculatorState()
        [.digit(9), .operation(.add), .digit(2), .clear, .digit(3), .equals].forEach { state.press($0) }
        #expect(state == stateAfter([.digit(3), .equals]))
    }

    private func result(of keys: [PatternCalculatorKey]) -> String {
        stateAfter(keys).canonicalDisplay
    }

    private func stateAfter(_ keys: [PatternCalculatorKey]) -> PatternCalculatorState {
        var state = PatternCalculatorState()
        keys.forEach { state.press($0) }
        return state
    }
}
```

Add focused cases for leading zero, `0.`, negative zero normalization, percent after a completed result, equals without a complete pending operation, non-finite/overflow result rejection, and division rounded to no more than 12 fractional digits.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter PatternCalculatorTests
```

Expected: compilation fails because the calculator types do not exist.

- [ ] **Step 3: Define the public keys, operations, display, and error boundary**

Create `PatternCalculator.swift` with these exact public types:

```swift
import Foundation

public enum PatternCalculatorOperation: Equatable, Sendable {
    case add, subtract, multiply, divide
}

public enum PatternCalculatorError: Equatable, Sendable {
    case invalidResult
}

public enum PatternCalculatorKey: Equatable, Sendable {
    case digit(Int)
    case decimal
    case operation(PatternCalculatorOperation)
    case equals
    case clear
    case toggleSign
    case percent
}

public enum PatternCalculatorDisplay: Equatable, Sendable {
    case number(String)
    case error(PatternCalculatorError)
}

public struct PatternCalculatorState: Equatable, Sendable {
    public static let maximumEntryDigits = 12
    public static let maximumFractionDigits = 12

    public private(set) var canonicalDisplay = "0"
    public private(set) var display: PatternCalculatorDisplay = .number("0")
    public var pendingOperationForDisplay: PatternCalculatorOperation? { pendingOperation }

    private var accumulator: Decimal?
    private var pendingOperation: PatternCalculatorOperation?
    private var isStartingNewEntry = false

    public init() {}
}
```

The canonical display always uses `.` internally. It is not a localized display string and must never be parsed using the current UI locale.

- [ ] **Step 4: Implement the minimal deterministic state machine**

Implement one private method per key family:

```swift
private mutating func inputDigit(_ digit: Int)
private mutating func inputDecimal()
private mutating func select(_ operation: PatternCalculatorOperation)
private mutating func evaluate()
private mutating func toggleSign()
private mutating func applyPercent()
private mutating func fail()
private mutating func replaceDisplay(with value: Decimal) -> Bool
private func currentValue() -> Decimal?
```

Requirements for the implementation:

```swift
public mutating func press(_ key: PatternCalculatorKey) {
    if case .error = display {
        switch key {
        case .clear:
            self = .init()
        case let .digit(digit):
            self = .init()
            inputDigit(digit)
        default:
            return
        }
        return
    }

    switch key {
    case let .digit(digit): inputDigit(digit)
    case .decimal: inputDecimal()
    case let .operation(operation): select(operation)
    case .equals: evaluate()
    case .clear: self = .init()
    case .toggleSign: toggleSign()
    case .percent: applyPercent()
    }
}
```

- Accept only digits `0...9`; ignore other integers.
- Count numeric digits, not a leading minus sign or decimal separator, against `maximumEntryDigits`.
- Parse with `Locale(identifier: "en_US_POSIX")`.
- Before division, reject a right operand equal to zero.
- Round completed arithmetic to `maximumFractionDigits` using `NSDecimalRound(..., .plain)`, then use `NSDecimalNumber(decimal:).stringValue` to remove insignificant trailing zeros.
- Reject `NSDecimalNumber.notANumber`; `fail()` clears accumulator and pending operation and sets `.error(.invalidResult)`.
- When a result is installed, normalize `-0` to `0`.
- Consecutive operations only replace `pendingOperation` until the user enters a right operand.

- [ ] **Step 5: Run focused and calculator regression tests**

Run:

```bash
swift test --filter PatternCalculatorTests
swift test --filter GaugeCalculatorTests
swift test --filter EvenStitchAdjustmentCalculatorTests
swift test --filter RowIntervalAdjustmentCalculatorTests
```

Expected: all selected suites pass; the new calculator does not alter existing knitting calculators.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Calculators/PatternCalculator.swift \
  Tests/KnitNoteCoreTests/PatternCalculatorTests.swift
git commit -m "feat: add pattern calculator engine"
```

---

### Task 2: Build the Localized, Accessible Calculator Panel

**Files:**
- Create: `KnitNote/Patterns/PatternCalculatorView.swift`
- Create: `Tests/KnitNoteCoreTests/PatternCalculatorViewContractTests.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: `Binding<PatternCalculatorState>` and `PatternCalculatorState.press(_:)` from Task 1.
- Produces: `PatternCalculatorView(state:)`, a self-contained panel that does not know about `PatternReaderView`, stores, patterns, projects, or persistence.

- [ ] **Step 1: Write failing localization and view-contract tests**

Add these exact bilingual entries to a new required dictionary in `LocalizationContractTests`:

```swift
private let requiredPatternCalculatorTranslations = [
    "patterns.calculator.title": ["en": "Calculator", "zh-Hant": "計算機"],
    "patterns.calculator.hint": ["en": "Opens a calculator without leaving the pattern", "zh-Hant": "不離開織圖即可開啟計算機"],
    "patterns.calculator.clear": ["en": "All Clear", "zh-Hant": "全部清除"],
    "patterns.calculator.result": ["en": "Result", "zh-Hant": "結果"],
    "patterns.calculator.error": ["en": "Error", "zh-Hant": "錯誤"],
    "patterns.calculator.add": ["en": "Add", "zh-Hant": "加"],
    "patterns.calculator.subtract": ["en": "Subtract", "zh-Hant": "減"],
    "patterns.calculator.multiply": ["en": "Multiply", "zh-Hant": "乘"],
    "patterns.calculator.divide": ["en": "Divide", "zh-Hant": "除"],
    "patterns.calculator.equals": ["en": "Equals", "zh-Hant": "等於"],
    "patterns.calculator.percent": ["en": "Percent", "zh-Hant": "百分比"],
    "patterns.calculator.toggleSign": ["en": "Change Sign", "zh-Hant": "切換正負號"],
]
```

Create `PatternCalculatorViewContractTests.swift` to assert the source:

```swift
import Foundation
import Testing

@Suite struct PatternCalculatorViewContractTests {
    @Test func panelUsesOneBoundStateAndTheApprovedKeys() throws {
        let source = try appSource("KnitNote/Patterns/PatternCalculatorView.swift")
        #expect(source.contains("@Binding var state: PatternCalculatorState"))
        #expect(source.contains("state.press(key)"))
        for token in [".clear", ".toggleSign", ".percent", ".divide", ".multiply", ".subtract", ".add", ".decimal", ".equals"] {
            #expect(source.contains(token))
        }
        #expect(!source.contains("JSONProjectStore"))
        #expect(!source.contains("UserDefaults"))
    }
}
```

Add this complete repository-root helper at the bottom of the test file:

```swift
private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter PatternCalculatorViewContractTests
swift test --filter LocalizationContractTests
```

Expected: the view file and localization keys are missing.

- [ ] **Step 3: Implement the adaptive calculator panel**

Create `PatternCalculatorView.swift`:

```swift
import SwiftUI

struct PatternCalculatorView: View {
    @Environment(\.locale) private var locale
    @Binding var state: PatternCalculatorState

    private var rows: [[PatternCalculatorButton]] {
        [
            [.utility("AC", .clear, "patterns.calculator.clear"), .utility("±", .toggleSign, "patterns.calculator.toggleSign"), .utility("%", .percent, "patterns.calculator.percent"), .operation("÷", .divide, "patterns.calculator.divide")],
            [.digit(7), .digit(8), .digit(9), .operation("×", .multiply, "patterns.calculator.multiply")],
            [.digit(4), .digit(5), .digit(6), .operation("−", .subtract, "patterns.calculator.subtract")],
            [.digit(1), .digit(2), .digit(3), .operation("+", .add, "patterns.calculator.add")],
            [.digit(0, columnSpan: 2), .utility(decimalSeparator, .decimal, decimalSeparator), .operation("=", nil, "patterns.calculator.equals", key: .equals)],
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(displayText)
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .trailing)
                .accessibilityLabel(Text("patterns.calculator.result"))
                .accessibilityValue(Text(displayText))

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { button in
                            Button {
                                state.press(button.key)
                            } label: {
                                Text(button.label)
                                    .font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .background(button.background(isPending: button.operation == state.pendingOperationForDisplay))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        button.operation == state.pendingOperationForDisplay ? WatercolorTheme.actionBerry : .clear,
                                        lineWidth: button.operation == state.pendingOperationForDisplay ? 3 : 0
                                    )
                            }
                            .gridCellColumns(button.columnSpan)
                            .accessibilityLabel(Text(button.accessibilityKey))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(idealWidth: 320, maxWidth: 360)
        .background(WatercolorBackground())
    }
}
```

Add private view-only `PatternCalculatorButton` and `PatternCalculatorButtonRole` types in this file. The role enum has exactly `digit`, `utility`, and `operation`. The button stores `label: String`, `key: PatternCalculatorKey`, `role: PatternCalculatorButtonRole`, `accessibilityKey: LocalizedStringKey`, and `columnSpan: Int`; its `operation` computed property returns the associated operation only for `.operation`. Provide factory methods with these exact signatures: `digit(_ value: Int, columnSpan: Int = 1)`, `utility(_ label: String, _ key: PatternCalculatorKey, _ accessibilityKey: LocalizedStringKey)`, and `operation(_ label: String, _ operation: PatternCalculatorOperation?, _ accessibilityKey: LocalizedStringKey, key: PatternCalculatorKey? = nil)`. The operation factory uses `key ?? .operation(operation!)`; the one nil operation is equals and supplies `key: .equals`. `background(isPending:)` returns `WatercolorTheme.actionBerry.opacity(isPending ? 0.34 : 0.18)` for operations and `.white.opacity(0.72)` otherwise. Every visible key calls only `state.press(button.key)`.

The `displayText` computation must:

```swift
switch state.display {
case let .number(canonical):
    let separator = locale.decimalSeparator ?? "."
    return canonical.replacingOccurrences(of: ".", with: separator)
case .error:
    return String(localized: "patterns.calculator.error", locale: locale)
}
```

Do not parse the localized text back into the calculator.

- [ ] **Step 4: Add Mac keyboard input through the same state machine**

Add one private key mapper in `PatternCalculatorView.swift`:

```swift
private func calculatorKey(for character: Character) -> PatternCalculatorKey? {
    if let digit = character.wholeNumberValue { return .digit(digit) }
    switch character {
    case ".", ",": return .decimal
    case "+": return .operation(.add)
    case "-": return .operation(.subtract)
    case "*", "×": return .operation(.multiply)
    case "/", "÷": return .operation(.divide)
    case "%": return .percent
    case "=": return .equals
    default: return nil
    }
}
```

Add `@FocusState private var hasKeyboardFocus: Bool`, then attach this exact Mac-only forwarding path to the panel root:

```swift
#if os(macOS)
.focusable()
.focused($hasKeyboardFocus)
.onAppear { hasKeyboardFocus = true }
.onKeyPress(phases: .down) { press in
    if press.key == .return {
        state.press(.equals)
        return .handled
    }
    if press.key == .escape || press.key == .delete {
        state.press(.clear)
        return .handled
    }
    guard let character = press.characters.first,
          let key = calculatorKey(for: character) else {
        return .ignored
    }
    state.press(key)
    return .handled
}
#endif
```

This uses the same `state.press(_:)` arithmetic path as mouse and touch input.

- [ ] **Step 5: Add localization and verify GREEN**

Add the exact strings from Step 1 to `Localizable.xcstrings`. Run:

```bash
swift test --filter PatternCalculatorViewContractTests
swift test --filter LocalizationContractTests
```

Expected: both suites pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add KnitNote/Patterns/PatternCalculatorView.swift \
  KnitNote/Localization/Localizable.xcstrings \
  Tests/KnitNoteCoreTests/PatternCalculatorViewContractTests.swift \
  Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m "feat: add pattern calculator panel"
```

---

### Task 3: Integrate the Calculator Without Touching Reader Persistence

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Create: `Tests/KnitNoteCoreTests/PatternReaderCalculatorIntegrationTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `PatternCalculatorState` from Task 1 and `PatternCalculatorView(state:)` from Task 2.
- Produces: one toolbar entry and one adaptive presentation owned by the current `PatternReaderView` instance.

- [ ] **Step 1: Write failing integration contract tests**

Create `PatternReaderCalculatorIntegrationTests.swift`:

```swift
import Foundation
import Testing

@Suite struct PatternReaderCalculatorIntegrationTests {
    @Test func readerOwnsSessionStateAndPresentsThePanelFromItsToolbar() throws {
        let source = try appSource("KnitNote/Patterns/PatternReaderView.swift")
        #expect(source.contains("@State private var calculatorState = PatternCalculatorState()"))
        #expect(source.contains("@State private var showingCalculator = false"))
        #expect(source.contains("Label(\"patterns.calculator.title\", systemImage: \"plus.forwardslash.minus\")"))
        #expect(source.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(source.contains(".accessibilityHint(Text(\"patterns.calculator.hint\"))"))
        #expect(source.contains("PatternCalculatorView(state: $calculatorState)"))
        #expect(source.contains(".presentationCompactAdaptation(.sheet)"))
        #expect(source.contains(".presentationDetents([.medium])"))
    }

    @Test func calculatorIsNotWrittenIntoReaderOrStoreState() throws {
        let reader = try appSource("KnitNote/Patterns/PatternReaderView.swift")
        let document = try appSource("Sources/KnitNoteCore/Patterns/PatternDocument.swift")
        let usage = try appSource("Sources/KnitNoteCore/Patterns/PatternProjectUsage.swift")
        #expect(!document.contains("PatternCalculator"))
        #expect(!usage.contains("PatternCalculator"))
        #expect(!reader.contains("mutatePatternReaderCalculator"))
        #expect(!reader.contains("saveCalculator"))
    }
}
```

Add this complete source helper to the bottom of the integration test file:

```swift
private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter PatternReaderCalculatorIntegrationTests
```

Expected: assertions fail because the toolbar state and presentation are absent.

- [ ] **Step 3: Add reader-owned state and the toolbar presentation**

Add beside the other transient reader presentation state:

```swift
@State private var calculatorState = PatternCalculatorState()
@State private var showingCalculator = false
```

Add a primary toolbar item before the page-note item:

```swift
ToolbarItem(placement: .primaryAction) {
    Button {
        showingCalculator = true
    } label: {
        Label("patterns.calculator.title", systemImage: "plus.forwardslash.minus")
    }
    .frame(minWidth: 44, minHeight: 44)
    .accessibilityHint(Text("patterns.calculator.hint"))
    .popover(isPresented: $showingCalculator, attachmentAnchor: .rect(.bounds)) {
        PatternCalculatorView(state: $calculatorState)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.medium])
    }
}
```

Confirm on iPhone that compact adaptation is a medium sheet, while regular-width iPad and Mac remain popovers. Do not attach the presentation to the reader canvas, PDF view, page identity, or store generation.

Do not add calculator reset code to `reloadReader(for:)`: that method also runs for store-generation refreshes during the same reader instance. The two `@State` values naturally start fresh when a new `PatternReaderView` instance is created. Do not reset calculator state on sheet/popover dismissal, scene inactivity, rotation, page change, store generation observation, save, or markup change.

- [ ] **Step 4: Regenerate Xcode membership and verify focused tests/builds**

Run:

```bash
xcodegen generate
swift test --filter PatternReaderCalculatorIntegrationTests
swift test --filter PatternCalculatorTests
swift test --filter PatternCalculatorViewContractTests
swift test --filter LocalizationContractTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: all focused tests and both platform builds pass. Inspect the regenerated diff and confirm it contains only expected file membership updates; do not accept version/build drift.

- [ ] **Step 5: Commit Task 3**

```bash
git add KnitNote/Patterns/PatternReaderView.swift \
  Tests/KnitNoteCoreTests/PatternReaderCalculatorIntegrationTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: open calculator from pattern reader"
```

---

### Task 4: Full Regression and Exact-Candidate Physical Acceptance

**Files:**
- Modify only if an acceptance defect is found: files owned by Tasks 1–3 and their tests.
- Do not modify release metadata during this task.

**Interfaces:**
- Consumes: the complete calculator feature from Tasks 1–3.
- Produces: a verified calculator commit suitable for later inclusion in a separate 1.3.1 release candidate.

- [ ] **Step 1: Run the complete automated suite**

Run:

```bash
swift test --disable-sandbox
```

Expected: the full suite passes with zero failures.

- [ ] **Step 2: Run clean unsigned iOS and macOS builds**

Use a workspace-local derived-data directory so signing and stale caches do not hide compile failures:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .derived-data/reader-calculator-ios \
  CODE_SIGNING_ALLOWED=NO clean build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derived-data/reader-calculator-macos \
  CODE_SIGNING_ALLOWED=NO clean build
```

Expected: both builds end with `BUILD SUCCEEDED`.

- [ ] **Step 3: Perform iPhone physical acceptance**

Install the exact build produced from the recorded commit. With one multi-page PDF and one image pattern:

1. Move to a non-default page, zoom, scroll, and move both highlighters.
2. Open the calculator, calculate `12.5 × 4 = 50`, dismiss, and confirm every reader state remains unchanged.
3. Reopen and confirm `50` remains; press `AC` and confirm zero.
4. Rotate with the medium sheet open and after closing it; confirm no crash, clipping, unsafe-area overlap, PDF reload, or reader jump.
5. Exit the reader, reopen the same pattern, and confirm the calculator is zero while the normal saved reading state still restores.

- [ ] **Step 4: Perform iPad and Mac physical acceptance**

- iPad: repeat the state-preservation test in portrait and landscape; verify a compact popover, stable anchor, readable buttons, and no PDF/highlight movement.
- Mac: verify popover sizing, mouse input, digits, `+ - * / %`, decimal, Return/Enter, and clear by keyboard; confirm focus returns to the reader after dismissal.
- Both: enable VoiceOver and enlarged text; verify the toolbar entry, result, number keys, operators, `AC`, sign, percent, and equals are announced and operable.

- [ ] **Step 5: Record the verified boundary**

Record:

```bash
git rev-parse HEAD
git status --short
git diff --check
```

The acceptance record must name the exact commit and platform/build artifact. Stop if iPhone, iPad, and Mac were not built from the same commit. Do not merge, push, change version/build, upload, or submit without a separate release authorization.
