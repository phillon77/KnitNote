# Projects Family Painting Background Design

## Goal

Use the existing `FamilyKnittingHero` artwork, drawn by the user's daughter, as a full-screen softened background on the Projects collection screen. The artwork gives the collection a personal identity without reducing the readability or usability of project cards.

## Scope

The new background applies only to `ProjectsView`, including its populated and empty states. Project detail, pattern reader, yarn library, settings, editors, sheets, and other screens continue using the existing `WatercolorBackground`.

No new artwork, animation, user setting, or localization is required. The existing `FamilyKnittingHero` asset remains the single image source.

## Visual Design

Create a dedicated `ProjectsPaintingBackground` view with these layers, back to front:

1. The existing watercolor gradient fills the screen as a safe fallback.
2. `FamilyKnittingHero` is resizable, center-aligned, and aspect-filled across the entire screen. Cropping at the sides or top and bottom is allowed to avoid distortion and blank bands on different iPhone and iPad aspect ratios.
3. The artwork uses 30% opacity.
4. A top-to-bottom light watercolor veil overlays the artwork, using the existing theme background color at 72% opacity at the top, 50% at the center, and 32% at the bottom. This keeps the navigation title and cards clear while allowing more of the painting to appear toward the bottom.

The background is placed outside the `ScrollView` in the existing root `ZStack`, so it remains fixed while project cards scroll.

Project cards retain their current translucent white surface, spacing, shadow, navigation behavior, swipe actions, and maximum content width. The bottom tab bar remains unchanged.

## Accessibility and Interaction

The painting and veil are decorative:

- Hide them from accessibility.
- Disable hit testing so they cannot intercept scrolling, card taps, swipe actions, toolbar buttons, or the empty-state action.
- Do not add an accessibility label for the painting on this screen, because it would be repeatedly announced behind the functional collection.

Existing Dynamic Type, VoiceOver order, project-card labels, and contrast behavior remain unchanged. The light veil and existing card surfaces are responsible for keeping text legible over both dark and light regions of the artwork.

## Architecture

Keep the change isolated:

- Add `ProjectsPaintingBackground` beside the existing watercolor surfaces in `WatercolorSurfaces.swift`, or in a small dedicated theme file if source size requires it.
- Replace only the `WatercolorBackground()` instance at the root of `ProjectsView`.
- Reuse `FamilyKnittingHero`; do not duplicate the bitmap or modify the asset catalog.

This boundary allows opacity and veil tuning without affecting every screen that currently uses `WatercolorBackground`.

## Failure Behavior

If the image asset cannot render, the base watercolor gradient still fills the screen. No loading state or error message is needed because the artwork is decorative and bundled with the app.

## Verification

Automated contracts verify that:

- `ProjectsView` uses `ProjectsPaintingBackground` and no longer uses the generic background at its root.
- `ProjectsPaintingBackground` references `FamilyKnittingHero`, uses aspect fill, ignores safe areas, is accessibility-hidden, and does not accept hit testing.
- Other screens continue to use `WatercolorBackground`.

Visual verification covers:

- iPhone portrait with zero, one, and several projects.
- iPad portrait and landscape.
- Scrolling a long project list while confirming the painting stays fixed.
- Project-card readability, swipe-to-delete, the add button, empty-state action, tab bar, and VoiceOver focus order.

## Out of Scope

- Restoring the previous launch animation or placing the painting as a separate hero banner.
- Applying the painting to project detail or other tabs.
- User-adjustable background opacity or alternate artwork.
- Editing, recoloring, or generating a replacement for the daughter's original painting.
