# Pattern Reader Shared Width Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve one user-selected PDF width ratio across every page of one pattern usage, rotations, normal exits, and reopen.

**Architecture:** Store a PDF-only `pdfWidthScaleRatio` on `PatternReadingState`, so each `PatternProjectUsage` owns one ratio while all of its pages share it. Convert between the saved ratio and PDFKit's current fit-width baseline through a pure `PatternPDFScalePolicy`; the PDF adapter applies saved values programmatically without recapturing them as user changes, while normal reader persistence saves the page and ratio together.

**Tech Stack:** Swift 6, SwiftUI, PDFKit, Swift Testing, Codable project archives.

## Global Constraints

- Keep the accepted event-driven viewport/highlight behavior from commit `0313a56` unchanged.
- `pdfWidthScaleRatio = currentScale / currentFitWidthScale`; `1.0` means the current fit-width baseline.
- The ratio belongs to `PatternReadingState` for one `PatternProjectUsage`, never to `PatternPageState`.
- Every page of one usage shares the ratio; the same pattern linked to two projects retains two independent ratios.
- Legacy archives versions 1 through 10 decode a missing or invalid ratio as `1.0`.
- Raise `ProjectArchive.currentVersion` from `10` to `11` exactly once; keep `minimumSupportedVersion == 1`.
- Do not change image-reader `zoomScale`, per-page highlights, notes, handwriting, pattern/project links, or backup contents other than the new archive field/version.
- Programmatic page, layout, rotation, and restore scaling must not overwrite the saved ratio.
- User pinch/zoom changes update the ratio only after the adapter can sample a valid finite positive scale and fit-width baseline.
- Apply the saved ratio through the current PDFKit minimum/maximum scale limits; invalid inputs fall back to fit width.
- Persist the current page and ratio on Done, scene inactive, normal disappearance, and successful page transitions; failed transitions keep the prior page and ratio.
- Do not add the page thumbnail strip in this plan.

---

### Task 1: Usage-Scoped Width Model and Archive Compatibility

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternPDFScalePolicy.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternDocument.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternProjectUsage.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`
- Test: `Tests/KnitNoteCoreTests/PatternReaderSessionTests.swift`
- Test: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Test: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Produces: `PatternPDFScalePolicy.normalizedRatio(_:) -> Double`.
- Produces: `PatternPDFScalePolicy.ratio(currentScale:fitWidthScale:) -> Double`.
- Produces: `PatternPDFScalePolicy.absoluteScale(ratio:fitWidthScale:allowed:) -> Double`.
- Produces: `PatternReadingState.pdfWidthScaleRatio: Double` and `PatternBrowsingState.pdfWidthScaleRatio: Double`.
- Produces: `PatternProjectUsage.updatePDFWidthScaleRatio(_:now:)`.
- Preserves: all existing `PatternReadingState` initializers with a default ratio of `1.0`.

- [ ] **Step 1: Write failing pure scale-policy tests**

Add literal, hand-derived cases to `PatternDocumentTests.swift`:

```swift
@Test func pdfScalePolicyConvertsBetweenFitWidthRatioAndAbsoluteScale() {
    #expect(PatternPDFScalePolicy.ratio(currentScale: 1.8, fitWidthScale: 1.2) == 1.5)
    #expect(PatternPDFScalePolicy.absoluteScale(
        ratio: 1.5,
        fitWidthScale: 0.9,
        allowed: 0.5...3.0
    ) == 1.35)
}

@Test func pdfScalePolicyFallsBackAndClampsAtPDFKitLimits() {
    #expect(PatternPDFScalePolicy.ratio(currentScale: .infinity, fitWidthScale: 1.0) == 1.0)
    #expect(PatternPDFScalePolicy.ratio(currentScale: 2.0, fitWidthScale: 0.0) == 1.0)
    #expect(PatternPDFScalePolicy.absoluteScale(ratio: 8.0, fitWidthScale: 0.5, allowed: 0.25...2.0) == 2.0)
    #expect(PatternPDFScalePolicy.absoluteScale(ratio: -1.0, fitWidthScale: 0.8, allowed: 0.25...2.0) == 0.8)
}
```

- [ ] **Step 2: Run policy tests and verify RED**

Run: `swift test --filter PatternDocumentTests`

Expected: FAIL because `PatternPDFScalePolicy` and `pdfWidthScaleRatio` do not exist.

- [ ] **Step 3: Write failing state, usage-isolation, and compatibility tests**

Add tests that prove:

```swift
@Test func pdfWidthRatioIsSharedAcrossPagesWithoutChangingPageDetails() {
    var state = PatternReadingState(
        pageIndex: 0,
        pdfWidthScaleRatio: 1.6,
        highlightPosition: 0.2,
        pageNote: "body",
        pageStates: [1: .init(horizontalPosition: 0.8, verticalPosition: 0.3, note: "sleeve")]
    )
    state.transitionToPDFPage(1)
    #expect(state.pdfWidthScaleRatio == 1.6)
    #expect(state.pageNote == "sleeve")
    #expect(state.highlightPosition == 0.8)
}

