# iPad Full-Screen Pattern Reader Design

## Goal

Make the entire pattern reader fill the iPad's usable screen while preserving the established reader controls and safe areas. The PDF page itself continues to use its existing single-page fitting behavior.

## Confirmed Problem

The pattern reader is opened with SwiftUI's default sheet presentation. On iPad this becomes a centered form sheet, so the whole reader—including the PDF canvas—is constrained to a small rounded rectangle. The previous change enlarged content inside that form sheet, which did not address the presentation constraint.

## Design

- Revert the internal iPad-only compact controls and navigation-toolbar markup changes from commit `f7685b8`.
- Restore the stable markup strip and standard bottom controls on every platform.
- Present `PatternReaderView` full-screen when running on iPad.
- Keep the existing sheet presentation on iPhone and Mac.
- Apply the same iPad presentation policy from both pattern entry points: the project pattern list and the global pattern library.
- Let `PatternReaderView` continue respecting its navigation and bottom safe areas; the PDF canvas must remain between the toolbars rather than extending underneath them.

## State and Behavior

No persistence or reader-state code changes are permitted. Page number, highlights, markup, page notes, row count, and navigation must behave exactly as before. Dismissing the full-screen reader continues to use the existing Done action and save path.

## Implementation Boundary

A small reusable presentation helper selects full-screen presentation from the iPad device idiom and sheet presentation elsewhere. The helper owns only presentation choice; it does not modify reader content or stored data.

## Verification

- Unit-test the presentation policy: iPad selects full screen; non-iPad selects sheet.
- Run all Swift tests.
- Build the generic iOS and macOS targets.
- On iPad Simulator, open a pattern from both entry points and confirm the reader fills the safe screen.
- Confirm page navigation, highlight movement, markup, page notes, and row controls remain visible and functional.
- Confirm iPhone retains its current presentation.

## Exclusions

- No PDF fit-width or cropping changes.
- No redesign of the reader toolbars.
- No changes to localization content.
- No changes to project or pattern data formats.
