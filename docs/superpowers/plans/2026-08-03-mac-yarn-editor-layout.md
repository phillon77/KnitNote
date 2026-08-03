# KnitNote Mac Yarn Editor Layout Implementation Plan

> **Execution:** Use `superpowers:subagent-driven-development`, one task at a time, with test-driven development and a fresh review after each task.

**Goal:** Replace the broken macOS yarn create/edit `Form` layouts with one centered, readable, single-column editor while preserving every iPhone/iPad workflow and all existing yarn behavior.

**Architecture:** Add a Mac-only shared field view made from a `ScrollView`, vertical stacks, labeled controls, and `WatercolorCard` sections. `CreateYarnView` and `EditYarnView` retain their existing state, toolbar, validation, save, OCR, photo, and project-link logic. iOS/iPadOS continue using the current `Form` and `YarnEditorFields`.

**Testing rule:** Layout tests must render real SwiftUI views and inspect runtime accessibility/frame behavior. Do not use source-text search or grep as a layout test.

## Global constraints

- macOS layout only; no iPhone/iPad layout or behavior changes.
- Mac content: maximum width 560 pt, outer horizontal padding 28 pt.
- Mac sheet: minimum width 520 pt, ideal width 620 pt, minimum height 560 pt, fitted presentation sizing.
- All controls remain in one column; wider windows add outer whitespace only.
- Preserve `YarnEditorDraft`, validation, persistence, OCR confirmation, photos, label photos, project links, backup, and restore behavior.
- Add exact English and Traditional Chinese strings for new section titles.
- Preserve the untracked `KnitNote 5.xcodeproj/` directory.
- Do not change version/build metadata, merge, push, upload, submit, or release.

---

## Task 1: Shared Mac fields and Create Yarn

**Files**

- Create: `KnitNote/Yarn/MacYarnEditorFields.swift`
- Create: `Tests/KnitNoteAppTests/MacYarnEditorLayoutTests.swift`
- Modify: `KnitNote/Yarn/CreateYarnView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify only to remove the unfinished prior-attempt hunks: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

### 1.1 Write failing behavioral tests

- Add exact localization assertions:
  - `yarn.section.basic`: `Basic Details` / `基本資料`
  - `yarn.section.inventory`: `Inventory` / `庫存`
  - `yarn.section.storage`: `Storage & Notes` / `收納與筆記`
- Render the real Mac create-yarn content in an `NSHostingView` attached to an off-screen `NSWindow`.
- Exercise host widths 520 pt and 620 pt.
- Locate controls by stable accessibility identifiers and assert:
  - every field has a positive frame inside the host bounds;
  - all field leading edges align within 1 pt;
  - successive fields have distinct vertical midpoints;
  - needle and hook range controls fit at the minimum width.
- Required identifiers:
  - `macYarnEditor.name`, `.brand`, `.series`, `.color`, `.colorCode`, `.dyeLot`
  - `.ballWeightGrams`, `.lengthMeters`, `.fiberContent`
  - `.needleLower`, `.needleUpper`, `.hookLower`, `.hookUpper`
  - `.remainingBalls`, `.remainingGrams`, `.storageLocation`, `.notes`
- Run focused tests and record the expected RED failure before implementation.

### 1.2 Implement the shared Mac editor

- Add `MacYarnEditorFields(draft:)` using one `VStack(alignment: .leading, spacing: 20)`.
- Use `WatercolorCard` sections in this order:
  1. basic details: name, brand, series, color, color code;
  2. label details: dye lot, ball weight, length, fiber, needle range, hook range;
  3. inventory: remaining balls and grams;
  4. storage and notes;
  5. linked projects.
- Add the accessibility identifiers listed above to the actual controls.
- Reuse existing parsing, validation, field bindings, and linked-project UI; do not duplicate domain logic.
- Add the three exact bilingual localization entries.

### 1.3 Convert Create Yarn on Mac only

- macOS content becomes `ScrollView` -> vertical content -> shared fields + existing photo section.
- Center content with `.frame(maxWidth: 560)` and 28 pt outer padding.
- Keep minimum width 520 pt, ideal width 620 pt, minimum height 560 pt, and fitted sizing.
- Keep the iPhone/iPad `Form` branch unchanged.
- Regenerate the Xcode project, run focused tests, full Swift tests, and an iOS build.
- Commit only Task 1 files with message `fix: rebuild Mac create yarn layout`.

---

## Task 2: Convert Edit Yarn without changing saved behavior

**Files**

- Modify: `KnitNote/Yarn/EditYarnView.swift`
- Modify: `Tests/KnitNoteAppTests/MacYarnEditorLayoutTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj` if needed.

### 2.1 Write a failing rendered Edit Yarn test

- Create a temporary `JSONProjectStore` and a real yarn record.
- Render the real Mac edit view at 520 x 560 pt in an off-screen window.
- Assert positive, in-bounds, vertically distinct frames for:
  - scan action;
  - shared name field;
  - linked-projects control;
  - label-photo area when present;
  - main photo control.
- Confirm the test fails on the current Mac `Form` layout before implementation.

### 2.2 Implement the Mac edit layout

- macOS content becomes one vertical `ScrollView` in this order:
  1. scan section;
  2. shared fields;
  3. label photos when present;
  4. main photo section.
- Apply the same centered 560 pt maximum width and 28 pt outer padding.
- Preserve every existing save callback, OCR candidate/confirmation boundary, installed photo, label photo, and project-link merge behavior.
- Keep iPhone/iPad `Form` unchanged.
- Run focused tests, full Swift tests, clean iOS and macOS builds.
- Commit only Task 2 files with message `fix: rebuild Mac edit yarn layout`.

---

## Task 3: Full verification and physical Mac acceptance

- Run `swift test --disable-sandbox`.
- Run clean iOS and macOS builds using `KnitNote.xcodeproj`.
- Verify the exact built Mac artifact, not an older installed app.
- Use only privacy-safe dummy yarn/photos; do not inspect or retain personal files.
- At 520 pt and 620 pt widths, verify Create and Edit:
  - one clean column with no clipping or horizontal scroll;
  - all fields, ranges, scan, photos, and linked projects remain reachable;
  - save, cancel, validation, OCR confirmation, and persistence still behave correctly;
  - English and Traditional Chinese render correctly;
  - enlarged text, Tab order, Return/Escape, and VoiceOver labels remain usable.
- Record exact commit SHA and clean/known-dirty status.
- Do not perform release actions.
