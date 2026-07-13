# Family Watercolor Visual System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the daughter's watercolor knitting illustration as KnitNote's light-mode brand system without reducing the clarity or reliability of core knitting workflows.

**Architecture:** Store the family artwork and an extracted Lemon asset in an asset catalog, define reusable semantic theme tokens and SwiftUI surfaces in one visual-system module, then adopt those components screen by screen. Pure palette and responsive-layout policies live in KnitNoteCore for test-first coverage; pattern content remains isolated from decorative styling.

**Tech Stack:** Swift 6, SwiftUI, UIKit/AppKit asset catalogs, Swift Testing, XcodeGen, image-generation/editing tooling, Xcode 26.

## Global Constraints

- Preserve the original woman-to-Lemon composition and never stretch the family artwork.
- Version one uses a fixed light appearance on iPhone, iPad, and Mac.
- Keep PDFs, image patterns, markup canvases, and essential pattern text free from watercolor decoration.
- Preserve all project, row, note, pattern, highlight, markup, page, and persistence behavior.
- Retain system icons, standard destructive red, at least 44-point touch targets, Dynamic Type, VoiceOver, and Reduce Motion support.
- Localize meaningful artwork descriptions in Traditional Chinese and English; hide decorative motifs from assistive technologies.
- Leave the pre-existing `KnitNote/Localization/Localizable.xcstrings` working-tree change outside unrelated commits until the localization task intentionally reconciles it.

---

### Task 1: Testable Theme and Responsive Hero Policy

**Files:**
- Create: `Sources/KnitNoteCore/Theme/WatercolorThemePolicy.swift`
- Create: `Tests/KnitNoteCoreTests/WatercolorThemePolicyTests.swift`

**Interfaces:**
- Produces: `ThemeRGB`, `WatercolorPalette`, `FamilyHeroLayout`, and `familyHeroLayout(width:isPad:)`.

- [ ] **Step 1: Write failing palette and responsive-layout tests**

```swift
import Testing
@testable import KnitNoteCore

@Test func watercolorPaletteUsesAccessibleActionInk() {
    #expect(WatercolorPalette.actionBerry.hex == 0x9A3F70)
    #expect(WatercolorPalette.ink.hex == 0x33405C)
    #expect(WatercolorPalette.softWhite.hex == 0xFFFDFB)
}

@Test func familyHeroUsesShortPhoneAndWidePadLayouts() {
    #expect(familyHeroLayout(width: 390, isPad: false) == .phone(height: 150))
    #expect(familyHeroLayout(width: 1024, isPad: true) == .wide(height: 300))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build --filter WatercolorThemePolicyTests
```

Expected: compilation fails because the theme policy types do not exist.

- [ ] **Step 3: Add the minimal pure policy**

