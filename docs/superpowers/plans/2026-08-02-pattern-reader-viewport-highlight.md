# Pattern Reader Viewport Highlight Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep horizontal, vertical, and cross highlights attached to the same PDF page content while the user scrolls or zooms, especially on iPad in landscape.

**Architecture:** Introduce a small `PatternPDFViewportState` value and publication gate in `KnitNoteCore`, then make the PDFKit adapter publish that state from page, scale, layout, and internal scroll events. `PatternReaderView` projects its existing normalized highlight coordinates through the viewport's live `pageFrame`; persisted highlight, note, markup, page-transition, and zoom semantics remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, UIKit/AppKit scroll observation, Swift Testing, Xcode 26.6.

## Global Constraints

- This plan implements only live viewport/highlight synchronization. It does not persist `pdfWidthScaleRatio` and does not add the thumbnail strip.
- Horizontal and vertical highlight positions remain normalized `0...1` page-content coordinates and are written only by explicit highlight editing.
- Existing per-page highlight, note, and handwriting data must remain byte-for-byte compatible.
- Do not replace PDFKit's internal scroll-view delegate and do not add high-frequency polling; use event-driven observation.
- The existing 0.25-second timer may remain only as the current-page synchronization fallback, not as the viewport publisher.
- Invalid or non-finite page geometry publishes `pageFrame == nil`, temporarily hiding PDF highlights instead of moving them to the canvas center.
- iPhone, iPad, and Mac PDF readers use the same viewport interface; image-reader behavior remains unchanged.
- No version, build, archive schema, localization, App Store, push, upload, or release changes are authorized.

---

### Task 1: Add the pure PDF viewport state boundary

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternPDFViewportState.swift`
- Create: `Tests/KnitNoteCoreTests/PatternPDFViewportStateTests.swift`

**Interfaces:**
- Consumes: `CGRect`, `CGFloat`, and the existing normalized highlight projection in `PatternHighlightGeometry`.
- Produces: `PatternPDFViewportState` and `PatternPDFViewportPublicationGate.accept(_:)` for the PDFKit adapter in Task 2.

- [ ] **Step 1: Write failing viewport-state tests**

Create tests that require a finite positive frame, positive finite scale values, and publication only when the visible viewport changes:

```swift
import CoreGraphics
import Testing
@testable import KnitNoteCore

@Suite struct PatternPDFViewportStateTests {
    @Test func validViewportPreservesPageGeometryAndScale() {
        let frame = CGRect(x: -40, y: 120, width: 612, height: 792)
        let state = PatternPDFViewportState(
            pageIndex: 3,
            pageFrame: frame,
            scaleFactor: 1.75,
            fitWidthScaleFactor: 1.25,
            isUserInteracting: true
        )

        #expect(state.pageIndex == 3)
        #expect(state.pageFrame == frame)
        #expect(state.scaleFactor == 1.75)
        #expect(state.fitWidthScaleFactor == 1.25)
        #expect(state.isUserInteracting)
    }

    @Test func invalidViewportValuesDegradeSafely() {
        let state = PatternPDFViewportState(
            pageIndex: -4,
            pageFrame: CGRect(x: .nan, y: 0, width: 100, height: 100),
            scaleFactor: .infinity,
            fitWidthScaleFactor: 0,
            isUserInteracting: false
        )

        #expect(state.pageIndex == 0)
        #expect(state.pageFrame == nil)
        #expect(state.scaleFactor == 1)
        #expect(state.fitWidthScaleFactor == 1)
    }

    @Test func publicationGateAcceptsScrollFrameChangesButRejectsDuplicates() {
        var gate = PatternPDFViewportPublicationGate()
        let first = PatternPDFViewportState(pageFrame: CGRect(x: 0, y: 0, width: 500, height: 700))
        let scrolled = PatternPDFViewportState(pageFrame: CGRect(x: 0, y: -180, width: 500, height: 700))

        #expect(gate.accept(first))
        #expect(!gate.accept(first))
        #expect(gate.accept(scrolled))
        gate.reset()
        #expect(gate.accept(scrolled))
    }
}
```

- [ ] **Step 2: Run the focused tests and observe RED**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-viewport-state-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-viewport-state-cache \
swift test --disable-sandbox --filter PatternPDFViewportStateTests
```

