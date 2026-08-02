# PDF Thumbnail Asset Staleness Fix Implementation Plan

**Goal:** Prevent an unrelated store save from leaving a visible PDF page thumbnail permanently at its placeholder while still suppressing results for a deleted or revised pattern asset.

**Architecture:** Replace the page-thumbnail Store boundary's global `dataGeneration` post-await gate with asset-specific validation against the request's captured `PatternAsset`. The cell and preload identities already use asset ID, SHA/revision and page count, so the Store must apply the same invalidation rule.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI store boundary, PDF thumbnail cache.

## Global Constraints

- Unrelated archive or reading-state mutations must not invalidate a page thumbnail request when the requested asset ID, SHA-256, kind and page count are unchanged.
- Deleting the requested asset or changing its SHA-256, kind or page count while rendering is in flight must return `nil`.
- Caller cancellation must continue to cancel detached rendering and return `nil`.
- Do not change archive schema, app version/build, release metadata, PDF reader state, width, highlight, notes, markup, cache naming or cover-thumbnail behavior.
- Do not merge, push, upload or submit.

## Task 1: Align Store Publication With Asset Identity

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryModelTests.swift`

**Interfaces:**
- Consumes: the `PatternAsset` captured before detached rendering and the current `patternAssets` collection after await.
- Produces: `patternPDFPageThumbnailURL(assetID:pageIndex:)` that publishes only when the same asset identity is still current.

- [x] Write failing tests for unrelated mutation, revision change and deletion.
- [x] Run the focused tests and verify the unchanged-asset case fails under global-generation validation.
- [x] Replace only this API's global-generation check with asset-specific post-await validation.
- [x] Verify focused thumbnail tests, the full test suite, macOS build, iOS Simulator build and `git diff --check`.

