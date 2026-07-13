# Pattern Highlight Modes Design

## Goal

Extend the pattern reader from one horizontal highlight to three selectable modes: horizontal, vertical, and cross. Each imported pattern keeps its own mode and line positions.

## User Experience

- The existing highlight control continues to enable or disable highlighting.
- A highlight mode menu offers Horizontal, Vertical, and Cross.
- Horizontal mode displays one draggable 44-point-high translucent band.
- Vertical mode displays one draggable 44-point-wide translucent band.
- Cross mode displays both bands. Each band can be dragged independently.
- The default mode is Horizontal so existing patterns retain their current appearance.
- Highlight mode, horizontal position, and vertical position persist independently for every pattern.

## Data Model and Migration

- Add a string-backed `HighlightMode` enum with `horizontal`, `vertical`, and `cross` cases.
- Add `highlightMode` and `verticalHighlightPosition` to `PatternDocument` and `PatternReadingState`.
- Keep `highlightPosition` as the horizontal band's normalized vertical position for archive compatibility.
- Decode archives without the new fields as `horizontal` with `verticalHighlightPosition` equal to `0.5`.
- Increase the JSON archive version and preserve migration from every previously supported archive version.
- Clamp both normalized line positions to the inclusive range `0...1`.

## View Architecture

- `HighlightOverlay` accepts mode plus separate bindings for horizontal and vertical positions.
- The horizontal band changes only the vertical-position binding.
- The vertical band changes only the horizontal-position binding.
- In Cross mode, the bands are separate interactive layers so either can be moved without changing the other.
- Accessibility exposes localized labels for the horizontal and vertical highlight controls and supports adjustable actions in the appropriate axis.

## Localization

Add complete Traditional Chinese and English strings for Horizontal, Vertical, Cross, horizontal highlight, vertical highlight, and highlight mode. No user-facing mode name is stored in persistent data.

## Verification

- Model tests cover defaults, clamping, complete-state persistence, and migration from archives without the new fields.
- UI code compiles for generic iOS and macOS destinations.
- Existing pattern reading state, PDF page restoration, image reader behavior, and row-note tests remain passing.

## Out of Scope

- Custom highlight colors, widths, or opacity.
- More than one horizontal or vertical band.
- Automatic movement tied to row counting.
