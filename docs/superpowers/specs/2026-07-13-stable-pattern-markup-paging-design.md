# Stable Pattern Markup Paging Design

## Goal

Make PDF page navigation reliable on iPad before, during, and after handwriting markup. Opening markup must preserve the visible page, previous and next buttons must work while drawing, and handwriting must remain independent for every page.

## Current Failure

The PDF reader, handwriting toolbar, handwriting canvas, and bottom controls currently share a layout built with conditional safe-area insets. Enabling markup changes the PDF reader's available size. PDFKit's page-view-controller integration can reset its visible page during that layout change. The handwriting canvas also occupies the reader's entire overlay area, while page buttons change shared state and wait for PDFKit to follow asynchronously.

This produces two user-visible failures:

- Previous and next page buttons do not reliably change pages in markup mode.
- Enabling markup after swiping to a later page can return the PDF to page one.

## Layout

The reader will use three explicit regions:

1. A top markup toolbar region.
2. A central reading canvas containing the PDF, highlights, and handwriting overlay.
3. A bottom control region containing page navigation and the project row counter.

The central reading canvas keeps the same identity and size when markup mode changes. The toolbar region remains structurally stable and only changes its visible content. The handwriting overlay is constrained to the central canvas and cannot receive touches intended for the top or bottom controls.

## Page Ownership

One page-navigation coordinator will own the relationship between SwiftUI state and the live PDF view.

- A PDF swipe immediately publishes the visible page to application state.
- A previous or next button sends an explicit page request to the live PDF view.
- The request is considered complete only after PDFKit reports that requested page as visible.
- Stale callbacks from the formerly visible page cannot overwrite an active request.
- Enabling or disabling markup does not create a page request and does not recreate or resize the reading canvas.

The displayed page number, persisted reading state, page note, highlight positions, and markup document all use the confirmed visible page.

## Markup Persistence

Before leaving a confirmed page, the app saves that page's markup. After the new page becomes visible, it loads only that page's markup. Page changes caused by swiping and by buttons follow the same save-and-load path.

Opening markup on page two or later must display that same page and its existing markup. Closing and reopening the reader must restore the last confirmed page.

## Error and Boundary Behaviour

- Previous is disabled on the first page.
- Next is disabled on the final page.
- Repeated taps during an in-flight transition resolve to a valid bounded target.
- A failed PDF load continues to show the existing invalid-pattern alert.
- Markup save failures continue to use the existing save-error presentation.

## Verification

Automated tests will cover the page request state machine, including stale page callbacks and confirmation of requested pages. Platform builds will verify iOS/iPadOS and macOS compilation.

Manual iPad verification must cover:

1. Swipe to page two, enable markup, and confirm page two remains visible.
2. Draw on page one, use Next, draw on page two, and use Previous.
3. Confirm page-one and page-two strokes remain independent.
4. Disable and re-enable markup without changing pages.
5. Close and reopen the pattern and confirm the last visible page and its markup return.

## Scope

This change is limited to reader layout, PDF page coordination, and page-linked markup loading. It does not change drawing tools, highlight appearance, project row counting, pattern import, or localization content.
