# iPad Maximized Pattern Reader Design

## Goal

Increase the usable pattern area on iPad while keeping all controls outside the pattern and preserving the stable PDF page behavior. iPhone and Mac retain their current layouts.

## Device Scope

The maximized layout applies only when the app runs on iPad. It is selected by the iOS device idiom, not horizontal size class, so an iPad remains in the iPad design when using Split View. iPhone and macOS continue to use the existing fixed three-region reader.

## Safe Layout

The pattern never extends behind a toolbar or control panel. The iPad reader contains three non-overlapping safe regions:

1. The existing navigation bar at the top.
2. The pattern canvas using all remaining flexible height.
3. A compact single-row control panel at the bottom.

The current always-reserved 60-point markup toolbar region is removed on iPad. This immediately adds that height to the pattern canvas when markup is off without placing content underneath controls.

## Markup Controls

On iPad, enabling markup replaces the normal navigation-bar actions with compact markup actions in the same fixed-height navigation bar. The PDF canvas therefore keeps the same size and identity when markup is toggled.

The actions remain: pen, eraser, color, line width, undo, clear page, and Done. Normal highlight, highlight mode, markup, and page-note actions return after Done. The handwriting canvas stays limited to the pattern canvas.

## Compact Bottom Controls

The iPad bottom panel uses one horizontal row:

`Previous | Page / Total | Next | Current Row | Undo Row | Complete Row`

The panel retains a material background, readable labels, disabled first/last-page states, and safe-area bottom padding. It does not overlay the pattern. iPhone and Mac retain the existing two-row `PatternReaderControls` layout.

## State and Behavior

This is a layout-only change. PDF navigation, page restoration, per-page highlights, handwriting files, page notes, and project row counts continue using the current state and persistence paths. Toggling markup must not navigate, resize the iPad pattern canvas, or recreate the PDF view.

## Verification

Automated tests will verify device-layout selection independently of UIKit. Platform builds will verify iOS/iPadOS and macOS compilation. Manual iPad verification will compare the enlarged pattern area and confirm page navigation, highlight movement, markup, notes, and row counting remain functional in portrait and landscape.