```swift
import Foundation

public struct ThemeRGB: Equatable, Sendable {
    public let hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex }
}

public enum WatercolorPalette {
    public static let sky = ThemeRGB(0x9FC7F6)
    public static let lavender = ThemeRGB(0xB9A9E8)
    public static let berry = ThemeRGB(0xC86498)
    public static let actionBerry = ThemeRGB(0x9A3F70)
    public static let flower = ThemeRGB(0xF4D46A)
    public static let softWhite = ThemeRGB(0xFFFDFB)
    public static let ink = ThemeRGB(0x33405C)
    public static let background = ThemeRGB(0xF4F2FF)
}

public enum FamilyHeroLayout: Equatable, Sendable {
    case phone(height: Double)
    case wide(height: Double)
}

public func familyHeroLayout(width: Double, isPad: Bool) -> FamilyHeroLayout {
    isPad || width >= 700 ? .wide(height: 300) : .phone(height: 150)
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Expected: both selected tests pass.

- [ ] **Step 5: Commit the policy**

Commit the two files as `Add watercolor theme policy`.

### Task 2: Original Artwork and Lemon Assets

**Files:**
- Create: `KnitNote/Assets.xcassets/Contents.json`
- Create: `KnitNote/Assets.xcassets/FamilyKnittingHero.imageset/Contents.json`
- Create: `KnitNote/Assets.xcassets/FamilyKnittingHero.imageset/family-knitting-hero.jpg`
- Create: `KnitNote/Assets.xcassets/LemonYarn.imageset/Contents.json`
- Create: `KnitNote/Assets.xcassets/LemonYarn.imageset/lemon-yarn.png`
- Create: `KnitNote/LaunchScreen.storyboard`
- Modify: `project.yml`

**Interfaces:**
- Consumes: source artwork `/Users/longzhenzhong/Downloads/IMG_5327 2 (2).JPEG`.
- Produces: SwiftUI assets `FamilyKnittingHero` and `LemonYarn`.

- [ ] **Step 1: Inspect and preserve the source artwork**

Verify dimensions, orientation, color profile, and that the source contains the complete woman, knitted fabric, connecting yarn, Lemon, yarn ball, flowers, and sky. Do not edit the source in Downloads.

- [ ] **Step 2: Prepare the responsive hero asset**

Create an optimized sRGB JPEG that retains the complete source composition, uses the original aspect ratio, has a 2560-pixel maximum long edge, and uses high-quality compression. Do not add, remove, repaint, stretch, or crop visual content.

- [ ] **Step 3: Extract Lemon with image editing**

Use the `imagegen` image-editing skill with the original artwork as reference. Extract the original rabbit and lavender yarn ball, retain the daughter's exact brushwork and proportions, remove only the surrounding sky, and output a transparent PNG. Do not invent a new pose in version one.

- [ ] **Step 4: Add exact asset-catalog metadata**

Each imageset uses universal idiom and the single-scale filename:

```json
{
  "images": [{ "filename": "family-knitting-hero.jpg", "idiom": "universal", "scale": "1x" }],
  "info": { "author": "xcode", "version": 1 }
}
```

Use the corresponding `lemon-yarn.png` filename in the Lemon imageset. Set Lemon's `preserves-vector-representation` property to false because it is raster watercolor artwork.

- [ ] **Step 5: Ensure XcodeGen includes the catalog**

Create an iOS launch storyboard with a soft sky background and a centered `FamilyKnittingHero` image view using aspect-fit constraints to the safe container. It must contain no controls, text that imitates loaded content, animation, or timed delay. In `project.yml`, replace generated launch-screen configuration with `INFOPLIST_KEY_UILaunchStoryboardName: LaunchScreen` for the KnitNote target.

- [ ] **Step 6: Ensure XcodeGen includes the resources**

Keep `KnitNote` as the source root in `project.yml`; regenerate with:

```bash
xcodegen generate
```

Expected: `Assets.xcassets` appears in the KnitNote resources build phase and both images compile with no asset-catalog warnings.

- [ ] **Step 7: Build and visually inspect assets**

Build generic iOS and macOS targets, then display each asset in an isolated SwiftUI preview. Launch the iOS app from a terminated state and confirm the native launch screen shows the complete artwork without stretching or delay. Confirm Lemon has clean transparent edges at 1x and 2x display scales.

- [ ] **Step 8: Commit assets**

Commit only the catalog, image files, generated project changes if any, and `project.yml` as `Add family watercolor artwork assets`.

### Task 3: Reusable SwiftUI Visual System

**Files:**
- Create: `KnitNote/Theme/WatercolorTheme.swift`
- Create: `KnitNote/Theme/WatercolorSurfaces.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `KnitNote/App/RootView.swift`

**Interfaces:**
- Consumes: `WatercolorPalette` and `FamilyKnittingHero`.
- Produces: `Color(hex:)`, `WatercolorTheme`, `WatercolorBackground`, `WatercolorCard`, `YarnPrimaryButtonStyle`, and `FamilyHeroView`.

- [ ] **Step 1: Add semantic SwiftUI colors**

```swift
extension Color {
    init(theme value: ThemeRGB) {
        let red = Double((value.hex >> 16) & 0xFF) / 255
        let green = Double((value.hex >> 8) & 0xFF) / 255
        let blue = Double(value.hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue)
    }
}

enum WatercolorTheme {
    static let sky = Color(theme: WatercolorPalette.sky)
    static let lavender = Color(theme: WatercolorPalette.lavender)
    static let berry = Color(theme: WatercolorPalette.berry)
    static let actionBerry = Color(theme: WatercolorPalette.actionBerry)
    static let flower = Color(theme: WatercolorPalette.flower)
    static let softWhite = Color(theme: WatercolorPalette.softWhite)
    static let ink = Color(theme: WatercolorPalette.ink)
    static let background = Color(theme: WatercolorPalette.background)
}
```

- [ ] **Step 2: Add reusable surfaces**

`WatercolorBackground` renders a low-contrast sky-to-lavender gradient. `WatercolorCard` uses soft white at 0.9 opacity, a 24-point continuous corner radius, and a restrained lavender shadow. `YarnPrimaryButtonStyle` retains at least a 44-point height and uses action berry for readable labels. Decorative surfaces set `.accessibilityHidden(true)`.

- [ ] **Step 3: Add the responsive hero**

