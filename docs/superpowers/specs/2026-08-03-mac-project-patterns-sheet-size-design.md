# KnitNote Mac Project Patterns Sheet Size Design

Date: 2026-08-03
Status: Approved

## Problem

On macOS, opening 「織圖」 from a project presents `ProjectPatternsView` in a separate sheet. Unlike the main Mac window and `PatternReaderView`, this sheet has no Mac sizing policy, so macOS can open it at a very small size and make the pattern list difficult to read.

## Decision

Apply the existing Mac minimum window size to only the project-patterns sheet:

- Minimum width: 850 points.
- Minimum height: 600 points.
- The sheet remains resizable above that minimum.
- iPhone and iPad presentation remains unchanged.
- The PDF reader, PDF viewport, highlights, thumbnails, project data, and pattern links remain unchanged.

## Architecture

The size constraint belongs at the presentation boundary in `ProjectDetailView`, where `ProjectPatternsView` is opened. The Mac branch will reuse `KnitNoteMacWindowSizingPolicy.minimumWidth` and `.minimumHeight`, matching the already-approved main-window and pattern-reader rules without adding another set of constants.

This is intentionally narrower than placing a frame inside `ProjectPatternsView`, because the reported defect concerns the Mac sheet opened through 「作品 → 織圖」 and other presentation contexts should not change accidentally.

## Alternatives Considered

1. Recommended: constrain the sheet at the `ProjectDetailView` presentation point. This is the smallest change and precisely matches the affected path.
2. Constrain `ProjectPatternsView` itself. This would affect every current and future presentation and is broader than required.
3. Open a separate Mac window. This adds navigation and window-lifecycle complexity without improving the requested workflow.

## Verification

- Add a failing contract test proving the Mac project-patterns sheet uses the shared minimum width and height.
- Verify the focused test passes after the minimal implementation.
- Run the complete Swift test suite.
- Build fresh iOS and macOS targets to prove the conditional change preserves both platforms.
- Launch the exact macOS artifact and inspect 「作品 → 織圖」 at a readable size.

## Non-Goals

- No visual redesign of the pattern list.
- No change to PDF scale, scrolling, restoration, highlights, or dark appearance.
- No iPhone, iPad, Watch, pricing, release, or App Store changes.
