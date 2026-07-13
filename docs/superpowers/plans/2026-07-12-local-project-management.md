# Local Project Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single sample counter with persistent multi-project creation, rename, counting, sorting, and confirmed deletion on iPhone, iPad, and Mac.

**Architecture:** A SwiftData `StoredProject` model is injected through one app-level `ModelContainer`. List and detail views operate on the same model context, while validation and row-count rules remain small testable model methods; all visible copy stays in the bilingual String Catalog.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, String Catalog, XcodeGen, iOS 18+, macOS 15+.

## Global Constraints

- Store data locally only; do not enable CloudKit.
- User-entered names must never be translated or replaced during language changes.
- Trim name whitespace and reject empty names.
- Row count must never be negative.
- Update `updatedAt` after rename, increment, and undo.
- Do not connect Apple Watch to stored projects in this phase.
- English and Traditional Chinese must cover every new visible string.

---

### Task 1: Persistent Project Model

**Files:**
- Create: `KnitNote/Projects/StoredProject.swift`
- Create: `KnitNoteTests/StoredProjectTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: `StoredProject.init(name:now:)`, `rename(to:now:) throws`, `completeRow(now:)`, and `undoRow(now:)`.

- [ ] **Step 1: Add a failing test target and model tests**

Configure a `KnitNoteTests` unit-test target in `project.yml`, then test that names are trimmed, blank names throw `ProjectValidationError.emptyName`, row count never falls below zero, and every successful mutation sets the supplied `now` date.

- [ ] **Step 2: Generate the project and verify RED**

Run: `xcodegen generate && xcodebuild test -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath work/ProjectTests CODE_SIGNING_ALLOWED=NO`

Expected: FAIL because `StoredProject` and `ProjectValidationError` do not exist.

- [ ] **Step 3: Implement the minimal SwiftData model**

```swift
import Foundation
import SwiftData

enum ProjectValidationError: Error, Equatable { case emptyName }

@Model final class StoredProject {
    @Attribute(.unique) var id: UUID
    var name: String
    private(set) var currentRow: Int
    var createdAt: Date
    private(set) var updatedAt: Date

    init(name: String, now: Date = .now) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectValidationError.emptyName }
        id = UUID(); self.name = clean; currentRow = 0
        createdAt = now; updatedAt = now
    }

    func rename(to value: String, now: Date = .now) throws {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ProjectValidationError.emptyName }
        name = clean; updatedAt = now
    }

    func completeRow(now: Date = .now) { currentRow += 1; updatedAt = now }
    func undoRow(now: Date = .now) { currentRow = max(0, currentRow - 1); updatedAt = now }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run the command from Step 2. Expected: all existing and new tests pass.

### Task 2: App Container and Project List

**Files:**
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Replace: `KnitNote/Projects/ProjectsView.swift`
- Create: `KnitNote/Projects/CreateProjectView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Create: `KnitNoteTests/ProjectPersistenceTests.swift`

**Interfaces:**
- Consumes: `StoredProject`.
- Produces: one persistent app container, sorted project list, empty state, and creation sheet.

- [ ] **Step 1: Write an in-memory persistence test**

Create `ModelConfiguration(isStoredInMemoryOnly: true)`, insert two projects with different `updatedAt` values, fetch with `SortDescriptor(\.updatedAt, order: .reverse)`, and assert the recently updated project appears first after a fresh fetch.

- [ ] **Step 2: Run the test and verify RED**

Expected: FAIL because the app container/list flow is not wired.

- [ ] **Step 3: Inject the production container**

Add `.modelContainer(for: StoredProject.self)` to the `WindowGroup`. Keep failure behavior explicit by allowing SwiftData initialization to fail at launch rather than silently using volatile storage.

- [ ] **Step 4: Implement list, empty state, and create sheet**

Use `@Query(sort: \StoredProject.updatedAt, order: .reverse)` and `@Environment(\.modelContext)`. The sheet contains one text field, Cancel, and Create; Create is disabled for trimmed empty input, inserts the project, saves the context, dismisses, and navigates to detail.

- [ ] **Step 5: Add bilingual catalog entries**

Add both locales for `projects.empty.title`, `projects.empty.message`, `projects.add`, `project.name`, `project.create`, `common.cancel`, `project.rowCount`, and `error.saveFailed`.

- [ ] **Step 6: Run tests and build macOS/iOS**

Expected: tests pass; both destinations build successfully.

### Task 3: Detail Counting and Rename

**Files:**
- Create: `KnitNote/Projects/ProjectDetailView.swift`
- Create: `KnitNote/Projects/RenameProjectView.swift`
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Create: `KnitNoteTests/ProjectMutationPersistenceTests.swift`

**Interfaces:**
- Consumes: one `StoredProject` from list navigation.
- Produces: persistent increment, undo, and rename interactions.

- [ ] **Step 1: Write failing mutation-persistence tests**

Insert a project in an in-memory container, mutate it, save, create a new context, fetch by ID, and assert the new name and row count persist. Add a test proving an invalid rename preserves the prior name.

- [ ] **Step 2: Run and verify RED**

Expected: FAIL until the detail mutation/save path is implemented.

- [ ] **Step 3: Implement the detail counter**

Display name, large row count, Complete a Row, Undo, and Rename. Each successful mutation calls `modelContext.save()`; save errors set a localized alert state without destroying the current screen.

- [ ] **Step 4: Implement rename sheet**

Initialize the field with the current name, disable Save for blank input, call `rename(to:)`, save, and dismiss only after success.

- [ ] **Step 5: Add bilingual entries and verify**

Add `project.rename`, `common.save`, and localized error/alert strings in both languages. Run all tests and both platform builds.

### Task 4: Confirmed Deletion and Release Verification

**Files:**
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Create: `KnitNoteTests/ProjectDeletionTests.swift`
- Modify: `docs/localization-release-checklist.md` if present

**Interfaces:**
- Consumes: stored list projects.
- Produces: destructive action that only deletes after explicit confirmation.

- [ ] **Step 1: Write a deletion persistence test**

Insert two projects, delete one, save, fetch in a fresh context, and assert only the untouched project remains.

- [ ] **Step 2: Run and verify RED for the UI workflow**

Expected: unit deletion works only after implementing the context operation; UI inspection shows no confirmation action yet.

- [ ] **Step 3: Implement pending-delete confirmation**

Swipe/context-menu Delete assigns the selected project to `pendingDeletion`. A destructive confirmation dialog includes the exact user-entered name; only its destructive button calls `modelContext.delete`, saves, and clears the pending value. Cancel only clears the pending value.

- [ ] **Step 4: Add bilingual deletion copy**

Add both locales for `project.delete`, `project.delete.title`, `project.delete.message`, and `common.delete`.

- [ ] **Step 5: Verify catalog completeness**

Run a JSON assertion that every catalog key contains both `en` and `zh-Hant` localizations. Expected: true.

- [ ] **Step 6: Run complete verification**

Run all unit tests, then clean builds for macOS and generic iOS. Expected: zero test failures and both builds succeed. Confirm the generated iOS Info.plist still contains `UILaunchScreen`.

## Completion Boundary

This plan is complete when local multi-project management passes all acceptance checks. Apple Watch synchronization, CloudKit, photos, patterns, yarn links, archive, and deletion recovery remain outside this implementation.
