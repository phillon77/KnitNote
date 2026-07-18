# Family Painting Launch Animation Design

## Goal

Turn the daughter's family knitting painting into a short, gentle launch experience. The painting briefly comes alive, settles back into the original still artwork, then shrinks smoothly into the existing hero position on the Projects home screen.

The animation must preserve the original faces, composition, colors, and hand-drawn texture. It must not delay access to project data or make the app feel like it is playing an advertisement.

## Platforms and Playback Rules

- Play on every cold launch of the iPhone, iPad, and Mac app.
- Do not replay when the app merely returns from the background.
- Keep Apple Watch launch behavior unchanged.
- Allow a tap anywhere to skip immediately to the final transition state.
- Respect Reduce Motion. When enabled, omit all character and object motion, fade in the original painting, then reveal the home screen.
- Never block the home screen if an animation asset is missing or cannot be decoded.

## Visual Sequence

The normal sequence lasts approximately 4 seconds and uses deliberate camera
movement so the two local actions remain clearly visible on a phone screen:

1. **Hands close-up, 0.0–1.1 seconds:** The complete painting reveals while the
   camera pushes in toward the mother's hands. Her hands, knitting needles, and
   nearby yarn make two clearly visible but gentle knitting motions.
2. **First wide shot, 1.1–1.8 seconds:** The camera pulls back to the complete
   painting and briefly settles there.
3. **Lemon close-up, 1.8–2.8 seconds:** The camera pushes in toward Lemon's face,
   holds long enough to establish focus, and Lemon completes one unmistakable
   blink.
4. **Final wide shot, 2.8–3.4 seconds:** The camera pulls back to the complete
   original painting. Every local overlay returns to its exact resting pose.
5. **Enter the app, 3.4–4.0 seconds:** The still painting scales and moves into
   the existing `FamilyKnittingHero` position. The Projects title, project cards,
   add button, and navigation controls fade in around it.

There is no launch text, logo animation, music, or sound effect. The experience should feel as though the original painting quietly came alive for a moment.

## Artwork Assets

The existing `FamilyKnittingHero` image remains the authoritative full painting and the final still frame. Small transparent overlays are derived from that same source image for:

- the mother's hands, knitting needles, and nearby yarn;
- Lemon's eyelids.

The overlays may be cropped and alpha-masked, but must not redraw, regenerate,
restyle, or reinterpret the family artwork. Local movement uses feathered masks
instead of visible rectangular crops. Motion amplitudes must be large enough to
read clearly at iPhone size while remaining small enough that overlay edges do
not visibly separate from the base painting.

The approved sequence requires both the hand motion and Lemon blink. If either
cannot be derived cleanly from the source pixels, implementation stops for a
revised masking approach instead of silently omitting the requested movement.
Preserving the daughter's artwork still takes priority over adding unrelated
motion.

## App Architecture

### LaunchExperienceCoordinator

A small state model owns the phases `revealing`, `animating`, `settling`, `enteringHome`, and `complete`. It starts only once for the lifetime of the app process and provides a single idempotent `skip()` operation. Normal completion and skip both converge through `enteringHome` so the final layout cannot diverge.

### FamilyLaunchAnimationView

This SwiftUI view renders the full painting, camera framing, and local overlay
layers. A deterministic timeline supplies camera focus, zoom, hand-motion, and
blink progress values. The view receives the timeline state and Reduce Motion
value, but does not own application data or navigation.

Camera framing always transforms the complete painting around normalized hand,
Lemon, or full-painting focal points. Local overlays move inside that transformed
painting, so camera motion and character motion share one coordinate system.

### Root Integration

`RootView` and its normal project data load immediately underneath the launch layer. A geometry-aware transition calculates the painting's final frame from the same family-hero layout policy used by the Projects screen. The launch overlay is removed only after the painting reaches that target and the home controls have become visible.

The animation must not replace the iOS static launch storyboard. The storyboard remains a fast system launch surface; the SwiftUI animation begins after the app process is ready.

## Accessibility

- The launch artwork uses the existing localized family-art accessibility description.
- Decorative overlay layers are hidden from accessibility.
- A single tap skips the sequence without requiring a small target.
- Reduce Motion replaces transforms and local movement with opacity changes.
- VoiceOver focus is not exposed to the underlying home controls until the launch overlay finishes or is skipped.

## Failure Handling

- If the full painting is unavailable, skip the launch experience and show the normal Projects screen.
- If a required hand or eye layer is unavailable, bypass the local-action sequence
  and enter the Projects screen without presenting a misleading motion-only launch.
- Repeated taps, phase completion callbacks, and scene changes must not run completion twice.
- Orientation or window-size changes during playback recompute the destination frame rather than preserving a stale offset.

## Testing and Acceptance

Unit tests cover phase progression, the four-second timeline, camera focal points,
non-zero hand motion, a complete blink cycle, idempotent skip, cold-launch-only
behavior, Reduce Motion behavior, and completion convergence.

Build and manual acceptance cover:

- iPhone and iPad in portrait and landscape;
- compact and large iPad window sizes;
- Mac window resizing;
- tap-to-skip during each phase;
- Reduce Motion enabled;
- background and foreground transitions without replay;
- missing required overlay fallback directly to the Projects screen;
- clean alignment with the Projects hero image at the end of the transition;
- video or frame-sequence confirmation that the hand motion is visibly different
  between its two extrema at iPhone size;
- video or frame-sequence confirmation that Lemon's open-eye and closed-eye frames
  are visibly different during the Lemon close-up;
- clean feathered overlay edges with no rectangular crop seams during either close-up;
- no regression to projects, row counting, notes, photos, patterns, markup, localization, or Watch builds.

## Out of Scope

- Audio, music, haptics, launch text, or logo animation.
- A user-selectable animation gallery or animation settings page.
- Replaying the animation from within the app.
- AI-generated reinterpretation of the family artwork.
- Apple Watch launch animation.
