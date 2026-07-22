# Pattern Priority and iPad Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename Traditional Chinese “圖解” UI to “織圖”, prioritize pattern access on the project screen, refine highlight geometry, and make the PDF reader readable and unobstructed on iPad without regressing iPhone or saved reading state.

**Architecture:** Add pure, platform-neutral reader layout and highlight metric policies to `KnitNoteCore`, then let SwiftUI and PDFKit consume those policies. Keep the existing `PatternReadingState`, page navigator, restore gate, markup persistence, and note persistence unchanged. Split page navigation from the counter overlay so iPad portrait can reserve real height below the PDF while iPhone retains its current overlay.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, Swift Testing, String Catalogs, XcodeGen.

## Global Constraints

- Traditional Chinese user-facing “圖解” becomes “織圖”; English remains `Pattern`／`Patterns`.
- Project content order is photo, pattern, notes, counters, tool details, calculators, journal; completed status remains adjacent to the photo.
- Horizontal highlight visible thickness is 22 pt; vertical highlight is a solid pink 3 pt line; both keep a 44 pt drag target.
- iPad landscape uses fit-width PDF scaling; iPad portrait reserves a separate page-control row below the PDF.
- iPhone keeps its existing PDF scale and page-control placement.
- The pattern reader shows no visible document title on iPhone or iPad; VoiceOver still receives the document name.
- Existing page restoration, highlight positions, markup, page notes, counter rail safe area, and stored data formats must not change.
- Do not upload or submit an App Store build.

---