@Test func twoProjectUsagesKeepIndependentPDFWidthRatios() {
    let patternID = UUID()
    let first = PatternProjectUsage(patternID: patternID, projectID: UUID(), sortOrder: 0,
        readingState: .init(pdfWidthScaleRatio: 1.25))
    let second = PatternProjectUsage(patternID: patternID, projectID: UUID(), sortOrder: 1,
        readingState: .init(pdfWidthScaleRatio: 2.0))
    #expect(first.readingState.pdfWidthScaleRatio == 1.25)
    #expect(second.readingState.pdfWidthScaleRatio == 2.0)
}
```

Also decode a literal legacy `PatternReadingState` JSON payload with no ratio and payloads containing `0`, `-1`, `Double.nan`, and `Double.infinity` via keyed test fixtures; assert `1.0`. Encode/decode a rich state and assert the ratio, page states, highlights, note, offsets, and image `zoomScale` all round-trip unchanged. Assert `ProjectArchive.currentVersion == 11`, `minimumSupportedVersion == 1`, and versions 1 through 10 remain supported.

- [ ] **Step 4: Run state and archive tests and verify RED**

Run: `swift test --filter 'PatternDocumentTests|PatternReaderSessionTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'`

Expected: FAIL because the ratio field, normalization, browsing projection, and archive version 11 are missing.

- [ ] **Step 5: Implement the minimal model and policy**

Create `PatternPDFScalePolicy.swift` with a pure, Sendable namespace:

```swift
public enum PatternPDFScalePolicy: Sendable {
    public static let defaultRatio = 1.0

    public static func normalizedRatio(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : defaultRatio
    }

    public static func ratio(currentScale: Double, fitWidthScale: Double) -> Double {
        guard currentScale.isFinite, currentScale > 0,
              fitWidthScale.isFinite, fitWidthScale > 0 else { return defaultRatio }
        return normalizedRatio(currentScale / fitWidthScale)
    }

    public static func absoluteScale(
        ratio: Double,
        fitWidthScale: Double,
        allowed: ClosedRange<Double>
    ) -> Double {
        let cleanFit = fitWidthScale.isFinite && fitWidthScale > 0 ? fitWidthScale : defaultRatio
        let lower = allowed.lowerBound.isFinite && allowed.lowerBound > 0 ? allowed.lowerBound : cleanFit
        let upper = allowed.upperBound.isFinite && allowed.upperBound >= lower ? allowed.upperBound : max(lower, cleanFit)
        let candidate = normalizedRatio(ratio) * cleanFit
        return min(upper, max(lower, candidate.isFinite && candidate > 0 ? candidate : cleanFit))
    }
}
```

Add the ratio to `PatternReadingState` with explicit `CodingKeys`, `init(from:)`, and `encode(to:)`, decoding through `normalizedRatio`. Add the ratio to `PatternBrowsingState`, copy it in `init(readingState:)`, and restore it in `applyBrowsingState(_:)`. Page transitions must not modify it. Add `updatePDFWidthScaleRatio` to `PatternProjectUsage` and normalize there. Set `ProjectArchive.currentVersion = 11`.

- [ ] **Step 6: Run focused model tests and verify GREEN**

Run: `swift test --filter 'PatternDocumentTests|PatternReaderSessionTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'`

Expected: PASS with zero failures.

- [ ] **Step 7: Commit the model boundary**

```bash
git add Sources/KnitNoteCore/Patterns/PatternPDFScalePolicy.swift Sources/KnitNoteCore/Patterns/PatternDocument.swift Sources/KnitNoteCore/Patterns/PatternProjectUsage.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/PatternDocumentTests.swift Tests/KnitNoteCoreTests/PatternReaderSessionTests.swift Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "feat: persist pattern PDF width ratio"
```

---

### Task 2: PDFKit Restoration and Normal-Exit Persistence

**Files:**
- Modify: `KnitNote/Patterns/PDFReaderView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Test: `Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes: `PatternReadingState.pdfWidthScaleRatio` and `PatternPDFScalePolicy` from Task 1.
- Produces: one adapter path that applies a saved ratio after initial restore, page change, layout, and rotation.
- Produces: one capture path that writes a valid user-selected ratio back through the existing state binding.
- Preserves: the accepted nested-scroll viewport observation and highlight projection from `0313a56`.

- [ ] **Step 1: Write failing adapter and persistence contract tests**

Extend `PDFReaderScaleContractTests.swift` and `PatternReaderCounterContractTests.swift` to require observable behavior boundaries:

```swift
@Test func pdfReaderRestoresSavedWidthInsteadOfResettingEveryPageToFitWidth() throws {
    let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
    #expect(pdf.contains("PatternPDFScalePolicy.absoluteScale"))
    #expect(pdf.contains("state.pdfWidthScaleRatio"))
    #expect(pdf.contains("isApplyingSavedScale"))
}

