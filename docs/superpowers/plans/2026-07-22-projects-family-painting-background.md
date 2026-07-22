# Projects Family Painting Background Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display the bundled `FamilyKnittingHero` painting as a softened, full-screen, fixed background only on the Projects collection screen.

**Architecture:** Add an isolated `ProjectsPaintingBackground` theme surface that composes the existing watercolor fallback, the bundled painting, and a fixed-opacity veil. Wire only `ProjectsView` to this surface so every other screen keeps `WatercolorBackground`, with source contracts guarding scope, accessibility, and visual constants.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, XcodeGen-generated Xcode project, iOS and macOS.

## Global Constraints

- Reuse `FamilyKnittingHero`; do not duplicate or modify the bitmap asset.
- Apply the painting only to `ProjectsView`, including populated and empty states.
- Use 30% artwork opacity.
- Use a top-to-bottom veil with `WatercolorTheme.background` at 72%, 50%, and 32% opacity.
- Keep the painting fixed outside the project-list `ScrollView`.
- Preserve project-card layout, navigation, swipe actions, empty-state action, tab bar, Dynamic Type, and VoiceOver order.
- The decorative background is accessibility-hidden and accepts no hit testing.
- Project detail, pattern reader, yarn library, settings, editors, and sheets continue using `WatercolorBackground`.

---

### Task 1: Add the isolated projects painting surface

**Files:**
- Modify: `KnitNote/Theme/WatercolorSurfaces.swift:6-17`
- Modify: `Tests/KnitNoteCoreTests/WatercolorThemePolicyTests.swift:1-25`

**Interfaces:**
- Consumes: `WatercolorBackground`, `WatercolorTheme.background`, and the asset name `FamilyKnittingHero`.
- Produces: `struct ProjectsPaintingBackground: View` with no initializer arguments.

- [ ] **Step 1: Add a failing source contract for the new surface**

Append this test and helper to `WatercolorThemePolicyTests.swift`:

```swift
@Test func projectsPaintingBackgroundUsesTheApprovedArtworkAndVeil() throws {
    let source = try appSource("KnitNote/Theme/WatercolorSurfaces.swift")
    let start = try #require(source.range(of: "struct ProjectsPaintingBackground: View"))
    let end = try #require(source.range(of: "struct WatercolorCard", range: start.upperBound..<source.endIndex))
    let background = String(source[start.lowerBound..<end.lowerBound])

    #expect(background.contains("WatercolorBackground()"))
    #expect(background.contains("Image(\"FamilyKnittingHero\")"))
    #expect(background.contains(".scaledToFill()"))
    #expect(background.contains(".opacity(0.30)"))
    #expect(background.contains("WatercolorTheme.background.opacity(0.72)"))
    #expect(background.contains("WatercolorTheme.background.opacity(0.50)"))
    #expect(background.contains("WatercolorTheme.background.opacity(0.32)"))
    #expect(background.contains(".ignoresSafeArea()"))
    #expect(background.contains(".allowsHitTesting(false)"))
    #expect(background.contains(".accessibilityHidden(true)"))
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
```

