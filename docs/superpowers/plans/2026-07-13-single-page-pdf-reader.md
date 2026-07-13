# Single-Page PDF Reader Implementation Plan

**Goal:** Replace continuous PDF scrolling with discrete full-page navigation.

1. Add a tested `movePDFPage(by:pageCount:)` state operation that clamps page indexes and clears offsets.
2. Configure PDFView as `.singlePage`; enable the iOS page view controller for horizontal swipes.
3. Make representable updates navigate when the bound page index changes and reset to fit-to-page scaling.
4. Add Previous and Next controls plus English and Traditional Chinese strings.
5. Run all Swift tests and generic iOS/macOS builds, then commit the verified change.