### Task 1: Define reader layout and highlight policies

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternReaderLayoutPolicy.swift`
- Create: `Tests/KnitNoteCoreTests/PatternReaderLayoutPolicyTests.swift`

**Interfaces:**
- Produces: `PatternPDFScaleMode`, `PatternPageControlPlacement`, `PatternReaderLayoutPolicy.resolve(isPad:width:height:)`, and `PatternHighlightMetrics`.
- Consumed by: `PatternReaderView`, `PDFReaderView`, `HighlightOverlay`, and later contract tests.

- [ ] **Step 1: Write the failing policy tests**

```swift
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderLayoutPolicyTests {
    @Test func iPadLandscapeFitsWidthAndKeepsOverlayPageControls() {
        let policy = PatternReaderLayoutPolicy.resolve(isPad: true, width: 1194, height: 834)
        #expect(policy.pdfScaleMode == .fitWidth)
        #expect(policy.pageControlPlacement == .overlay)
    }

    @Test func iPadPortraitReservesPageControlsBelowThePDF() {
        let policy = PatternReaderLayoutPolicy.resolve(isPad: true, width: 834, height: 1194)
        #expect(policy.pdfScaleMode == .automatic)
        #expect(policy.pageControlPlacement == .reservedBelow)
    }

    @Test func iPhoneKeepsAutomaticOverlayBehaviorInBothOrientations() {
        #expect(PatternReaderLayoutPolicy.resolve(isPad: false, width: 430, height: 932)
            == .init(pdfScaleMode: .automatic, pageControlPlacement: .overlay))
        #expect(PatternReaderLayoutPolicy.resolve(isPad: false, width: 932, height: 430)
            == .init(pdfScaleMode: .automatic, pageControlPlacement: .overlay))
    }

    @Test func squareIPadUsesPortraitSafeBehavior() {
        let policy = PatternReaderLayoutPolicy.resolve(isPad: true, width: 800, height: 800)
        #expect(policy.pdfScaleMode == .automatic)
        #expect(policy.pageControlPlacement == .reservedBelow)
    }

    @Test func highlightMetricsMatchTheApprovedVisualAndTouchSizes() {
        #expect(PatternHighlightMetrics.horizontalVisibleThickness == 22)
        #expect(PatternHighlightMetrics.verticalVisibleThickness == 3)
        #expect(PatternHighlightMetrics.minimumDragThickness == 44)
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --filter PatternReaderLayoutPolicyTests
```

Expected: compilation fails because `PatternReaderLayoutPolicy` and `PatternHighlightMetrics` do not exist.

- [ ] **Step 3: Implement the minimal pure policies**

```swift
import CoreGraphics

public enum PatternPDFScaleMode: Sendable, Equatable {
    case automatic
    case fitWidth
}

public enum PatternPageControlPlacement: Sendable, Equatable {
    case overlay
    case reservedBelow
}

public struct PatternReaderLayoutPolicy: Sendable, Equatable {
    public let pdfScaleMode: PatternPDFScaleMode
    public let pageControlPlacement: PatternPageControlPlacement

    public init(
        pdfScaleMode: PatternPDFScaleMode,
        pageControlPlacement: PatternPageControlPlacement
    ) {
        self.pdfScaleMode = pdfScaleMode
        self.pageControlPlacement = pageControlPlacement
    }

    public static func resolve(isPad: Bool, width: Double, height: Double) -> Self {
        guard isPad else {
            return .init(pdfScaleMode: .automatic, pageControlPlacement: .overlay)
        }
        if width > height {
            return .init(pdfScaleMode: .fitWidth, pageControlPlacement: .overlay)
        }
        return .init(pdfScaleMode: .automatic, pageControlPlacement: .reservedBelow)
    }
}

public enum PatternHighlightMetrics {
    public static let horizontalVisibleThickness: CGFloat = 22
    public static let verticalVisibleThickness: CGFloat = 3
    public static let minimumDragThickness: CGFloat = 44
}
```

- [ ] **Step 4: Run the policy tests and verify GREEN**

Run: `swift test --filter PatternReaderLayoutPolicyTests`

Expected: 5 tests pass.

- [ ] **Step 5: Commit the policy**

```bash
git add Sources/KnitNoteCore/Patterns/PatternReaderLayoutPolicy.swift Tests/KnitNoteCoreTests/PatternReaderLayoutPolicyTests.swift
git commit -m "Add adaptive pattern reader layout policy"
```

---

### Task 2: Rename Traditional Chinese UI and reorder the project screen

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNote/Projects/ProjectDetailView.swift:30-145`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`

**Interfaces:**
- Consumes: existing localization keys; no key or data model changes.
- Produces: approved Traditional Chinese copy and project screen ordering.

- [ ] **Step 1: Write failing localization and ordering tests**

Add a localization test inside the existing `LocalizationContractTests` suite. It uses the existing `catalogStrings()` and `localizedValue(_:language:strings:)` helpers, walks every `zh-Hant.stringUnit.value`, and asserts no value contains `圖解`:

```swift
@Test func traditionalChineseUsesKnittingPatternTerminology() throws {
    let strings = try catalogStrings()
    let values = strings.values.compactMap { entry -> String? in
        guard let entry = entry as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let translation = localizations["zh-Hant"] as? [String: Any],
              let stringUnit = translation["stringUnit"] as? [String: Any]
        else { return nil }
        return stringUnit["value"] as? String
    }
    let forbidden = values.filter { $0.contains("圖解") }
    #expect(forbidden.isEmpty)
    #expect(try localizedValue("patterns.title", language: "zh-Hant", strings: strings) == "織圖")
    #expect(try localizedValue("patterns.open", language: "zh-Hant", strings: strings) == "織圖")
    #expect(try localizedValue("patterns.add", language: "zh-Hant", strings: strings) == "加入織圖")
}
```

Create a source-order contract test:

```swift
import Foundation
import Testing

@Suite struct ProjectDetailLayoutContractTests {
    @Test func projectFeaturesFollowTheApprovedKnittingOrder() throws {
        let source = try projectSource()
        let photo = try #require(source.range(of: "ProjectPhotoView("))
        let pattern = try #require(source.range(of: "projectActionCard(\"patterns.open\""))
        let note = try #require(source.range(of: "projectActionCard(\"notes.edit\""))
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let tools = try #require(source.range(of: "if hasToolDetails(project)"))
        let calculator = try #require(source.range(of: "KnittingCalculatorsView()"))
        let journal = try #require(source.range(of: "ProjectJournalSection("))

        #expect(photo.lowerBound < pattern.lowerBound)
        #expect(pattern.lowerBound < note.lowerBound)
        #expect(note.lowerBound < counters.lowerBound)
        #expect(counters.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < calculator.lowerBound)
        #expect(calculator.lowerBound < journal.lowerBound)
    }

    private func projectSource() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "KnitNote/Projects/ProjectDetailView.swift"))
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
swift test --filter LocalizationContractTests
swift test --filter ProjectDetailLayoutContractTests
```

Expected: localization fails with existing `圖解` values; order test fails because tools and counters currently precede pattern and notes.

- [ ] **Step 3: Update every `zh-Hant` pattern value without changing keys or English**

Mechanically replace user-facing Traditional Chinese occurrences:

```text
圖解 → 織圖
加入圖解 → 加入織圖
刪除圖解？ → 刪除織圖？
圖解錯誤 → 織圖錯誤
無法讀取圖解 → 無法讀取織圖
還沒有圖解 → 還沒有織圖
找不到圖解檔案 → 找不到織圖檔案
作品圖解 → 作品織圖
```

Do not rename localization keys such as `patterns.title`.

- [ ] **Step 4: Reorder `ProjectDetailView`**

Move existing blocks rather than rewriting them. The `VStack` order must be:

```swift
ProjectPhotoView(...)
if project.isCompleted { ... }
projectActionCard("patterns.open", icon: "doc.text.image") { showingPatterns = true }
projectActionCard("notes.edit", icon: "note.text") { ... }
let sortedNotes = ...
if !sortedNotes.isEmpty { ... }
WatercolorCard { CounterSelectorGrid(...) }
if hasToolDetails(project) { ... }
WatercolorCard { NavigationLink { KnittingCalculatorsView() } ... }
WatercolorCard { ProjectJournalSection(...) }
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter LocalizationContractTests
swift test --filter ProjectDetailLayoutContractTests
```

Expected: both suites pass.

- [ ] **Step 6: Commit localization and ordering**

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNote/Projects/ProjectDetailView.swift Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift
git commit -m "Prioritize pattern access on project details"
```

