# Task 10 Main-App Inbox Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Process Share Extension inbox files serially whenever the main App launches or becomes active, with durable duplicate decisions, visible retry/discard failures, and crash-safe idempotency.

**Architecture:** An App-only Core `PatternInboxDriver` actor owns run serialization and consumes a small async `PatternInboxProcessing` protocol. `JSONProjectStore` remains the only archive mutation authority and exposes off-main inbox listing, explicit duplicate resolution, and safe discard. A `@MainActor` App processor translates driver events into a nonblocking notice, a blocking duplicate-selection sheet, or a persistent retry/discard failure.

**Tech Stack:** Swift 6, Swift Concurrency actors, SwiftUI, Swift Testing, existing `JSONProjectStore`/`PatternInboxFileService`, XcodeGen.

## Global Constraints

- Process inbox items strictly by `receivedAt`, serially, on launch and every active scene transition.
- Share Extension remains enqueue-only and never mutates the archive.
- Unique, new, and existing results resolve automatically; migrated duplicate ambiguity must remain durable until the user chooses an existing collection or explicitly creates a new collection.
- Failures must remain visible with localized retry and discard actions; no silent deletion.
- Successful archive publication precedes inbox cleanup. Cancellation, crash, relaunch, and repeated foreground events must not create duplicate collections or assets.
- Validation, hashing, copy, and inbox enumeration remain off the main actor.
- Do not add Task 11 backup format or backup UI behavior.
- Task 10 App UI must work in English and Traditional Chinese on iPhone, iPad, and macOS with readable VoiceOver labels; no Task 10 App sources belong to Watch.

---

### Task 1: Durable Store Resolution and Discard

**Files:**
- Modify: `Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift`
- Modify: `Sources/KnitNoteCore/Patterns/PatternInboxItem.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Create: `Tests/KnitNoteCoreTests/PatternInboxProcessingStoreTests.swift`

**Interfaces:**
- Produces: `PatternImportDuplicateResolution.automatic`, `.existing(UUID)`, `.createNew`
- Produces: `JSONProjectStore.pendingPatternInboxItems()`
- Produces: `JSONProjectStore.processPatternInboxItem(id:duplicateResolution:)`
- Produces: `JSONProjectStore.discardPatternInboxItem(id:)`

- [ ] Write a failing test where one migrated asset has two collection names and `.createNew` creates exactly one additional collection referencing the existing asset, preserves the friendly inbox name, and removes the inbox item.
- [ ] Write failing restart tests proving an interrupted or repeated resolution cannot create a second collection or asset.
- [ ] Write a failing discard test proving staged bytes and manifest disappear without any archive mutation and repeated discard is idempotent.
- [ ] Run `swift test --filter PatternInboxProcessingStoreTests` and confirm missing APIs fail.
- [ ] Implement explicit duplicate resolution in the existing publish transaction and implement discard as a durable manifest transition followed by best-effort cleanup.
- [ ] Implement off-main received-time inbox enumeration and rerun the focused store/fault tests.

### Task 2: Serial Actor Driver

**Files:**
- Create: `Sources/KnitNoteCore/Patterns/PatternInboxProcessing.swift`
- Create: `Tests/KnitNoteCoreTests/PatternInboxProcessorTests.swift`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`

**Interfaces:**
- Produces:

```swift
public protocol PatternInboxProcessing: Sendable {
    func pendingItems() async throws -> [PatternInboxItem]
    func process(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome
    func discard(itemID: UUID) async throws
}
```

- Produces: `PatternInboxDriver.processPending()`, `.resolve(...)`, `.retry(...)`, `.discard(...)`
- Produces: ordered `PatternInboxDriverEvent` values for created, existing, selection, failure, and discarded states.

- [ ] Write a failing controllable fake-processing test that starts two foreground runs and proves maximum concurrency and per-item processing count are both one.
- [ ] Write failing ordered tests proving processing stops on the first ambiguity or failure and never processes later items out of order.
- [ ] Write failing cancellation and retry tests proving the item remains pending after cancellation/failure and succeeds once on retry.
- [ ] Write failing relaunch/idempotency tests using real inbox/store processing.
- [ ] Run `swift test --filter PatternInboxProcessorTests` and confirm missing driver APIs fail.
- [ ] Implement the actor run gate and event mapping without swallowing errors.
- [ ] Exclude the App-only driver from Watch, regenerate the project, and prove executable source membership.

### Task 3: Main-App Processor and Persistent Decision UI

**Files:**
- Create: `KnitNote/Patterns/PatternInboxProcessor.swift`
- Create: `KnitNote/Patterns/PendingPatternSelectionView.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `KnitNote/App/RootView.swift`
- Create: `Tests/KnitNoteCoreTests/PatternInboxPresentationContractTests.swift`

**Interfaces:**
- Produces: `PatternInboxNotice`, `PendingPatternSelection`, `PatternInboxFailure`
- Consumes: `PatternInboxDriverEvent`

- [ ] Write failing App target/presentation contracts for one retained processor, initial and `.active` processing, nonblocking notice overlay, nondismissable duplicate sheet, retry/discard alert, create-new action, and accessible candidate rows.
- [ ] Run `swift test --filter PatternInboxPresentationContractTests` and confirm the App artifacts are absent.
- [ ] Implement a `JSONProjectStore` protocol adapter and `@MainActor ObservableObject` processor that owns one current task and ignores stale publications after cancellation.
- [ ] Inject the processor once in `KnitNoteApp`; start processing from `RootView.task` and each active scene transition.
- [ ] Implement the adaptive duplicate sheet and persistent localized failure actions without changing the selected tab.
- [ ] Rerun presentation, localization, and membership tests.

### Task 4: Localization and Verification

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Create: `task-10-report.md`
- Modify: this plan

**Interfaces:**
- Produces: exact English and Traditional Chinese Task 10 copy.

- [ ] Add failing exact-catalog tests for created, existing, selection, create-new, retry, discard, failure, and discarded strings.
- [ ] Add the exact two-language strings and verify VoiceOver labels expose names and actions.
- [ ] Run all focused inbox, import fault, localization, and PBX membership suites.
- [ ] Run full `swift test --quiet`.
- [ ] Run fresh canonical Share Extension, iOS App, macOS App, and Watch builds with code signing disabled.
- [ ] Verify iOS embedding, macOS/Watch isolation, plist/entitlements/PBX, catalogs, Swift parse, and `git diff --check`.
- [ ] Record all RED/GREEN evidence in `task-10-report.md`, stage only Task 10 files, and commit `feat: process shared patterns on foreground`.
