# PDF Pattern Page-Relative Highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep PDF highlight lines attached to the same page content position when an iPad rotates or the PDF scale mode changes.

**Architecture:** Add a pure page-relative coordinate helper to `KnitNoteCore`. `PDFReaderView` reports the currently displayed PDF page frame in its own view coordinates, and `PatternReaderView` passes that frame to `HighlightOverlay`, which renders and drags inside the page frame while retaining the existing normalized persisted values.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, CoreGraphics, Swift Testing, Xcode

## Global Constraints

- Preserve `PatternReadingState`, page-specific highlight values, and the current archive version.
- Do not migrate or rewrite existing persisted data.
- Keep current highlight colors, visible thicknesses, 44 pt drag targets, and VoiceOver adjustable actions.
- Keep image-pattern highlights on their current full-canvas coordinate system.
- Preserve page navigation, notes, markup, counters, completed-project read-only behavior, and the 64 pt counter rail safe area.
- Do not modify `.superpowers/brainstorm/`, `KnitNote 5.xcodeproj/`, or `KnitNote 6.xcodeproj/`.
- Do not push, upload, or submit an App Store build.

---

### Task 1: Define page-relative highlight geometry

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternReaderLayoutPolicy.swift`
- Create: `Tests/KnitNoteCoreTests/PatternHighlightGeometryTests.swift`

**Interfaces:**
- Consumes: optional PDF page `CGRect` and the full overlay `CGSize`.
- Produces:
  - `PatternHighlightGeometry.resolvedContentRect(_:canvasSize:) -> CGRect`
  - `PatternHighlightGeometry.coordinate(normalized:origin:length:) -> CGFloat`
  - `PatternHighlightGeometry.normalized(coordinate:origin:length:) -> Double`

- [ ] **Step 1: Write failing geometry tests**

Create `Tests/KnitNoteCoreTests/PatternHighlightGeometryTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import KnitNoteCore

@Suite struct PatternHighlightGeometryTests {
    @Test func sameNormalizedLineSurvivesPortraitAndLandscapePageFrames() {
        let portrait = CGRect(x: 72, y: 96, width: 620, height: 900)
        let landscape = CGRect(x: 84, y: -238, width: 940, height: 1364)

        let portraitY = PatternHighlightGeometry.coordinate(
            normalized: 0.72,
            origin: portrait.minY,
            length: portrait.height
        )
        let landscapeY = PatternHighlightGeometry.coordinate(
            normalized: 0.72,
            origin: landscape.minY,
            length: landscape.height
        )

        #expect(PatternHighlightGeometry.normalized(
            coordinate: portraitY,
            origin: portrait.minY,
            length: portrait.height
        ) == 0.72)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: landscapeY,
            origin: landscape.minY,
            length: landscape.height
        ) == 0.72)
    }

    @Test func dragPositionsClampToTheDisplayedPage() {
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 40,
            origin: 100,
            length: 800
        ) == 0)
        #expect(PatternHighlightGeometry.normalized(
            coordinate: 960,
            origin: 100,
            length: 800
        ) == 1)
    }

    @Test func missingOrInvalidPageFrameFallsBackToTheCanvas() {
        let canvas = CGSize(width: 700, height: 900)
        #expect(PatternHighlightGeometry.resolvedContentRect(nil, canvasSize: canvas)
            == CGRect(origin: .zero, size: canvas))
        #expect(PatternHighlightGeometry.resolvedContentRect(
            CGRect(x: 1, y: 2, width: 0, height: 500),
            canvasSize: canvas
        ) == CGRect(origin: .zero, size: canvas))
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter PatternHighlightGeometryTests
```

Expected: compilation fails because `PatternHighlightGeometry` does not exist.

- [ ] **Step 3: Add the minimal pure geometry implementation**

Append to `Sources/KnitNoteCore/Patterns/PatternReaderLayoutPolicy.swift`:

```swift
public enum PatternHighlightGeometry {
    public static func resolvedContentRect(
        _ contentRect: CGRect?,
        canvasSize: CGSize
    ) -> CGRect {
        let fallback = CGRect(origin: .zero, size: canvasSize)
        guard let contentRect,
              contentRect.origin.x.isFinite,
              contentRect.origin.y.isFinite,
              contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentRect.width > 0,
              contentRect.height > 0
        else {
            return fallback
        }
        return contentRect
    }

