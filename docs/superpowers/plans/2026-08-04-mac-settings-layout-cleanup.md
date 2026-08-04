# Mac Settings Layout Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the cluttered macOS Settings `Form` with the approved centered single-column grouped-card layout while preserving every setting and the existing iOS layout.

**Architecture:** `SettingsView` selects a macOS `ScrollView` presentation or the existing iOS `Form`. Small reusable macOS section/row views provide consistent appearance, while `BackupSettingsSection` keeps ownership of all backup state and exposes a macOS row presentation without duplicating backup operations.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, string catalog localization, Xcode multi-platform targets.

## Global Constraints

- The macOS page uses one scrollable, centered column with 560-point maximum content width and 28-point outer padding.
- Categories appear in this order: General, Knitting Tools, Data, About.
- Every existing setting and action remains available on the same page.
- iPhone and iPad keep the existing Settings `Form`.
- Language, calculators, storage, backup/restore, backup history, and version/build behavior do not change.
- Traditional Chinese, English, dark mode, and VoiceOver remain supported.
- Preserve untracked `.superpowers/` and `KnitNote 5.xcodeproj/`.

---

### Task 1: Reusable macOS settings surfaces

**Files:**
- Create: `KnitNote/Settings/MacSettingsComponents.swift`
- Create: `Tests/KnitNoteCoreTests/MacSettingsComponentsContractTests.swift`

**Interfaces:**
- Produces: `MacSettingsSection<Content: View>` for titled watercolor cards and `MacSettingsRow<Content: View>` for consistent 44-point rows.
- Consumes: `WatercolorCard`, `WatercolorTheme.actionBerry`, and caller-provided SwiftUI content.

- [ ] **Step 1: Write failing source-contract tests**

Assert the new file defines `MacSettingsSection` and `MacSettingsRow`, uses `WatercolorCard`, applies a 44-point minimum row height, and keeps the section title in the action-berry color.

- [ ] **Step 2: Run the test and verify failure**

Run: `swift test --filter MacSettingsComponentsContractTests`

Expected: FAIL because the component file does not exist.

- [ ] **Step 3: Implement the two focused components**

Keep the components presentation-only. They must not read the store, mutate settings, start backup operations, or own navigation state.

- [ ] **Step 4: Run the focused test**

Run: `swift test --filter MacSettingsComponentsContractTests`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add KnitNote/Settings/MacSettingsComponents.swift Tests/KnitNoteCoreTests/MacSettingsComponentsContractTests.swift
git commit -m "feat: add Mac settings layout components"
```

### Task 2: Backup rows reusable outside Form sections

**Files:**
- Modify: `KnitNote/Settings/BackupSettingsSection.swift`
- Modify: `Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift`

**Interfaces:**
- Preserves: `BackupSettingsSection` public initializer and all existing exporter/importer/confirmation/alert behavior.
- Produces: macOS plain rows and non-macOS `Section("backup.section")` using the same export, restore, and history subviews.

- [ ] **Step 1: Write failing platform-structure tests**

Assert the source has macOS and non-macOS containers, that only the non-macOS branch wraps rows in `Section("backup.section")`, and that both branches reuse `exportButton`, `restoreButton`, and `lastSuccessfulBackupRow`.

- [ ] **Step 2: Run the test and verify failure**

Run: `swift test --filter BackupSettingsViewContractTests`

Expected: FAIL on missing shared row properties and platform branches.

- [ ] **Step 3: Extract shared row views**

Move the current two buttons and last-successful row into three `some View` properties without changing actions, disabled conditions, progress state, labels, accessibility, date formatting, or alerts.

- [ ] **Step 4: Add platform containers**

Use a divider-separated `VStack(spacing: 0)` on macOS and retain the current titled `Section` on iOS/iPadOS.

- [ ] **Step 5: Run backup tests**

Run:

```bash
swift test --filter BackupSettingsViewContractTests
swift test --filter KnitNoteBackup
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add KnitNote/Settings/BackupSettingsSection.swift Tests/KnitNoteCoreTests/BackupSettingsViewContractTests.swift
git commit -m "refactor: share backup settings rows"
```

### Task 3: Approved macOS Settings single column

**Files:**
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `KnitNote/Resources/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift`
- Modify: `Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: `MacSettingsSection`, `MacSettingsRow`, `YarnLabelStorageRow`, `BackupSettingsSection`, `GaugeCalculatorView`, `EvenStitchAdjustmentCalculatorView`, and `versionDisplay`.
- Produces: a macOS-only `macSettingsContent`; preserves the existing non-macOS `settingsForm`.

- [ ] **Step 1: Write failing macOS layout tests**

Assert `SettingsView` contains a macOS `ScrollView`, `VStack(alignment: .leading, spacing: 16)`, `.frame(maxWidth: 560)`, `.padding(28)`, and four `MacSettingsSection` calls in the approved order. Assert the macOS branch does not use `Form` and the non-macOS branch still returns `settingsForm`.

- [ ] **Step 2: Write failing localization tests**

Add `settings.general` and `settings.data` to the required English/Traditional Chinese key map with approved copy: `General`／`一般`, `Data`／`資料`.

- [ ] **Step 3: Run the focused tests and verify failure**

Run:

```bash
swift test --filter MacFormLayoutContractTests
swift test --filter MacFormLayoutSmokeTests
swift test --filter LocalizationContractTests
```

Expected: FAIL on the missing layout and localization keys.

- [ ] **Step 4: Add the two localized section titles**

Update the string catalog with English and Traditional Chinese values only; do not add new languages or change existing copy.

- [ ] **Step 5: Implement `macSettingsContent`**

Build the four cards in the approved order. Use the existing binding for language, existing navigation destinations for calculators, existing storage row and backup view, and the existing runtime `versionDisplay`.

- [ ] **Step 6: Preserve iOS Settings unchanged**

Keep the current `settingsForm` definition and route only non-macOS platforms to it. Do not move or rename existing localization keys used by iOS.

- [ ] **Step 7: Run Settings and feature tests**

Run:

```bash
swift test --filter MacFormLayoutContractTests
swift test --filter MacFormLayoutSmokeTests
swift test --filter LocalizationContractTests
swift test --filter LanguageSettingsTests
swift test --filter GaugeCalculator
swift test --filter EvenStitchAdjustment
swift test --filter YarnLabelStorage
swift test --filter BackupSettings
swift test --filter AppVersionInfo
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add KnitNote/Settings/SettingsView.swift KnitNote/Resources/Localizable.xcstrings Tests/KnitNoteCoreTests/MacFormLayoutContractTests.swift Tests/KnitNoteAppTests/MacFormLayoutSmokeTests.swift Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m "fix: simplify Mac settings layout"
```

### Task 4: Cross-platform regression verification

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: Tasks 1–3 commits.
- Produces: complete test and exact-HEAD iOS/macOS build evidence.

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

Expected: only pre-existing untracked `.superpowers/` and `KnitNote 5.xcodeproj/` remain; no whitespace errors.
