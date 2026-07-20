# Static Launch and Clean Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the family painting on the system launch screen while removing all in-app launch animation and the repeated painting on the Projects home screen.

**Architecture:** `RootView` will directly render the existing tab interface without launch state, overlays, geometry matching, or delayed interaction. `ProjectsView` will stop instantiating `FamilyHeroView`; the watercolor theme and `LaunchScreen.storyboard` remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Xcode asset catalogs and launch storyboard.

## Global Constraints

- Keep `FamilyKnittingHero` in `LaunchScreen.storyboard` as a static launch image.
- Do not add a fixed launch delay.
- Remove the in-app launch animation and the Projects home hero image.
- Preserve all watercolor colors, surfaces, buttons, cards, and navigation styling.

---

### Task 1: Direct Root Interface

**Files:**
- Modify: `Tests/KnitNoteCoreTests/LaunchExperienceStateTests.swift`
- Modify: `KnitNote/App/RootView.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`

**Interfaces:**
- Consumes: `RootView(storedLanguage: Binding<String>)` and the existing `TabView` content.
- Produces: A `RootView` that immediately renders the tab interface without `LaunchExperienceCoordinator`.

- [ ] **Step 1: Write the failing source-contract test**

Add a test that reads `RootView.swift` and `KnitNoteApp.swift`, then expects no `FamilyLaunchAnimationView`, `LaunchExperienceCoordinator`, `launchExperience`, or `.environmentObject(launchExperience)` references.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter rootViewImmediatelyShowsHomeWithoutInAppLaunchAnimation`

Expected: FAIL because the current root still builds and injects the animation coordinator.

- [ ] **Step 3: Implement the direct root**

Make `RootView.body` return the existing `homeTabs` directly. Remove launch-related environment properties, state, overlay, geometry, availability checks, and platform image imports. Remove the launch coordinator property and injection from `KnitNoteApp`.

- [ ] **Step 4: Run the focused test**

Run: `swift test --filter rootViewImmediatelyShowsHomeWithoutInAppLaunchAnimation`

Expected: PASS.

### Task 2: Clean Projects Home

**Files:**
- Modify: `Tests/KnitNoteCoreTests/WatercolorThemePolicyTests.swift`
- Modify: `KnitNote/Projects/ProjectsView.swift`

**Interfaces:**
- Consumes: The existing Projects navigation, empty state, and list.
- Produces: A Projects home screen without `FamilyHeroView` while retaining `WatercolorBackground`.

- [ ] **Step 1: Write the failing source-contract test**

Add a test that reads `ProjectsView.swift`, expects no `FamilyHeroView()` call, and still expects `WatercolorBackground()`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter projectsHomeRemovesPaintingButKeepsWatercolorTheme`

Expected: FAIL because `ProjectsView` still instantiates `FamilyHeroView`.

- [ ] **Step 3: Remove only the home artwork**

Delete the `FamilyHeroView()` line from the Projects screen. Do not modify `WatercolorBackground`, project cards, navigation, or theme tokens.

- [ ] **Step 4: Verify tests and build**

Run:

```bash
swift test --filter rootViewImmediatelyShowsHomeWithoutInAppLaunchAnimation
swift test --filter projectsHomeRemovesPaintingButKeepsWatercolorTheme
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteStaticLaunch CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Expected: Both focused tests pass, the app target builds, and the diff check reports no whitespace errors.