    public static func coordinate(
        normalized: Double,
        origin: CGFloat,
        length: CGFloat
    ) -> CGFloat {
        let clamped = min(1, max(0, normalized))
        return origin + (length * clamped)
    }

    public static func normalized(
        coordinate: CGFloat,
        origin: CGFloat,
        length: CGFloat
    ) -> Double {
        guard length.isFinite, length > 0 else { return 0.5 }
        return min(1, max(0, Double((coordinate - origin) / length)))
    }
}
```

- [ ] **Step 4: Run focused and existing layout tests**

Run:

```bash
swift test --filter PatternHighlightGeometryTests
swift test --filter PatternReaderLayoutPolicyTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit the geometry policy**

```bash
git add Sources/KnitNoteCore/Patterns/PatternReaderLayoutPolicy.swift Tests/KnitNoteCoreTests/PatternHighlightGeometryTests.swift
git commit -m "fix: define page-relative highlight geometry"
```

---

### Task 2: Report the displayed PDF page frame

**Files:**
- Modify: `KnitNote/Patterns/PDFReaderView.swift`
- Modify: `Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift`

**Interfaces:**
- Consumes: PDFKit `PDFView.currentPage`, `PDFView.displayBox`, page bounds, and the current `PDFView` layout.
- Produces: `PDFReaderView.pageFrame: Binding<CGRect?>`, updated after load, page navigation, scale changes, view-size changes, and periodic sampling.

- [ ] **Step 1: Add failing source-contract assertions**

In `Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift`, add:

```swift
@Test func readerReportsTheCurrentDisplayedPageFrame() throws {
    let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
    #expect(pdf.contains("@Binding var pageFrame: CGRect?"))
    #expect(pdf.contains("view.convert(page.bounds(for: view.displayBox), from: page)"))
    #expect(pdf.contains("publishPageFrame"))
}
```

Reuse the suite's existing source-file helper rather than adding a second file loader.

- [ ] **Step 2: Run the contract suite and verify RED**

Run:

```bash
swift test --filter PDFReaderScaleContractTests
```

Expected: the new assertions fail because `PDFReaderView` does not expose or publish a page frame.

- [ ] **Step 3: Thread the page-frame binding through the representable**

In both platform declarations in `KnitNote/Patterns/PDFReaderView.swift`, add:

```swift
@Binding var pageFrame: CGRect?
```

Pass `$pageFrame` into the coordinator:

```swift
Coordinator(
    state: $state,
    pageCount: $pageCount,
    error: $loadError,
    pageFrame: $pageFrame,
    navigator: navigator,
    onReady: onReady
)
```

In `Coordinator`, add:

```swift
@Binding private var pageFrame: CGRect?
private var lastPublishedPageFrame: CGRect?
```

Update the initializer to receive and assign `Binding<CGRect?>`.

- [ ] **Step 4: Publish only valid, changed page frames**

Add this coordinator method:

```swift
private func publishPageFrame(from view: PDFView) {
    guard let page = view.currentPage else {
        if lastPublishedPageFrame != nil {
            lastPublishedPageFrame = nil
            Task { @MainActor [weak self] in self?.pageFrame = nil }
        }
        return
    }

    let converted = view.convert(page.bounds(for: view.displayBox), from: page)
    let candidate: CGRect? = converted.origin.x.isFinite
        && converted.origin.y.isFinite
        && converted.width.isFinite
        && converted.height.isFinite
        && converted.width > 0
        && converted.height > 0
        ? converted
        : nil

    guard candidate != lastPublishedPageFrame else { return }
    lastPublishedPageFrame = candidate
    Task { @MainActor [weak self] in self?.pageFrame = candidate }
}
```

