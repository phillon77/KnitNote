# Single-Page PDF Reader Design

## Goal

Eliminate ambiguous between-page reading positions by displaying exactly one PDF page at a time while retaining the fast screen-fixed highlight overlay from commit `83430b9`.

## Behavior

- PDF patterns display one complete page at a time with automatic fit-to-page scaling.
- iPhone and iPad support horizontal page swiping through PDFKit's page view controller.
- All platforms provide localized Previous Page and Next Page buttons.
- The page indicator remains visible and always represents one discrete page.
- Closing saves only the page index for PDF navigation; between-page offsets are reset to zero.
- Opening restores the saved page and complete-page layout.
- Switching pages restores fit-to-page scaling so the page cannot remain partially positioned from an earlier zoom.
- Image patterns and all highlight modes remain unchanged.

## Verification

- Core tests cover clamped discrete page navigation.
- Generic iOS and macOS builds must succeed.
- Existing reading-state, localization, pattern-import, and row-note tests must continue to pass.
