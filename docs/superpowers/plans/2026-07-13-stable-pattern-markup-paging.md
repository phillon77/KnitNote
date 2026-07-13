# Stable Pattern Markup Paging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the visible PDF page stable when markup is toggled and make page buttons directly and reliably navigate while handwriting is active.

**Architecture:** A small testable request gate protects confirmed page state from stale PDFKit callbacks. A main-actor `PDFPageNavigator` owns a weak reference to the live `PDFView`, so buttons issue direct page commands rather than waiting for a state-binding feedback loop. `PatternReaderView` uses fixed top, center, and bottom regions so toggling markup never resizes the PDF canvas.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, Swift Testing, Swift Package Manager, Xcode 26.

## Global Constraints

- Preserve discrete single-page PDF reading and horizontal swiping.
- Keep handwriting, highlights, page notes, and project row counts unchanged except for page synchronization.
- Keep every page's markup in its existing independent JSON file.
- Support iOS/iPadOS 18 or newer and macOS 15 or newer.
- Add no third-party dependencies.
- Do not include the pre-existing `KnitNote/Localization/Localizable.xcstrings` working-tree change in these commits.

---

### Task 1: Confirmed PDF Page Request State

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`

**Interfaces:**
- Produces: `PatternPDFPageRequestGate.request(_:)`, `accepts(_:)`, and `requestedPageIndex` for the PDF coordinator.
- Consumes: Zero-based PDF page indexes.

- [ ] **Step 1: Replace the existing gate regression test with complete request semantics**

```swift
@Test func pdfPageRequestRejectsStaleCallbacksUntilTargetIsConfirmed() {
    var gate = PatternPDFPageRequestGate()
    gate.request(2)
    let stale = gate.accepts(1)
    let confirmed = gate.accepts(2)
    let laterSwipe = gate.accepts(3)
    #expect(!stale)
    #expect(confirmed)
    #expect(laterSwipe)
    #expect(gate.requestedPageIndex == nil)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter pdfPageRequestRejectsStaleCallbacksUntilTargetIsConfirmed
```

Expected: compilation fails because `accepts(_:)` does not exist.

- [ ] **Step 3: Implement the minimal request gate API**

```swift
public mutating func accepts(_ visiblePageIndex: Int) -> Bool {
    guard let requestedPageIndex else { return true }
    guard visiblePageIndex == requestedPageIndex else { return false }
    self.requestedPageIndex = nil
    return true
}
```

Remove `shouldAcceptSample(_:)` and update its call sites in Task 2.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: one selected test passes.

- [ ] **Step 5: Commit the state-machine change**

Stage only the two listed files and commit with message `Clarify confirmed PDF page requests`.

### Task 2: Direct Live PDF Navigation

**Files:**
- Modify: `KnitNote/Patterns/PDFReaderView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`

**Interfaces:**
- Produces: `@MainActor final class PDFPageNavigator` with `attach(_:)` and `go(to:)`.
- Consumes: `PatternPDFPageRequestGate` from Task 1 and a zero-based target from page controls.

- [ ] **Step 1: Add a navigator that commands the live PDF view**

```swift
@MainActor final class PDFPageNavigator: ObservableObject {
    private weak var view: PDFView?
    private var request: ((Int) -> Void)?

    func attach(_ view: PDFView, request: @escaping (Int) -> Void) {
        self.view = view
        self.request = request
    }

    func go(to pageIndex: Int) {
        guard let view, let document = view.document,
              document.pageCount > 0 else { return }
        let target = min(document.pageCount - 1, max(0, pageIndex))
        guard let page = document.page(at: target) else { return }
        request?(target)
        view.go(to: page)
    }
}
```

- [ ] **Step 2: Attach the navigator inside `PDFReaderView.Coordinator.make(url:)`**

Pass `PDFPageNavigator` into `PDFReaderView`, store it in the coordinator, and attach it after assigning the document. The request closure must call `pageRequestGate.request(target)` before `view.go(to:)` occurs.

- [ ] **Step 3: Publish only confirmed pages from `sample(_:)`**

```swift
let visiblePage = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
guard pageRequestGate.accepts(visiblePage) else { return }
state.transitionToPDFPage(visiblePage)
state.zoomScale = 1
state.offsetX = 0
state.offsetY = 0
```

Remove state-driven `showRequestedPage(in:state:)`; buttons now use the navigator and swipes remain PDFKit-driven.

- [ ] **Step 4: Route buttons through the navigator**

In `PatternReaderView`, add `@StateObject private var pdfNavigator = PDFPageNavigator()`. For PDFs, calculate the bounded target from the confirmed `state.pageIndex` and call `pdfNavigator.go(to:)`. Do not call `state.movePDFPage` from the buttons; the confirmed PDF callback changes state and triggers the existing per-page markup save/load hook.

- [ ] **Step 5: Run all package tests**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
```

Expected: all tests pass with zero failures.

- [ ] **Step 6: Commit direct navigation**

Stage only the two listed app files and commit with message `Navigate the live PDF view directly`.

### Task 3: Fixed Markup Reader Regions

**Files:**
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Patterns/PatternMarkupToolbar.swift`

**Interfaces:**
- Consumes: `PDFPageNavigator` from Task 2.
- Produces: A stable toolbar region, central canvas, and bottom controls with non-overlapping hit-test areas.

- [ ] **Step 1: Replace conditional safe-area insets with explicit regions**

The successful pattern branch must have this structure:

```swift
VStack(spacing: 0) {
    PatternMarkupToolbar(
        document: $markup,
        tool: $markupTool,
        color: $markupColor,
        width: $markupWidth,
        onClear: { confirmingMarkupClear = true },
        onDone: finishMarkup
    )
    .opacity(markupMode ? 1 : 0)
    .allowsHitTesting(markupMode)
    .accessibilityHidden(!markupMode)
    .frame(height: PatternMarkupToolbar.stableHeight)

    ZStack(alignment: .top) {
        reader(pattern)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()

    PatternReaderControls(/* existing arguments */)
}
```

Extract a private `@ViewBuilder func reader(_ pattern: PatternDocument) -> some View` only if needed to keep `body` readable.

- [ ] **Step 2: Give the toolbar one stable height**

Add:

```swift
static let stableHeight: CGFloat = 60
```

Keep its existing material background and controls. The hidden toolbar reserves the same height, so the central PDF canvas does not change size when markup toggles.

- [ ] **Step 3: Verify markup page lifecycle remains confirmed-page-driven**

Keep:

```swift
.onChange(of: state.pageIndex) { oldPage, newPage in
    saveMarkup(page: oldPage)
    loadMarkup(page: newPage)
}
```

Do not add a markup-mode handler that changes `state.pageIndex`, recreates `PDFReaderView`, or calls page navigation.

- [ ] **Step 4: Build iOS/iPadOS and macOS**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: both commands end with `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit the stable layout**

Stage only the two listed files and commit with message `Keep the PDF canvas stable during markup`.

### Task 4: Final Regression Verification

**Files:**
- Verify only; no production changes expected.

**Interfaces:**
- Consumes all prior tasks.
- Produces fresh automated verification evidence and an iPad test checklist for the user.

- [ ] **Step 1: Run the complete Swift test suite**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
```

Expected: all tests pass with zero failures.

- [ ] **Step 2: Run clean platform builds**

Run both Task 3 build commands. Expected: both builds succeed.

- [ ] **Step 3: Inspect the final diff and working tree**

```bash
git diff --check
git status --short
git log -4 --oneline
```

Expected: no whitespace errors; only the preserved localization change may remain unstaged; the three implementation commits and this plan commit appear in history.

- [ ] **Step 4: Hand off the exact iPad test**

Ask the user to verify: swipe to page two and toggle markup without a page change; draw on pages one and two using buttons; toggle markup again; close and reopen; confirm the last page and per-page strokes persist.