---

### Task 3: Refine horizontal and vertical highlight geometry

**Files:**
- Modify: `KnitNote/Patterns/HighlightOverlay.swift:21-47`
- Create: `Tests/KnitNoteCoreTests/HighlightOverlayContractTests.swift`

**Interfaces:**
- Consumes: `PatternHighlightMetrics` from Task 1 and existing highlight bindings.
- Produces: approved visible geometry while retaining drag and VoiceOver behavior.

- [ ] **Step 1: Write the failing source contract test**

```swift
import Foundation
import Testing

@Suite struct HighlightOverlayContractTests {
    @Test func overlayUsesPolicyMetricsAndKeepsBothAccessibleDragControls() throws {
        let source = try highlightSource()
        #expect(source.contains("PatternHighlightMetrics.horizontalVisibleThickness"))
        #expect(source.contains("PatternHighlightMetrics.verticalVisibleThickness"))
        #expect(source.contains("PatternHighlightMetrics.minimumDragThickness"))
        #expect(source.contains("Rectangle().fill(.pink)"))
        #expect(!source.contains(".fill(.pink.opacity(0.32))"))
        #expect(source.components(separatedBy: ".accessibilityAdjustableAction").count - 1 == 2)
    }

    private func highlightSource() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "KnitNote/Patterns/HighlightOverlay.swift"))
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `swift test --filter HighlightOverlayContractTests`

Expected: fails because the view still hard-codes 44 pt translucent bands.

- [ ] **Step 3: Separate visible shapes from drag targets**

Implement each control as a 44 pt `ZStack` with a smaller visible child:

```swift
private func horizontalBand(in size: CGSize) -> some View {
    ZStack(alignment: .trailing) {
        RoundedRectangle(cornerRadius: 4)
            .fill(.yellow.opacity(0.32))
            .frame(height: PatternHighlightMetrics.horizontalVisibleThickness)
        Color.clear
            .contentShape(Rectangle())
            .frame(height: PatternHighlightMetrics.minimumDragThickness)
    }
    .frame(height: PatternHighlightMetrics.minimumDragThickness)
    .position(
        x: size.width / 2,
        y: max(22, min(size.height - 22, size.height * horizontalPosition))
    )
    .gesture(DragGesture().onChanged { value in
        horizontalPosition = min(1, max(0, value.location.y / max(1, size.height)))
    })
    .accessibilityLabel(Text("patterns.highlight.horizontalControl"))
    .accessibilityAdjustableAction { direction in
        let delta = direction == .increment ? 0.05 : -0.05
        horizontalPosition = min(1, max(0, horizontalPosition + delta))
    }
}