Expected: compilation fails because `PatternPDFViewportState` and `PatternPDFViewportPublicationGate` do not exist.

- [ ] **Step 3: Implement the minimal state and gate**

Create:

```swift
import CoreGraphics

public struct PatternPDFViewportState: Equatable, Sendable {
    public var pageIndex: Int
    public var pageFrame: CGRect?
    public var scaleFactor: CGFloat
    public var fitWidthScaleFactor: CGFloat
    public var isUserInteracting: Bool

    public init(
        pageIndex: Int = 0,
        pageFrame: CGRect? = nil,
        scaleFactor: CGFloat = 1,
        fitWidthScaleFactor: CGFloat = 1,
        isUserInteracting: Bool = false
    ) {
        self.pageIndex = max(0, pageIndex)
        self.pageFrame = Self.validFrame(pageFrame)
        self.scaleFactor = Self.validScale(scaleFactor)
        self.fitWidthScaleFactor = Self.validScale(fitWidthScaleFactor)
        self.isUserInteracting = isUserInteracting
    }

    private static func validFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        return frame
    }

    private static func validScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }
}

public struct PatternPDFViewportPublicationGate: Sendable {
    private var lastAccepted: PatternPDFViewportState?

    public init() {}

    public mutating func accept(_ candidate: PatternPDFViewportState) -> Bool {
        guard candidate != lastAccepted else { return false }
        lastAccepted = candidate
        return true
    }

    public mutating func reset() {
        lastAccepted = nil
    }
}
```

- [ ] **Step 4: Run the focused tests and observe GREEN**

Run the Step 2 command again. Expected: 3 tests pass with 0 failures.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Patterns/PatternPDFViewportState.swift \
  Tests/KnitNoteCoreTests/PatternPDFViewportStateTests.swift
git commit -m "feat: add PDF viewport state boundary"
```

---

### Task 2: Publish the viewport from PDF page, scale, layout, and scroll events

**Files:**
- Modify: `KnitNote/Patterns/PDFReaderView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes: `PatternPDFViewportState`, `PatternPDFViewportPublicationGate`, `PatternPDFPageFrameGeometry.flippedFrame(_:in:)`, existing `PatternReadingState`, and `PatternPDFScaleMode`.
- Produces: `PDFReaderView.viewport: Binding<PatternPDFViewportState>` and event-driven viewport publication without taking ownership of PDFKit's scroll delegate.

- [ ] **Step 1: Write failing adapter and reader contracts**

Extend `PDFReaderScaleContractTests` to require:

```swift
@Test func readerPublishesOneViewportFromPageScaleLayoutAndScrollEvents() throws {
    let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")

    #expect(pdf.contains("@Binding var viewport: PatternPDFViewportState"))
    #expect(pdf.contains("private func publishViewport(from view: PDFView"))
    #expect(pdf.contains("viewportPublicationGate.accept(candidate)"))
    #expect(pdf.contains("installScrollObservation(in: view)"))
    #expect(pdf.contains("contentOffsetObservation"))
    #expect(pdf.contains("NSView.boundsDidChangeNotification"))
    #expect(!pdf.contains("scroll.delegate ="))
}

@Test func fallbackTimerDoesNotPublishViewport() throws {
    let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
    let sample = try #require(pdf.slice(from: "private func sample", to: "deinit"))
    #expect(!sample.contains("publishViewport"))
    #expect(!sample.contains("pageFrame"))
}
```

Update `PatternReaderCounterContractTests` to require `@State private var pdfViewport = PatternPDFViewportState()`, `viewport: $pdfViewport`, and `contentRect: content.kind == .pdf ? pdfViewport.pageFrame : nil`.

- [ ] **Step 2: Run the focused contracts and observe RED**

