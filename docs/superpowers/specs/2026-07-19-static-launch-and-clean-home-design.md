# Static Launch and Clean Home Design

## Goal

Simplify KnitNote's opening experience while preserving the family artwork and the established watercolor visual identity.

## Approved Experience

- The system launch screen continues to show `FamilyKnittingHero` as a static image while iOS launches the app.
- After loading, the app displays the home interface immediately. There is no fixed waiting period.
- Remove all in-app launch animation, including camera movement, hand movement, Lemon blinking, zooming, settling, and artwork-to-home transitions.
- Remove `FamilyHeroView` from the Projects home screen so the artwork does not appear again after launch.
- Keep the existing watercolor background, berry action color, lavender surfaces, cards, buttons, and navigation styling.

## Architecture

- `RootView` becomes a direct host for the main tab interface and no longer coordinates launch phases, hero destination frames, or overlay artwork.
- `ProjectsView` removes only the hero artwork. Project creation and project list behavior remain unchanged.
- `LaunchScreen.storyboard` and the `FamilyKnittingHero` asset remain unchanged.
- Obsolete animation code may remain in the repository temporarily if removing it would create unrelated project-file risk, but it must not be instantiated or execute at runtime.

## Accessibility and Motion

- The home interface is interactive as soon as it appears.
- Reduce Motion no longer needs a separate launch path because no in-app launch motion remains.
- The static launch image remains decorative and does not add an extra accessibility stop after the app opens.

## Verification

- A source contract verifies that `RootView` does not instantiate `FamilyLaunchAnimationView` or depend on launch phases.
- A source contract verifies that `ProjectsView` does not instantiate `FamilyHeroView`.
- Existing project-list, counter, pattern, localization, and watercolor-theme tests continue to pass.
- Build the app target to confirm the simplified root hierarchy compiles.