private func verticalBand(in size: CGSize) -> some View {
    ZStack {
        Rectangle().fill(.pink)
            .frame(width: PatternHighlightMetrics.verticalVisibleThickness)
        Color.clear
            .contentShape(Rectangle())
            .frame(width: PatternHighlightMetrics.minimumDragThickness)
    }
    .frame(width: PatternHighlightMetrics.minimumDragThickness)
    .position(
        x: max(22, min(size.width - 22, size.width * verticalPosition)),
        y: size.height / 2
    )
    .gesture(DragGesture().onChanged { value in
        verticalPosition = min(1, max(0, value.location.x / max(1, size.width)))
    })
    .accessibilityLabel(Text("patterns.highlight.verticalControl"))
    .accessibilityAdjustableAction { direction in
        let delta = direction == .increment ? 0.05 : -0.05
        verticalPosition = min(1, max(0, verticalPosition + delta))
    }
}
```

Retain the existing 0.05 VoiceOver adjustment delta and normalized position bindings. Do not add thickness persistence.

- [ ] **Step 4: Run focused and existing pattern-state tests**

Run:

```bash
swift test --filter HighlightOverlayContractTests
swift test --filter PatternDocumentTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit highlight geometry**

```bash
git add KnitNote/Patterns/HighlightOverlay.swift Tests/KnitNoteCoreTests/HighlightOverlayContractTests.swift
git commit -m "Refine pattern highlight geometry"
```

---

### Task 4: Split page controls from the counter overlay and remove the visible reader title

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderControls.swift:3-90`
- Modify: `KnitNote/Patterns/PatternReaderView.swift:40-174`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes: `PatternReaderLayoutPolicy` and `PatternPageControlPlacement` from Task 1.
- Produces: `PatternPageControls`, counter overlay with optional page controls, and an untitled reader with an accessibility document name.

- [ ] **Step 1: Write failing reader layout source contracts**

Add tests asserting:

```swift
@Test func iPadPortraitCanReservePageControlsOutsideTheReaderOverlay() throws {
    let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")
    let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
    #expect(controls.contains("struct PatternPageControls: View"))
    #expect(reader.contains("pageControlPlacement == .reservedBelow"))
    #expect(reader.contains("PatternPageControls("))
}

@Test func readerHasNoVisibleNavigationTitleButKeepsAnAccessibilityName() throws {
    let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
    #expect(!reader.contains(".navigationTitle(pattern?.displayName"))
    #expect(reader.contains(".accessibilityLabel(Text(pattern.displayName))"))
}
```

Update the existing counter-rail test so it still requires the 64 pt trailing padding.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter PatternReaderCounterContractTests`

Expected: fails because page controls are private inside the overlay and the visible navigation title remains.

- [ ] **Step 3: Extract `PatternPageControls`**

Move the existing previous/page count/next `HStack` into:

```swift
struct PatternPageControls: View {
    let pageIndex: Int
    let pageCount: Int
    let onPreviousPage: () -> Void
    let onNextPage: () -> Void

    var body: some View {
        HStack {
            Button(action: onPreviousPage) { Label("patterns.previousPage", systemImage: "chevron.left") }
                .disabled(pageIndex == 0)
            Spacer()
            Text(verbatim: "\(pageIndex + 1) / \(pageCount)")
                .font(.caption.monospacedDigit())
            Spacer()
            Button(action: onNextPage) { Label("patterns.nextPage", systemImage: "chevron.right") }
                .disabled(pageIndex >= pageCount - 1)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
```