Run:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-viewport-contract-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-viewport-contract-cache \
swift test --disable-sandbox --filter PDFReaderScaleContractTests

env CLANG_MODULE_CACHE_PATH=/tmp/knitnote-viewport-contract-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-viewport-contract-cache \
swift test --disable-sandbox --filter PatternReaderCounterContractTests
```

Expected: both focused suites fail because the reader still binds only `pageFrame` and does not observe internal scroll movement.

- [ ] **Step 3: Replace the page-frame binding with the viewport binding**

In both platform representables, replace `@Binding var pageFrame: CGRect?` with `@Binding var viewport: PatternPDFViewportState`, provide `.constant(PatternPDFViewportState())` as the default binding, and pass the binding into the coordinator. In `PatternReaderView`, replace `pdfPageFrame` with `pdfViewport`, pass `$pdfViewport`, project the overlay through `pdfViewport.pageFrame`, and reset the whole viewport when the reader context reloads.

The coordinator owns:

```swift
@Binding private var viewport: PatternPDFViewportState
private var viewportPublicationGate = PatternPDFViewportPublicationGate()
private var lastPublishedViewport: PatternPDFViewportState?
```

Rename `publishPageFrame(from:)` to `publishViewport(from:isUserInteracting:)`. Build the candidate with the current page index, converted page frame, `view.scaleFactor`, `view.scaleFactorForSizeToFit`, and interaction state. Publish only when `viewportPublicationGate.accept(candidate)` succeeds, and retain the existing last-candidate guard inside the `Task` so stale asynchronous callbacks cannot overwrite a newer snapshot.

- [ ] **Step 4: Install platform scroll observers without replacing delegates**

On iOS/iPadOS, recursively locate PDFKit's internal `UIScrollView` and keep an `NSKeyValueObservation` of `contentOffset`. Its callback schedules `publishViewport` on `MainActor`, passing `scroll.isDragging || scroll.isDecelerating || scroll.isZooming`.

On macOS, recursively locate the internal `NSScrollView`, set `contentView.postsBoundsChangedNotifications = true`, and observe `NSView.boundsDidChangeNotification` for that clip view. Its callback publishes the viewport and uses `scroll.inLiveResize || scroll.contentView.inLiveResize` as the interaction hint.

Call `installScrollObservation(in:)` after assigning the PDF document, after restore/layout, and from platform update methods so delayed PDFKit subview creation is handled. Page-change and scale-change notifications and every explicit layout/scale application call `publishViewport`; the 0.25-second `sample()` remains page-only and must not publish viewport geometry.

Cancel the KVO token/remove the notification token in `deinit`. Do not set either internal scroll view's delegate.

- [ ] **Step 5: Run focused tests and platform builds**

Run both Step 2 commands, then:

```bash
xcodebuild -quiet build -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/knitnote-viewport-mac \
  CODE_SIGNING_ALLOWED=NO

xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/knitnote-viewport-ios \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: focused suites pass and both builds exit 0.

- [ ] **Step 6: Verify the iPad symptom before broadening scope**

Install one signed candidate on the physical iPad. Open a multi-page PDF in landscape, move horizontal and vertical highlights onto identifiable text, zoom, then scroll to the page top, middle, and bottom. Confirm both highlights stay attached to the same page content. Rotate landscape to portrait and back; confirm normalized highlight positions are unchanged. Confirm page notes and handwriting remain on their original pages.

If any part fails, stop here and fix viewport publication. Do not begin width persistence or thumbnails.

- [ ] **Step 7: Commit Task 2**

```bash
git add KnitNote/Patterns/PDFReaderView.swift \
  KnitNote/Patterns/PatternReaderView.swift \
  Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift \
  Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m "fix: keep PDF highlights attached while scrolling"
```

---

## Completion Gate

- Task 1 and Task 2 reviews are clean.
- Focused viewport and reader tests pass.
- macOS and generic iOS Simulator builds pass.
- Physical iPad landscape scroll, zoom, and rotation acceptance passes for horizontal and vertical highlights.
- Only after this gate may the separate shared-width persistence plan begin; thumbnails remain later.
