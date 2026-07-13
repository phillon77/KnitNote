# PDF Content-Anchored Highlights Implementation Plan

**Goal:** Make PDF highlights remain attached to the same PDF content across scrolling, zooming, closing, and reopening.

**Architecture:** Image patterns keep the existing SwiftUI screen overlay. PDF patterns render temporary in-memory PDF annotations anchored to a stored page and normalized page coordinates. Platform pan gestures update those document coordinates; annotations are removed from memory when the reader closes and never written to the imported PDF.

## Task 1: Persistent PDF Highlight Anchor

- Add `highlightPageIndex` to `PatternDocument` and `PatternReadingState`, defaulting old archives to the saved reading page.
- Add failing tests for defaults, clamping, migration, and reload persistence.
- Increment the archive version only if decoding compatibility requires it.

## Task 2: PDF Annotation Renderer

- Create and refresh yellow horizontal and pink vertical square annotations on the anchored page.
- Size bands to remain approximately 44 screen points at the current zoom.
- Remove prior temporary annotations before refreshing and on coordinator teardown.
- Keep the existing SwiftUI overlay only for image patterns.

## Task 3: Document-Space Dragging

- Add iOS and macOS pan recognizers that begin only when a highlight band is touched.
- Convert the gesture location from PDFView coordinates to page coordinates.
- Update page index and normalized horizontal/vertical positions as one operation.

## Task 4: Verification

- Run all Swift tests.
- Build generic iOS and macOS destinations.
- Commit the verified change independently.
