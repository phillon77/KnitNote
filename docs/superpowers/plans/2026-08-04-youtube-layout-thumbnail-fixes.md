# YouTube Layout and Thumbnail Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the macOS YouTube import sheet and reduce YouTube thumbnails in the pattern library and project-pattern lists without changing PDF or image thumbnails.

**Architecture:** Keep the YouTube coordinator and storage flow unchanged. Add one pure thumbnail-layout policy shared by both lists, then give `AddYouTubePatternView` a macOS-only `ScrollView`/single-column presentation while preserving the current iOS `Form`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Xcode multi-platform targets.

## Global Constraints

- The macOS YouTube import sheet uses a centered single column with 520-point minimum width and height.
- The macOS content maximum width is 560 points with 28 points of outer padding.
- The macOS preview is 16:9 and no wider than 320 points.
- YouTube list thumbnails are 76×43 points on all platforms.
- PDF and image list thumbnails remain 76×96 points.
- iPhone and iPad keep the existing YouTube import `Form`.
- YouTube validation, metadata, cache, storage, project-link, cancellation, and error behavior do not change.
- Do not add video downloading or embedded playback.
- Preserve untracked `.superpowers/` and `KnitNote 5.xcodeproj/`.

---

### Task 1: Shared list-thumbnail layout policy

**Files:**
- Create: `KnitNote/Patterns/PatternListThumbnailLayout.swift`
- Create: `Tests/KnitNoteCoreTests/PatternListThumbnailLayoutTests.swift`
- Modify: `KnitNote/Patterns/PatternLibraryRow.swift`
- Modify: `KnitNote/Patterns/ProjectPatternsView.swift`

**Interfaces:**
- Consumes: `PatternAsset.Kind` values `.pdf`, `.image`, and `.youtube`.
- Produces: `PatternListThumbnailLayout.size(for:) -> CGSize` and `PatternListThumbnailLayout.rowMinimumHeight(for:) -> CGFloat`.

- [ ] **Step 1: Write the failing pure-policy tests**

Create tests that assert `.youtube` returns `CGSize(width: 76, height: 43)` and row height `43`, while `.pdf` and `.image` return `CGSize(width: 76, height: 96)` and row height `96`.

- [ ] **Step 2: Run the tests and verify the policy is missing**

Run: `swift test --filter PatternListThumbnailLayoutTests`

Expected: FAIL because `PatternListThumbnailLayout` does not exist.

- [ ] **Step 3: Implement the pure policy**

Add a non-instantiable namespace with exhaustive switches over `PatternAsset.Kind`. Do not infer size from filenames or optional metadata.

- [ ] **Step 4: Apply the policy to both approved lists**

In `PatternLibraryRow`, replace the fixed 76×96 frame and 96-point row minimum with values for `asset.kind`.

In `ProjectPatternsView.projectPatternRow`, replace the fixed frame and row minimum with values for `selection.asset.kind`.

Do not change `ChooseLibraryPatternView`, `PatternImportResultView`, or `PatternDetailView`; they are outside the two approved list locations.

- [ ] **Step 5: Run focused and contract tests**

Run:

```bash
swift test --filter PatternListThumbnailLayoutTests
swift test --filter PatternLibraryViewContractTests
swift test --filter ProjectPatternsViewContractTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Patterns/PatternListThumbnailLayout.swift KnitNote/Patterns/PatternLibraryRow.swift KnitNote/Patterns/ProjectPatternsView.swift Tests/KnitNoteCoreTests/PatternListThumbnailLayoutTests.swift
git commit -m "fix: reduce YouTube list thumbnails"
```

### Task 2: macOS YouTube import presentation

**Files:**
- Modify: `KnitNote/Patterns/AddYouTubePatternView.swift`
- Modify: `Tests/KnitNoteCoreTests/AddYouTubePatternContractTests.swift`
- Modify: `Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift`

**Interfaces:**
- Consumes: the existing `YouTubePatternAddCoordinator`, `thumbnail`, `youtubeURLField`, `fallbackMessage`, and `addPattern()` behavior.
- Produces: a macOS-only `macYouTubeContent` and the existing iOS-only `youtubeForm`.

- [ ] **Step 1: Write failing layout contract tests**

Add assertions that the macOS branch contains `ScrollView`, `VStack(alignment: .leading, spacing: 20)`, `.frame(maxWidth: 560)`, `.padding(28)`, a 520/620/520 frame, and a preview constrained with `.aspectRatio(16.0 / 9.0, contentMode: .fit)` plus `.frame(maxWidth: 320)`. Assert the macOS content branch does not contain `Form`, while the non-macOS branch does.

- [ ] **Step 2: Run the layout tests and verify failure**

Run:

```bash
swift test --filter AddYouTubePatternContractTests
swift test --filter MacFormLayoutSmokeTests
```

Expected: FAIL on the missing macOS-specific structure.

- [ ] **Step 3: Split platform content without changing behavior**

Create `macYouTubeContent` under `#if os(macOS)` and `youtubeForm` under the non-macOS branch. Reuse the existing coordinator bindings, buttons, messages, and add action; do not duplicate business logic.

- [ ] **Step 4: Implement the approved macOS single column**

Place link label, URL field, read button, detail label, preview, title field, status, and error in the approved order. Use a `ScrollView`, centered 560-point content, 28-point padding, and a 520-point minimum height. Keep Cancel/Add in the navigation toolbar.

- [ ] **Step 5: Constrain the preview**

Apply the same 16:9 320-point maximum to loaded and fallback previews. Use aspect fit so the thumbnail is never cropped.

- [ ] **Step 6: Run focused YouTube and layout tests**

Run:

```bash
swift test --filter AddYouTubePattern
swift test --filter YouTubePattern
swift test --filter MacFormLayoutSmokeTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add KnitNote/Patterns/AddYouTubePatternView.swift Tests/KnitNoteCoreTests/AddYouTubePatternContractTests.swift Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift
git commit -m "fix: repair Mac YouTube import layout"
```

### Task 3: Cross-platform regression verification

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: Tasks 1–2 commits.
- Produces: verified iOS/macOS build evidence for the exact branch HEAD.

- [ ] **Step 1: Run the complete Swift test suite**

Run: `swift test`

Expected: all tests PASS.

- [ ] **Step 2: Build iOS without signing**

Run an iPhone Simulator build with a dedicated `/tmp` Derived Data directory and `CODE_SIGNING_ALLOWED=NO`.

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Build macOS without signing**

Run a macOS build with a separate `/tmp` Derived Data directory and `CODE_SIGNING_ALLOWED=NO`.

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Inspect Git state**

Run `git status --short` and `git diff --check`.

Expected: only the pre-existing untracked `.superpowers/` and `KnitNote 5.xcodeproj/` remain; no whitespace errors.