@Test func normalReaderExitAndSuccessfulPageChangePersistBrowsingState() throws {
    let reader = try source("KnitNote/Patterns/PatternReaderView.swift")
    #expect(reader.contains("_ = saveBrowsingState()"))
    let pageChange = try #require(reader.slice(from: ".onChange(of: state.pageIndex)", to: ".onChange(of: scenePhase)"))
    #expect(pageChange.contains("saveBrowsingState()"))
}
```

Add source-contract assertions that programmatic scale application is guarded, captures use `PatternPDFScalePolicy.ratio`, page-change callbacks no longer force `state.zoomScale = 1`, and the existing scroll-observation code remains present.

- [ ] **Step 2: Run adapter contracts and verify RED**

Run: `swift test --filter 'PDFReaderScaleContractTests|PatternReaderCounterContractTests'`

Expected: FAIL because the saved ratio is not applied or captured and successful page transitions do not persist browsing state.

- [ ] **Step 3: Implement fit-width baseline, guarded restoration, and capture**

In `PDFReaderView.Coordinator`:

1. Add `isApplyingSavedScale` and a `fitWidthBaseline(for:mode:)` helper. For `.fitWidth`, use `(view.bounds.width - 16) / pageWidth`; for `.automatic`, use the valid positive `view.scaleFactorForSizeToFit`.
2. Replace each unconditional `view.scaleFactor = widthScale` with `PatternPDFScalePolicy.absoluteScale(ratio: state.pdfWidthScaleRatio, fitWidthScale: baseline, allowed: view.minScaleFactor...view.maxScaleFactor)` inside `isApplyingSavedScale = true` / `defer { isApplyingSavedScale = false }`.
3. When `.PDFViewScaleChanged` arrives after restore is ready and `isApplyingSavedScale == false`, calculate `PatternPDFScalePolicy.ratio(currentScale:view.scaleFactor, fitWidthScale:baseline)` and write it only when it differs from `state.pdfWidthScaleRatio`.
4. Keep `lastScaleSignature` keyed by mode, bounds size, and page index so page changes and rotations reapply the saved ratio against the new baseline.
5. Publish the same baseline as `PatternPDFViewportState.fitWidthScaleFactor` so diagnostics and state use one definition.
6. Do not mutate the ratio from scroll callbacks, fallback timer sampling, or page restoration callbacks.

In `PatternReadingState.synchronizeVisiblePDFPage`, remove only the PDF page callback's obsolete `zoomScale = 1` assignment; retain offset reset and per-page highlight/note loading.

- [ ] **Step 4: Persist successful page transitions through the existing browsing path**

After a page transition has passed the revision/markup guards, cleared `pendingPageTransition`, and loaded the target markup, call `saveBrowsingState()`. Leave the existing Done, `.onDisappear`, and non-active scene paths intact; because `PatternBrowsingState` now includes `pdfWidthScaleRatio`, those paths save page and ratio together. If transition validation or markup save fails, restore the rollback state before any browsing save.

- [ ] **Step 5: Run adapter and reader contracts and verify GREEN**

Run: `swift test --filter 'PDFReaderScaleContractTests|PatternReaderCounterContractTests|PatternDocumentTests|PatternReaderSessionTests'`

Expected: PASS with zero failures.

- [ ] **Step 6: Run full focused regression and both platform builds**

Run: `swift test --filter 'PDFReaderScaleContractTests|PatternReaderCounterContractTests|PatternPDFViewportStateTests|PatternHighlightGeometryTests|PatternDocumentTests|PatternReaderSessionTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/knitnote-shared-width-ios CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath /tmp/knitnote-shared-width-mac CODE_SIGNING_ALLOWED=NO build`

Expected: tests and both builds exit 0.

- [ ] **Step 7: Commit the pre-thumbnail candidate**

```bash
git add KnitNote/Patterns/PDFReaderView.swift KnitNote/Patterns/PatternReaderView.swift Sources/KnitNoteCore/Patterns/PatternDocument.swift Tests/KnitNoteCoreTests/PDFReaderScaleContractTests.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m "fix: preserve pattern PDF width across pages"
```

- [ ] **Step 8: Pass the physical iPad gate**

Build and install the immutable commit on the paired iPad. With one multi-page PDF: set a non-default width in landscape, go next/previous and verify the width remains; scroll top/middle/bottom and verify both highlights stay attached; rotate portrait to landscape to portrait twice and verify the relative width remains; tap Done, reopen the same usage, and verify page and width restore. Link the same pattern to a second project, set a different width, and verify the first project's width is unchanged. Do not begin thumbnails until all checks pass.
