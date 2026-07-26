# Task 8 Review Fix Round 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Task 8 build through the canonical Xcode project and close the import transaction, async UI publication, and user-facing error gaps found in review.

**Architecture:** The canonical App target explicitly owns every new Task 8 source while the Watch target owns none of them. `JSONProjectStore` uses one outer pattern-transaction scope across enqueue, processing, and publication. A pure Core coordinator owns UI operation identity and error presentation so executable tests can prove cancellation, stale-result rejection, and localized error selection.

**Tech Stack:** Swift 5, SwiftUI, Swift Testing, Xcode project format, iOS 18 Simulator, macOS 14.

## Global Constraints

- Strict RED → GREEN for every behavior change.
- Modify only the isolated worktree and canonical `KnitNote.xcodeproj`.
- Do not add Task 8 UI/Core files to the Watch target.
- Do not implement Task 9 Share Extension behavior.
- Keep English and Traditional Chinese copy exact and VoiceOver-readable.

---

### Task 1: Canonical App Target Membership

**Files:**
- Modify: `KnitNote.xcodeproj/project.pbxproj`
- Create: `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`

**Interfaces:**
- Consumes: canonical PBX groups and the `KnitNote` App Sources phase.
- Produces: App-only membership for `ChooseLibraryPatternView.swift`, `PatternImportResultView.swift`, `ProjectPatternLinkIndex.swift`, and the presentation Core source introduced below.

- [x] Write an executable PBX structure test that resolves file references and build files by target.
- [x] Run it and confirm the new Task 8 files are missing from the App target.
- [x] Add the minimal file references, group children, build files, and App Sources entries without Watch entries.
- [x] Run the membership test and `plutil -lint`/`xcodebuild -list` equivalent project validation.

### Task 2: Import Transaction Boundary

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: `activePatternTransactions` and `beginDataOperation()`.
- Produces: one non-nested transaction scope across enqueue → prepare → publish with `defer` release.

- [x] Add latch tests proving export and restore reject while project import is blocked inside inbox enqueue.
- [x] Add success, injected-failure, and cancellation tests proving the gate releases afterward.
- [x] Run the focused tests and confirm the current enqueue gap fails.
- [x] Extract one async transaction wrapper and one private non-owning inbox processor; public processing owns its own scope while enqueue calls the private processor inside its existing scope.
- [x] Run focused store tests until green.

### Task 3: UI Operation Identity and Cancellation

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/ProjectPatternImportPresentation.swift`
- Modify: `KnitNote/Patterns/PatternImportResultView.swift`
- Create: `Tests/KnitNoteCoreTests/ProjectPatternImportPresentationTests.swift`

**Interfaces:**
- Produces: `ProjectPatternImportOperationCoordinator` with begin, current-result acceptance, and cancel transitions.
- Consumes: stored SwiftUI `Task<Void, Never>?` and operation UUIDs.

- [x] Add executable tests proving a second operation invalidates the first, stale results cannot publish, and cancellation clears the current identity.
- [x] Run and confirm the missing coordinator fails compilation.
- [x] Implement the minimal pure coordinator.
- [x] Store one task in the view, cancel before replacement, cancel on toolbar/disappearance, and mutate result state only when the operation ID remains current.
- [x] Run coordinator and UI contract tests until green.

### Task 4: Localized Import Errors and Verification

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/ProjectPatternImportPresentation.swift`
- Modify: `KnitNote/Patterns/PatternImportResultView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/ProjectPatternImportPresentationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `task-8-report.md`

**Interfaces:**
- Produces: exact localization-key mapping for file validation, inbox/storage, missing project, cancellation, and fallback failures.

- [x] Add table-driven executable mapping tests and exact en/zh-Hant catalog expectations.
- [x] Run and confirm missing mapping/catalog entries fail.
- [x] Route Files picker failures, camera temporary-file failures, durable import failures, and duplicate-resolution failures through the mapper.
- [x] Use localized alert keys with a readable accessibility label.
- [x] Run focused tests, full `swift test`, real App-target iOS/macOS `xcodebuild`, JSON/Swift/project parsing, and `git diff --check`.
- [x] Update the Task 8 report and create one isolated review-fix commit.