Refactor the existing first test to call `appSource("KnitNote/Projects/ProjectsView.swift")` so the repository-root lookup remains defined once.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter projectsPaintingBackgroundUsesTheApprovedArtworkAndVeil
```

Expected: failure because `struct ProjectsPaintingBackground: View` does not exist.

- [ ] **Step 3: Implement the background surface**

Insert this between `WatercolorBackground` and `WatercolorCard` in `WatercolorSurfaces.swift`:

```swift
struct ProjectsPaintingBackground: View {
    var body: some View {
        ZStack {
            WatercolorBackground()

            Image("FamilyKnittingHero")
                .resizable()
                .scaledToFill()
                .opacity(0.30)

            LinearGradient(
                colors: [
                    WatercolorTheme.background.opacity(0.72),
                    WatercolorTheme.background.opacity(0.50),
                    WatercolorTheme.background.opacity(0.32)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Run focused background and palette tests**

Run:

```bash
swift test --filter projectsPaintingBackgroundUsesTheApprovedArtworkAndVeil
swift test --filter watercolorPaletteUsesAccessibleActionInk
git diff --check
```

Expected: all selected tests pass and the diff check has no output.

- [ ] **Step 5: Commit the isolated surface**

```bash
git add KnitNote/Theme/WatercolorSurfaces.swift Tests/KnitNoteCoreTests/WatercolorThemePolicyTests.swift
git commit -m "Add projects painting background surface"
```

---

### Task 2: Apply the painting only to the Projects collection

**Files:**
- Modify: `KnitNote/Projects/ProjectsView.swift:8-40`
- Modify: `Tests/KnitNoteCoreTests/WatercolorThemePolicyTests.swift:5-18`

**Interfaces:**
- Consumes: `ProjectsPaintingBackground()` from Task 1.
- Produces: a Projects collection with a fixed painting behind its existing `ScrollView`; no public API.

- [ ] **Step 1: Replace the stale home-background contract with scoped contracts**

Replace `projectsHomeRemovesPaintingButKeepsWatercolorTheme` with:

```swift
@Test func projectsHomeUsesThePaintingSurfaceWithoutRestoringTheHeroBanner() throws {
    let source = try appSource("KnitNote/Projects/ProjectsView.swift")

    #expect(!source.contains("FamilyHeroView()"))
    #expect(source.contains("ProjectsPaintingBackground()"))
    #expect(!source.contains("WatercolorBackground()"))

    let background = try #require(source.range(of: "ProjectsPaintingBackground()"))
    let scrollView = try #require(source.range(of: "ScrollView {"))
    #expect(background.lowerBound < scrollView.lowerBound)
}

@Test func otherPrimaryScreensKeepTheGenericWatercolorBackground() throws {
    let paths = [
        "KnitNote/Projects/ProjectDetailView.swift",
        "KnitNote/Patterns/PatternLibraryView.swift",
        "KnitNote/Yarn/YarnLibraryView.swift",
        "KnitNote/Settings/SettingsView.swift"
    ]

    for path in paths {
        #expect(try appSource(path).contains("WatercolorBackground()"), "Missing generic background in \(path)")
    }
}
```

- [ ] **Step 2: Run the focused contracts and verify RED**

Run:

```bash
swift test --filter projectsHomeUsesThePaintingSurfaceWithoutRestoringTheHeroBanner
```

Expected: failure because `ProjectsView` still contains `WatercolorBackground()` and does not contain `ProjectsPaintingBackground()`.

- [ ] **Step 3: Wire the new background into the existing root ZStack**

Change only the first child of the `ProjectsView` root `ZStack`:

```diff
 ZStack {
-    WatercolorBackground()
+    ProjectsPaintingBackground()
     ScrollView {
```

Do not move the background into `ScrollView` and do not change the list, cards, navigation, toolbar, sheets, or deletion dialog.

- [ ] **Step 4: Run scoped contracts and full tests**

Run:

```bash
swift test --filter projectsHomeUsesThePaintingSurfaceWithoutRestoringTheHeroBanner
swift test --filter otherPrimaryScreensKeepTheGenericWatercolorBackground
swift test
git diff --check
```

Expected: 517 tests pass with zero failures, and the diff check has no output. If the exact total changes because another test lands first, require every discovered test to pass.

- [ ] **Step 5: Commit Projects integration**

```bash
git add KnitNote/Projects/ProjectsView.swift Tests/KnitNoteCoreTests/WatercolorThemePolicyTests.swift
git commit -m "Show family painting behind projects"
```

---

### Task 3: Build and visually verify the fixed background

**Files:**
- No product source changes expected.
- Modify tests or source only if verification reveals a reproducible defect; use a failing regression test before the fix.

**Interfaces:**
- Consumes: the completed Projects collection background from Tasks 1 and 2.
- Produces: verified iPhone, iPad, and macOS builds with recorded visual acceptance.

- [ ] **Step 1: Regenerate the Xcode project and confirm no source-reference churn**

Run:

```bash
xcodegen generate
git diff -- KnitNote.xcodeproj/project.pbxproj
```

Expected: no project diff because no source file was added. If XcodeGen emits a deterministic change, inspect and commit only required generated references.

- [ ] **Step 2: Build iOS and macOS**

Run:

```bash
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteProjectsPaintingiOS build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteProjectsPaintingMac build
```

Expected: both commands exit 0.

- [ ] **Step 3: Verify iPhone portrait in Simulator**

Build, install, and launch the generated app on an iPhone simulator. Verify:

1. The painting fills the whole Projects background without distortion or blank bands.
2. The painting stays fixed while a list containing enough projects to scroll moves.
3. The navigation title, add button, project names, completion state, and cards remain readable.
4. Project navigation, swipe-to-delete, and the add-project sheet still work.
5. The empty-state title, message, Lemon artwork, and add action remain readable when no projects exist.

- [ ] **Step 4: Verify iPad portrait and landscape**

On an iPad simulator, verify the same fixed-background and readability behavior in portrait and landscape. Confirm the centered 880-point project column and bottom tab bar remain unchanged after rotation.

- [ ] **Step 5: Verify accessibility and final repository state**

Use VoiceOver or the Simulator accessibility tree to confirm the background is not focusable and the project-card order is unchanged. Then run:

```bash
swift test
git diff --check
git status --short
```

Expected: every test passes, the diff check has no output, and only intentionally committed files plus pre-existing ignored or untracked user files appear.
