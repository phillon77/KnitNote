# KnitNote Mac Window Sizing Design

Date: 2026-08-02
Status: Approved

## Problem

The Mac app can restore or open its main window at an unusably small size. Physical inspection showed the entire KnitNote window at roughly 180 by 110 points, so both the pattern library and pattern reader were compressed. The PDF renderer itself was not the root cause.

## Decision

Apply Mac-only sizing policy to the main `WindowGroup`:

- Default window size: 1100 by 760 points.
- Minimum usable content size: 850 by 600 points.
- The user may still resize the window larger and use full screen.
- Existing window restoration may preserve a larger user-selected size, but it must not restore below the minimum.
- iPhone and iPad layout, presentation, and reader behavior remain unchanged.

## Architecture

The policy belongs at the Mac scene/root-window boundary rather than inside `PatternReaderView` or `PDFReaderView`. A Mac-only root sizing modifier enforces the minimum content frame, while the scene provides the initial default size. This fixes every main-screen layout that shares the window and avoids reader-specific width constants.

No project data, reader state, PDF viewport state, highlight state, or appearance preference changes are required.

## Alternatives Considered

1. Always maximize the Mac window. Rejected because it removes normal Mac window control and is unnecessary on large displays.
2. Increase only the PDF reader's frame. Rejected because the captured failure affected the entire app, including the pattern library.
3. Recommended: set a reasonable default plus a Mac-only minimum. This preserves user choice while preventing the unusable tiny state.

## Verification

- Add a platform-neutral sizing policy with tests for the approved default and minimum dimensions.
- Add an app scene contract test proving the Mac-only policy is wired at the root and does not introduce iOS sizing changes.
- Run focused tests, the full Swift suite, and clean iOS/macOS builds.
- Launch the exact Mac candidate and verify the window cannot shrink below the minimum, opens at a usable size when no larger restored size exists, and the pattern reader remains readable and resizable.

## Non-Goals

- No PDF zoom or fit-width behavior changes.
- No iPhone or iPad layout changes.
- No forced full-screen behavior.
- No release, version, pricing, or App Store changes.