Call `publishPageFrame(from:)`:

- after `applyScaleMode` completes;
- from `changed(_:)` after scale/page handling;
- from `sample(_:)` before reading page state, so scrolling and delayed PDFKit layout are observed;
- after the initial restore succeeds.

Do not write page-frame data into `PatternReadingState`.

- [ ] **Step 5: Run the PDF contract and pattern-reader tests**

Run:

```bash
swift test --filter PDFReaderScaleContractTests
swift test --filter PatternReaderSessionTests
swift test --filter PatternReaderPageTransitionTests
```

Expected: all suites pass.

- [ ] **Step 6: Commit PDF page-frame reporting**

```bash
git add KnitNote/Patterns/PDFReaderView.swift Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift
git commit -m "fix: report displayed PDF page frame"
```

---

### Task 3: Anchor highlight rendering and dragging to the PDF page

**Files:**
- Modify: `KnitNote/Patterns/HighlightOverlay.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `Tests/KnitNoteCoreTests/HighlightOverlayContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes:
  - `PatternHighlightGeometry`
  - `PDFReaderView.pageFrame`
  - existing `horizontalPosition` and `verticalPosition` bindings
- Produces:
  - `HighlightOverlay.init(mode:horizontalPosition:verticalPosition:contentRect:)`
  - PDF page-relative rendering and named-coordinate-space dragging

- [ ] **Step 1: Add failing integration contracts**

Add to `HighlightOverlayContractTests`:

```swift
@Test func overlayUsesAnOptionalContentRectAndCanvasCoordinateDragging() throws {
    let source = try highlightSource()
    #expect(source.contains("let contentRect: CGRect?"))
    #expect(source.contains("PatternHighlightGeometry.resolvedContentRect"))
    #expect(source.contains("PatternHighlightGeometry.coordinate"))
    #expect(source.contains("PatternHighlightGeometry.normalized"))
    #expect(source.contains("coordinateSpace: .named"))
}
```

Add to `PatternReaderCounterContractTests` using its existing source helper:

```swift
@Test func pdfReaderFrameFeedsTheHighlightWithoutChangingImageBehavior() throws {
    let source = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
    #expect(source.contains("@State private var pdfPageFrame: CGRect?"))
    #expect(source.contains("pageFrame: $pdfPageFrame"))
    #expect(source.contains("content.kind == .pdf ? pdfPageFrame : nil"))
}
```

- [ ] **Step 2: Run both contract suites and verify RED**

Run:

```bash
swift test --filter HighlightOverlayContractTests
swift test --filter PatternReaderCounterContractTests
```

Expected: the new assertions fail because the page frame is not connected to the overlay.

- [ ] **Step 3: Make `HighlightOverlay` page-relative**

Add:

```swift
let contentRect: CGRect?
private let coordinateSpaceName = "patternHighlightCanvas"
```

Inside `GeometryReader`, resolve:

```swift
let rect = PatternHighlightGeometry.resolvedContentRect(
    contentRect,
    canvasSize: proxy.size
)
```

Render the horizontal band with:

```swift
.frame(
    width: rect.width,
    height: PatternHighlightMetrics.minimumDragThickness
)
.position(
    x: rect.midX,
    y: PatternHighlightGeometry.coordinate(
        normalized: horizontalPosition,
        origin: rect.minY,
        length: rect.height
    )
)
.gesture(
    DragGesture(coordinateSpace: .named(coordinateSpaceName))
        .onChanged { value in
            horizontalPosition = PatternHighlightGeometry.normalized(
                coordinate: value.location.y,
                origin: rect.minY,
                length: rect.height
            )
        }
)
```

Render the vertical band with the matching page-relative height, `rect.midY`, `rect.minX`, and `rect.width`. Put:

