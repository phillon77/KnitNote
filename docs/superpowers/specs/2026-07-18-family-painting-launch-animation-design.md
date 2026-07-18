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

The normal sequence lasts approximately 2.6 seconds:

1. **Painting reveal, 0.0–0.3 seconds:** The complete original painting fades in through a soft white glow.
2. **Living painting, 0.3–1.7 seconds:** The mother's hands, knitting needles, and nearby yarn make two small knitting motions. The purple yarn ball turns slightly. Lemon blinks once and gently moves an ear.
3. **Return to still art, 1.7–2.0 seconds:** All local motion eases to a stop at the exact original-painting pose.
4. **Enter the app, 2.0–2.6 seconds:** The still painting scales and moves into the existing FamilyKnittingHero position. The Projects title, project cards, add button, and navigation controls fade in around it.

There is no launch text, logo animation, music, or sound effect. The experience should feel as though the original painting quietly came alive for a moment.

## Artwork Assets

The existing `FamilyKnittingHero` image remains the authoritative full painting and the final still frame. Small transparent overlays are derived from that same source image for:

- the mother's hands, knitting needles, and nearby yarn;
- the purple yarn-ball surface;
- Lemon's eyelids;
- Lemon's ears.

The overlays may be cropped and alpha-masked, but must not redraw, regenerate, restyle, or reinterpret the family artwork. Motion amplitudes must remain small enough that the base painting and overlay edges never visibly separate.

If a clean overlay cannot be derived without changing the drawing, that particular movement is omitted. Preserving the daughter's artwork takes priority over adding motion.

## App Architecture

### LaunchExperienceCoordinator

A small state model owns the phases `revealing`, `animating`, `settling`, `enteringHome`, and `complete`. It starts only once for the lifetime of the app process and provides a single idempotent `skip()` operation. Normal completion and skip both converge through `enteringHome` so the final layout cannot diverge.

### FamilyLaunchAnimationView

This SwiftUI view renders the full painting and optional overlay layers. It receives the current phase and Reduce Motion value, but does not own application data or navigation. Missing overlays fall back to the complete still painting.

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
- If one or more overlay assets are unavailable, play the sequence with the full painting only.
- Repeated taps, phase completion callbacks, and scene changes must not run completion twice.
- Orientation or window-size changes during playback recompute the destination frame rather than preserving a stale offset.

## Testing and Acceptance

Unit tests cover phase progression, idempotent skip, cold-launch-only behavior, Reduce Motion behavior, and completion convergence.

Build and manual acceptance cover:

- iPhone and iPad in portrait and landscape;
- compact and large iPad window sizes;
- Mac window resizing;
- tap-to-skip during each phase;
- Reduce Motion enabled;
- background and foreground transitions without replay;
- missing optional overlay fallback;
- clean alignment with the Projects hero image at the end of the transition;
- no regression to projects, row counting, notes, photos, patterns, markup, localization, or Watch builds.

## Out of Scope

- Audio, music, haptics, launch text, or logo animation.
- A user-selectable animation gallery or animation settings page.
- Replaying the animation from within the app.
- AI-generated reinterpretation of the family artwork.
- Apple Watch launch animation.