Use `GeometryReader` only to obtain available width, call `familyHeroLayout(width:isPad:)`, then render `Image("FamilyKnittingHero")` with `.resizable().scaledToFit()`. Place content below the image, never over it. Add `Text("art.familyHero.accessibility")` through `accessibilityLabel`.

- [ ] **Step 4: Apply the fixed light appearance and root tint**

In `KnitNoteApp`, apply `.preferredColorScheme(.light)`. In `RootView`, apply the semantic sky tint and a soft-white tab-bar background where supported, without replacing system tab icons.

- [ ] **Step 5: Build iOS and Mac**

Expected: both builds succeed and the root tabs retain all four destinations.

- [ ] **Step 6: Commit theme foundation**

Commit the four files as `Add reusable watercolor visual system`.

### Task 4: Projects Home, Cards, and Empty Lemon State

**Files:**
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Create: `KnitNote/Projects/ProjectCard.swift`
- Create: `KnitNote/Theme/LemonEmptyState.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: `FamilyHeroView`, `WatercolorBackground`, `WatercolorCard`, `LemonYarn`.
- Produces: branded Projects home and reusable `LemonEmptyState`.

- [ ] **Step 1: Preserve the complete navigation and deletion behavior**

Keep `NavigationLink(value:)`, `navigationDestination`, add-project sheet, swipe delete, confirmation dialog, and project IDs unchanged. Only replace visual containers.

- [ ] **Step 2: Build `ProjectCard`**

Render a lavender yarn placeholder, project name with Dynamic Type headline, localized current-row label plus monospaced row number, and a trailing chevron. Use `WatercolorCard`; do not claim progress percentage because the data model has no target row count.

- [ ] **Step 3: Rebuild Projects as a scrollable branded home**

Use `ScrollView` and `LazyVStack`. Place `FamilyHeroView` first and project cards below it. Keep the navigation title and add button. Sort order remains exactly `store.projects` to avoid introducing unapproved behavior.

- [ ] **Step 4: Add the first Lemon empty state**

`LemonEmptyState` renders `Image("LemonYarn")`, localized title/message, and an optional primary action. The no-project state uses existing empty copy and opens `CreateProjectView`. Hide the image from VoiceOver when the adjacent label conveys the same meaning; otherwise provide `art.lemonYarn.accessibility`.

- [ ] **Step 5: Reconcile localization deliberately**

Preserve all existing catalog entries and add only:

- `art.familyHero.accessibility`
- `art.lemonYarn.accessibility`

Traditional Chinese values describe the mother knitting beside Lemon; English values convey the same meaning. Review the full string-catalog diff so earlier unrelated formatting changes are either intentionally normalized in this commit or restored before staging.

- [ ] **Step 6: Verify phone and iPad home layouts**

Check iPhone portrait, iPad portrait, iPad landscape, and Dynamic Type accessibility size. Confirm the full composition is visible, cards remain tappable, and delete actions still work.

- [ ] **Step 7: Commit the home experience**

Commit the four files as `Style projects with family watercolor art`.

### Task 5: Project Counter and Supporting Screens

**Files:**
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Projects/AllNotesView.swift`
- Modify: `KnitNote/Projects/EditRowNoteView.swift`
- Modify: `KnitNote/Projects/CreateProjectView.swift`
- Modify: `KnitNote/Projects/RenameProjectView.swift`

**Interfaces:**
- Consumes: theme surfaces and `YarnPrimaryButtonStyle`.
- Produces: branded counter, notes, and project forms with unchanged state flow.

- [ ] **Step 1: Restyle the counter without changing actions**

Keep `completeRow`, `undoRow`, note editing, pattern opening, rename, and sheet bindings unchanged. Place the current-row number in a soft-white card, use action berry for Complete Row, and translucent capsule buttons for Undo, Notes, and Patterns. Maintain the large rounded monospaced number and a maximum readable content width on iPad/Mac.

- [ ] **Step 2: Respect Reduce Motion**

Read `@Environment(\.accessibilityReduceMotion)`. When false, the Complete Row action may briefly animate a small flower-colored glint; when true, update immediately with no decorative animation. Haptics remain iOS-only and must not block the store update.

- [ ] **Step 3: Apply form surfaces to supporting screens**

Use semantic background, card grouping, and tint only. Preserve every existing text field, save/cancel action, validation rule, note row, deletion behavior, and sheet dismissal.

- [ ] **Step 4: Build and manually exercise the project flow**

Create, rename, increment, undo, add/edit/delete a row note, open all notes, and open patterns on iPhone and iPad.

- [ ] **Step 5: Commit counter styling**