```swift
.coordinateSpace(name: coordinateSpaceName)
```

on the `GeometryReader` content container. Keep both existing accessibility labels and adjustable actions unchanged.

- [ ] **Step 4: Connect the PDF frame in `PatternReaderView`**

Add:

```swift
@State private var pdfPageFrame: CGRect?
```

Pass it to the PDF representable:

```swift
pageFrame: $pdfPageFrame
```

Pass only PDF frames to the overlay:

```swift
contentRect: content.kind == .pdf ? pdfPageFrame : nil
```

Set `pdfPageFrame = nil` when reloading a different reader identity, before the replacement content becomes active. Do not change `PatternReadingState`.

- [ ] **Step 5: Run focused and persistence tests**

Run:

```bash
swift test --filter PatternHighlightGeometryTests
swift test --filter HighlightOverlayContractTests
swift test --filter PDFReaderScaleContractTests
swift test --filter PatternReaderCounterContractTests
swift test --filter PatternDocumentTests
swift test --filter PatternReaderSessionTests
swift test --filter PatternReaderPageTransitionTests
```

Expected: every suite passes.

- [ ] **Step 6: Commit the reader integration**

```bash
git add KnitNote/Patterns/HighlightOverlay.swift KnitNote/Patterns/PatternReaderView.swift Tests/KnitNoteCoreTests/HighlightOverlayContractTests.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m "fix: anchor PDF highlights to page content"
```

---

### Task 4: Complete automated and physical verification

**Files:**
- Modify only if all verification evidence can be recorded accurately: `AppStore/Verification/PatternLibraryVerification.md`

**Interfaces:**
- Consumes: the completed implementation from Tasks 1–3.
- Produces: clean test/build evidence and an iPad build ready for the user’s physical orientation check.

- [ ] **Step 1: Run formatting and repository checks**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only the three protected user-owned untracked paths remain outside committed work.

- [ ] **Step 2: Run the complete Swift test suite**

Run:

```bash
swift test
```

Expected: exit 0 with all suites passing.

- [ ] **Step 3: Build iOS and macOS without signing**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnitNoteHighlight-iOS \
  CODE_SIGNING_ALLOWED=NO build -quiet

xcodebuild -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNoteHighlight-macOS \
  CODE_SIGNING_ALLOWED=NO build -quiet
```

Expected: both commands exit 0.

- [ ] **Step 4: Build, install, and launch the signed iPad build**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'id=00008103-001934E41128A01E' \
  -derivedDataPath /tmp/KnitNoteHighlight-iPad build -quiet

xcrun devicectl device install app \
  --device 00008103-001934E41128A01E \
  /tmp/KnitNoteHighlight-iPad/Build/Products/Debug-iphoneos/KnitNote.app

xcrun devicectl device process launch \
  --device 00008103-001934E41128A01E \
  com.phillon.KnitNote
```

Expected: build and installation succeed and KnitNote launches without deleting existing data.

- [ ] **Step 5: Perform the iPad physical acceptance sequence**

Ask the user to verify, one step at a time:

1. In portrait, place the horizontal line over identifiable text.
2. Rotate to landscape and confirm the same text remains highlighted.
3. Rotate back to portrait and confirm it remains highlighted.
4. Repeat with vertical and cross modes.
5. Change pages, close the reader, reopen it, and confirm each page restores correctly.

Do not record any item as passed without the user’s physical confirmation.

- [ ] **Step 6: Record only confirmed evidence and commit**

If the complete iPad sequence passes, add a dated row to `AppStore/Verification/PatternLibraryVerification.md` describing the exact device, OS, orientations, highlight modes, page reopen check, and commit under test.

Then run:

```bash
git diff --check
swift test
git add AppStore/Verification/PatternLibraryVerification.md
git commit -m "docs: record iPad highlight rotation acceptance"
```

If any physical step fails, do not update the evidence file; return to systematic debugging with the exact failed step.