`PatternReaderControls` receives `showsOverlayPageControls: Bool`; when true it wraps `PatternPageControls` in the existing capsule material. The counter rail remains unchanged.

- [ ] **Step 4: Apply layout policy in `PatternReaderView`**

Use `GeometryReader` around the reader content:

```swift
GeometryReader { proxy in
    let isPad = readerIsPad
    let layout = PatternReaderLayoutPolicy.resolve(
        isPad: isPad,
        width: proxy.size.width,
        height: proxy.size.height
    )
    VStack(spacing: 0) {
        readerCanvas(pattern: pattern, layout: layout)
        if pattern.kind == .pdf,
           pageCount > 0,
           layout.pageControlPlacement == .reservedBelow,
           !markupMode {
            PatternPageControls(
                pageIndex: state.pageIndex,
                pageCount: pageCount,
                onPreviousPage: { navigatePDF(by: -1) },
                onNextPage: { navigatePDF(by: 1) }
            )
            .background(.ultraThinMaterial)
        }
    }
}
```

On iOS, `readerIsPad` is `UIDevice.current.userInterfaceIdiom == .pad`; on macOS it is false. Pass `showsOverlayPageControls: layout.pageControlPlacement == .overlay` to `PatternReaderControls`.

Define the platform check explicitly:

```swift
private var readerIsPad: Bool {
#if os(iOS)
    UIDevice.current.userInterfaceIdiom == .pad
#else
    false
#endif
}
```

Move the existing ZStack into this helper so the outer VStack can reserve page-control height:

```swift
@ViewBuilder
private func readerCanvas(
    pattern: PatternDocument,
    layout: PatternReaderLayoutPolicy
) -> some View {
    ZStack(alignment: .top) {
        ZStack(alignment: .top) {
            if pattern.kind == .pdf {
                PDFReaderView(
                    url: store.patternURL(projectID: projectID, pattern: pattern),
                    navigator: pdfNavigator,
                    state: $state,
                    pageCount: $pageCount,
                    loadError: $loadError
                )
                .allowsHitTesting(!markupMode)
            } else {
                ImageReaderView(
                    url: store.patternURL(projectID: projectID, pattern: pattern),
                    state: $state,
                    loadError: $loadError
                )
                .allowsHitTesting(!markupMode)
            }
            if state.highlightEnabled {
                HighlightOverlay(
                    mode: state.highlightMode,
                    horizontalPosition: $state.highlightPosition,
                    verticalPosition: $state.verticalHighlightPosition
                )
                .allowsHitTesting(!markupMode)
            }
            if markupMode {
                PatternMarkupOverlay(
                    document: $markup,
                    tool: markupTool,
                    color: markupColor,
                    width: markupWidth
                )
            }
        }
        .padding(.trailing, counterRailSafeAreaWidth)
        .accessibilityLabel(Text(pattern.displayName))

        if let project = store.project(id: projectID), !markupMode {
            PatternReaderControls(
                counters: project.counters,
                isEnabled: !project.isCompleted,
                pageIndex: state.pageIndex,
                pageCount: pattern.kind == .pdf ? pageCount : 0,
                showsOverlayPageControls: layout.pageControlPlacement == .overlay,
                onPreviousPage: { navigatePDF(by: -1) },
                onNextPage: { navigatePDF(by: 1) },
                onIncrement: incrementCounter,
                onManage: { counterID in
                    managingCounter = project.counters.first { $0.id == counterID }
                }
            )
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
}
```

Remove `.navigationTitle(...)`. Apply `.accessibilityLabel(Text(pattern.displayName))` to the PDF/image canvas so assistive technologies retain the name without a visible title.

- [ ] **Step 5: Run focused tests and build iOS targets**

Run:

```bash
swift test --filter PatternReaderCounterContractTests
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Expected: tests pass and build exits 0.

- [ ] **Step 6: Commit reader control layout**

```bash
git add KnitNote/Patterns/PatternReaderControls.swift KnitNote/Patterns/PatternReaderView.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m "Reserve iPad pattern page controls"
```

---

### Task 5: Implement iPad landscape fit-width scaling without changing page state

**Files:**
- Modify: `KnitNote/Patterns/PDFReaderView.swift:4-105`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Create: `Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift`

**Interfaces:**
- Consumes: `PatternPDFScaleMode` from Task 1.
- Produces: idempotent `PDFReaderView` scale updates that preserve current page and reading state.

- [ ] **Step 1: Write failing scale integration contracts**

```swift
import Foundation
import Testing

@Suite struct PDFReaderScaleContractTests {
    @Test func readerPassesAdaptiveScaleModeIntoPDFKit() throws {
        let reader = try source("KnitNote/Patterns/PatternReaderView.swift")
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        #expect(reader.contains("scaleMode: layout.pdfScaleMode"))
        #expect(pdf.contains("let scaleMode: PatternPDFScaleMode"))
        #expect(pdf.contains("applyScaleMode"))
    }

    @Test func fitWidthDoesNotTransitionOrOverwriteReadingState() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let method = try #require(pdf.slice(from: "private func applyScaleMode", to: "@objc private func changed"))
        #expect(!method.contains("state.transitionToPDFPage"))
        #expect(!method.contains("state.highlight"))
        #expect(!method.contains("state.pageNote"))
    }
}
```

The test helper reads paths relative to `#filePath`; add this bounded substring helper inside the test file:

```swift
private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex)
        else { return nil }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter PDFReaderScaleContractTests`

Expected: fails because `PDFReaderView` has no scale mode.

- [ ] **Step 3: Thread `scaleMode` through the representable and navigator**

Add `let scaleMode: PatternPDFScaleMode` to the macOS and iOS representables. Change both update methods to:

```swift
context.coordinator.update(view, state: state, scaleMode: scaleMode)
```

The coordinator update method is:

```swift
func update(
    _ view: PDFView,
    state: PatternReadingState,
    scaleMode: PatternPDFScaleMode
) {
    latestScaleMode = scaleMode
    if restoreGate.beginRestoring() {
        scheduleRestore(view)
    } else if restoreGate.canSample {
        applyScaleMode(scaleMode, to: view)
    }
}
```

Remove `view.autoScales = true` from `PDFPageNavigator.go(to:)`. Store the latest scale mode in the coordinator and reapply it from the existing `.PDFViewPageChanged` callback after `go(to:)`; the navigator remains responsible only for requesting and changing the page.

- [ ] **Step 4: Apply scale only after layout and only when inputs change**

In `Coordinator`, track the last mode, bounds size, page index, and page bounds. Implement:

```swift
private struct ScaleSignature: Equatable {
    let mode: PatternPDFScaleMode
    let size: CGSize
    let pageIndex: Int
}

private var latestScaleMode = PatternPDFScaleMode.automatic
private var lastScaleSignature: ScaleSignature?

private func applyScaleMode(_ mode: PatternPDFScaleMode, to view: PDFView) {
    guard let page = view.currentPage,
          let document = view.document
    else { return }
#if os(macOS)
    view.layoutSubtreeIfNeeded()
#else
    view.layoutIfNeeded()
#endif
    let signature = ScaleSignature(
        mode: mode,
        size: view.bounds.size,
        pageIndex: document.index(for: page)
    )
    guard signature != lastScaleSignature else { return }
    lastScaleSignature = signature

    switch mode {
    case .automatic:
        view.autoScales = true
    case .fitWidth:
        let pageWidth = page.bounds(for: view.displayBox).width
        let availableWidth = max(1, view.bounds.width - 16)
        guard pageWidth > 0 else { return }
        let widthScale = availableWidth / pageWidth
        let sizeToFit = view.scaleFactorForSizeToFit
        view.autoScales = false
        view.minScaleFactor = min(sizeToFit, widthScale)
        view.maxScaleFactor = max(widthScale * 4, widthScale)
        view.scaleFactor = widthScale
    }
}
```