Commit the five files as `Style project counter and notes`.

### Task 6: Pattern Library and Protected Reader Chrome

**Files:**
- Modify: `KnitNote/Patterns/PatternLibraryView.swift`
- Modify: `KnitNote/Patterns/ProjectPatternsView.swift`
- Modify: `KnitNote/Patterns/PatternReaderControls.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Patterns/ChoosePatternProjectView.swift`
- Modify: `KnitNote/Patterns/EditPatternPageNoteView.swift`

**Interfaces:**
- Consumes: theme surfaces and `LemonEmptyState`.
- Produces: branded library and reader chrome while retaining neutral pattern content.

- [ ] **Step 1: Brand the library and empty state**

Replace only list surfaces and the empty presentation. Keep grouping, pattern selection, project chooser, importing, security-scoped file access, alerts, and full-screen iPad reader presentation unchanged.

- [ ] **Step 2: Restyle reader controls**

Keep page buttons, disabled conditions, page count, current row, undo, and complete callbacks unchanged. Use a soft-white translucent material container, action berry for Complete Row, lavender/sky accents for navigation, and standard disabled contrast.

- [ ] **Step 3: Protect the pattern canvas**

Keep `PDFReaderView`, `ImageReaderView`, `HighlightOverlay`, and `PatternMarkupOverlay` on neutral white/light-gray surfaces. Do not add hero, Lemon, flowers, clouds, gradient, or yarn decoration inside the ZStack. Apply theme color only to navigation and control chrome.

- [ ] **Step 4: Verify all reader state behavior**

On iPhone and iPad, exercise page navigation, reopen-page restoration, horizontal/vertical/cross highlights, markup per page, page notes, current-row synchronization, and iPad full-screen presentation.

- [ ] **Step 5: Commit reader styling**

Commit the six files as `Apply watercolor styling around pattern reader`.

### Task 7: Yarn Placeholder, Settings, and Final Accessibility Pass

**Files:**
- Modify: `KnitNote/App/RootView.swift`
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `KnitNote/Theme/LemonEmptyState.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: all visual-system components.
- Produces: complete version-one tab coverage and localized accessibility.

- [ ] **Step 1: Replace the generic yarn placeholder visual**

Keep the yarn tab nonfunctional as currently designed, but display Lemon beside an empty yarn area with existing coming-soon copy. Do not imply inventory functionality exists.

- [ ] **Step 2: Restyle Settings**

Keep language selection tags and `@Binding` unchanged. Apply pale lavender grouping, soft-white form surfaces, semantic tint, and fixed light appearance.

- [ ] **Step 3: Audit accessibility semantics**

Verify meaningful artwork descriptions are localized, decorative motifs are hidden, buttons retain labels and traits, Dynamic Type does not truncate essential values, color is not the only state indicator, and all primary actions remain at least 44 points.

- [ ] **Step 4: Commit final tab coverage**

Commit the four files as `Complete watercolor theme accessibility`.

### Task 8: Full Verification and Visual Acceptance

**Files:** All files from Tasks 1-7.

**Interfaces:**
- Consumes: completed visual-system implementation.
- Produces: verified version-one watercolor redesign.

- [ ] **Step 1: Run automated tests**

```bash
CLANG_MODULE_CACHE_PATH="$PWD/work/swift-cache" swift test --disable-sandbox --scratch-path work/.build
```

Expected: all existing tests plus the two new theme-policy tests pass.

- [ ] **Step 2: Build all supported app targets**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath work/DerivedData-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/DerivedData-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds succeed without new asset-catalog or Swift warnings.

- [ ] **Step 3: Capture simulator acceptance screens**

Capture iPhone portrait, iPad portrait, and iPad landscape for Projects with content, Projects empty state, Project counter, Pattern library, and Pattern reader. Compare the screens against the approved rules: complete hero composition, restrained motifs, readable cards, clean pattern canvas, and safe controls.

- [ ] **Step 4: Exercise functional regression checklist**

Create/rename/delete a project; increment/undo rows; create/edit/delete notes; import/open/delete a pattern; navigate pages; move every highlight mode; draw/erase/clear markup; save page notes; close/reopen and confirm state. Verify language switching still works.

- [ ] **Step 5: Inspect repository state**

Run `git diff --check`, verify no Downloads source file is modified, ensure generated previews and `.superpowers` files are excluded, and confirm only intentional project files remain changed.

- [ ] **Step 6: Commit verification adjustments if required**

If visual acceptance requires scoped fixes, commit only those fixes as `Polish family watercolor visual system`; otherwise create no empty commit.