In `PatternReaderView.readerCanvas`, update the Task 4 PDF construction to include `scaleMode: layout.pdfScaleMode`.

Call `applyScaleMode` after the initial page restore succeeds, on representable updates caused by rotation, and from `.PDFViewPageChanged` after navigator page changes:

```swift
@objc private func changed(_ note: Notification) {
    guard let view = note.object as? PDFView else { return }
    if note.name == .PDFViewPageChanged {
        lastScaleSignature = nil
        applyScaleMode(latestScaleMode, to: view)
    }
    sample(view)
}
```

Do not write scale, offset, page, highlight, markup, or note values into `PatternReadingState` from `applyScaleMode`.

- [ ] **Step 5: Verify state regression suites and platform builds**

Run:

```bash
swift test --filter PDFReaderScaleContractTests
swift test --filter PatternDocumentTests
swift test --filter PatternReaderCounterContractTests
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' build
```

Expected: all tests and both builds exit 0.

- [ ] **Step 6: Commit adaptive PDF scaling**

```bash
git add KnitNote/Patterns/PDFReaderView.swift KnitNote/Patterns/PatternReaderView.swift Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift
git commit -m "Fit iPad landscape patterns to width"
```

---

### Task 6: Regenerate the project and complete regression and visual verification

**Files:**
- Modify: `KnitNote.xcodeproj/project.pbxproj` if XcodeGen output changes
- Modify: `docs/superpowers/plans/2026-07-22-pattern-priority-ipad-reader.md` only to check completed task boxes during execution

**Interfaces:**
- Consumes: all previous tasks.
- Produces: verified iPhone/iPad/macOS project with no stale generated project references.

- [ ] **Step 1: Regenerate Xcode project**

Run:

```bash
xcodegen generate
git diff -- KnitNote.xcodeproj/project.pbxproj
```

Expected: any diff contains only deterministic file-reference changes required by the new core/test files.

- [ ] **Step 2: Run the complete automated suite**

Run:

```bash
swift test
git diff --check
```

Expected: all tests pass and `git diff --check` exits 0 with no output.

- [ ] **Step 3: Run platform builds**

Run:

```bash
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' build
```

Expected: both builds exit 0.

- [ ] **Step 4: Inspect iPhone portrait**

Launch on an iPhone simulator and verify:

1. Project details read photo → 織圖 → 筆記 → counters → tools/calculators → journal.
2. The pattern reader has no visible document title.
3. Page controls retain the existing overlay layout.
4. Horizontal highlight covers roughly one text row; vertical highlight is a solid pink line.
5. Page navigation, markup, page note, and saved highlight position still work after closing and reopening.

- [ ] **Step 5: Inspect iPad portrait and landscape**

Launch on an iPad simulator and verify:

1. Portrait page controls occupy a separate row below the PDF and do not cover the bottom of the A4 page.
2. Landscape PDF fills the safe available width excluding the 64 pt counter rail; text is readable and the page can pan vertically.
3. Rotate portrait → landscape → portrait while on page 2 with both highlights, markup, and a page note; page and all annotations remain unchanged.
4. Previous/next buttons still navigate exactly one page.

- [ ] **Step 6: Run localization residue check**

Run:

```bash
rg -n '圖解' KnitNote/Localization/Localizable.xcstrings
```

Expected: no Traditional Chinese user-facing value contains `圖解`. If the raw catalog contains the term outside `zh-Hant` values, inspect it and confirm it is not user-facing Traditional Chinese copy.

- [ ] **Step 7: Commit generated project and verification bookkeeping**

```bash
git add KnitNote.xcodeproj/project.pbxproj docs/superpowers/plans/2026-07-22-pattern-priority-ipad-reader.md
git commit -m "Verify adaptive pattern reader layout"
```

Only include `project.pbxproj` if it changed. Do not add `.superpowers/`, `KnitNote 5.xcodeproj/`, or `KnitNote 6.xcodeproj/`.
