# KnitNote Smart Knitting Reminders 2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the one-reminder-per-counter workflow with a project-level reminder collection that supports multiple main-counter rules, one-row deferral, reliable Apple Watch actions, and lossless migration of every 1.5.1 reminder.

**Architecture:** `StoredProject` owns `[KnittingReminder]`; each reminder keeps a stable `counterID`, rule, bounded progress, pending occurrences, and revision. All mutations pass through `JSONProjectStore`; project and pattern screens render the same ordered pending queue. Watch snapshots carry the collection, while existing durable command preparation, deduplication, acknowledgement, and recovery boundaries carry complete/defer/skip actions.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Foundation `Codable`, WatchConnectivity, XcodeGen, String Catalogs, iOS 18, iPadOS 18, macOS 15, watchOS 11.

**Spec:** `docs/superpowers/specs/2026-08-28-smart-knitting-reminders-2-design.md`

## Global Constraints

- New reminders always bind to the normalized first counter ID; selection and renaming never move them.
- Migrate all existing first-through-sixth-counter reminders without changing their counter IDs, progress, pending state, or active state.
- Secondary-counter legacy reminders remain operable and editable, but users cannot create additional secondary reminders.
- User-entered reminder text remains verbatim; only semantic reminder kinds and system copy are localized.
- No cloud sync, account, developer server, analytics, background notification, push notification, or notification permission.
- One occurrence may be deferred exactly once and reappears on the next upward main-counter change; the second presentation offers complete or skip.
- Counter decreases and resets never reopen handled occurrences.
- All store writes, archive migration, restore, and Watch commands remain atomic and stale-safe.
- Keep all 13 shipping languages aligned across the main and Watch String Catalogs.
- Physical iPhone, iPad, Mac, and Apple Watch acceptance remain separate release gates.
- Do not change marketing version, build number, pricing, signing, App Store metadata, or release state in this implementation plan.

---

### Task 1: Define the project-level reminder domain and evaluator

**Files:**
- Create: `Sources/KnitNoteCore/Projects/KnittingReminder.swift`
- Create: `Tests/KnitNoteCoreTests/KnittingReminderTests.swift`
- Modify: `Sources/KnitNoteCore/Projects/CounterReminder.swift`

**Interfaces:**
- Consumes: legacy `CounterReminder`, `CounterReminderRule`, and `CounterReminderPending` for migration only.
- Produces: `KnittingReminderKind`, `KnittingReminderRule`, `KnittingReminderOccurrence`, `KnittingReminderProgress`, `KnittingReminderState`, `KnittingReminderDraft`, `KnittingReminder`, `KnittingReminderAction`, and `KnittingReminderEvaluator.evaluate(oldValue:newValue:reminders:)`.

- [ ] **Step 1: Add RED tests for creation, validation, and deterministic ordering**

```swift
@Test func mainCounterSupportsMultipleSingleAndRepeatingRules() throws {
    let counterID = UUID()
    let change = try #require(KnittingReminder(
        counterID: counterID,
        draft: .oneTime(kind: .changeYarn, target: 20, text: "米白色"),
        createdAt: Date(timeIntervalSince1970: 1)
    ))
    let increase = try #require(KnittingReminder(
        counterID: counterID,
        draft: .repeating(kind: .increase, firstTarget: 10, interval: 4, limit: 6, text: nil),
        createdAt: Date(timeIntervalSince1970: 2)
    ))

    let result = KnittingReminderEvaluator.evaluate(
        oldValue: 9,
        newValue: 20,
        reminders: [change, increase]
    )

    #expect(result.pending.map(\.originalTarget) == [10, 14, 18, 20])
    #expect(result.pending.last?.kind == .changeYarn)
}

@Test func invalidTargetsIntervalsAndLimitsAreRejected() {
    let id = UUID()
    #expect(KnittingReminder(counterID: id, draft: .oneTime(kind: .custom, target: -1, text: "x"), createdAt: .now) == nil)
    #expect(KnittingReminder(counterID: id, draft: .repeating(kind: .cable, firstTarget: 8, interval: 0, limit: nil, text: nil), createdAt: .now) == nil)
    #expect(KnittingReminder(counterID: id, draft: .repeating(kind: .cable, firstTarget: 8, interval: 4, limit: 0, text: nil), createdAt: .now) == nil)
}
```

- [ ] **Step 2: Run the new suite and verify RED**

Run: `swift test --disable-sandbox --filter KnittingReminderTests`

Expected: compilation fails because `KnittingReminder` and related interfaces do not exist.

- [ ] **Step 3: Implement the minimal domain types and evaluator**

```swift
public enum KnittingReminderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case increase, decrease, changeYarn, cable, buttonhole, measure, custom
}

public enum KnittingReminderRule: Codable, Hashable, Sendable {
    case oneTime(target: Int)
    case repeating(firstTarget: Int, interval: Int, limit: Int?)
}

public enum KnittingReminderOccurrencePhase: String, Codable, Hashable, Sendable {
    case initial, deferredOnce
}

public struct KnittingReminderOccurrence: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let reminderID: UUID
    public let kind: KnittingReminderKind
    public let text: String?
    public let originalTarget: Int
    public var displayAt: Int
    public var phase: KnittingReminderOccurrencePhase
}

public enum KnittingReminderAction: Sendable {
    case complete, deferOnce, skip, stop, resetLatest
}

public enum KnittingReminderDraft: Equatable, Sendable {
    case oneTime(kind: KnittingReminderKind, target: Int, text: String?)
    case repeating(
        kind: KnittingReminderKind,
        firstTarget: Int,
        interval: Int,
        limit: Int?,
        text: String?
    )
}

public enum KnittingReminderState: String, Codable, Hashable, Sendable {
    case active, completed, stopped
}

public struct KnittingReminderProgress: Codable, Hashable, Sendable {
    public private(set) var scheduledCount: Int
    public private(set) var completedCount: Int
    public private(set) var skippedCount: Int
    public private(set) var nextTarget: Int?
    public private(set) var pending: [KnittingReminderOccurrence]
    public private(set) var latestHandled: KnittingReminderOccurrence?
}

public enum KnittingReminderMutation: Equatable, Sendable {
    case trigger(through: Int)
    case complete(occurrenceID: UUID, observedRevision: UInt64)
    case deferOnce(occurrenceID: UUID, observedRevision: UInt64)
    case skip(occurrenceID: UUID, observedRevision: UInt64)
    case stop(observedRevision: UInt64)
    case resetLatest(observedRevision: UInt64)
}

public struct KnittingReminderEvaluationResult: Equatable, Sendable {
    public let reminders: [KnittingReminder]
    public let pending: [KnittingReminderOccurrence]
}

public struct KnittingReminder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let counterID: UUID
    public private(set) var kind: KnittingReminderKind
    public private(set) var text: String?
    public private(set) var rule: KnittingReminderRule
    public private(set) var progress: KnittingReminderProgress
    public private(set) var state: KnittingReminderState
    public private(set) var mutationRevision: UInt64
    public let createdAt: Date

    public init?(
        id: UUID = UUID(),
        counterID: UUID,
        draft: KnittingReminderDraft,
        createdAt: Date
    )

    public func applying(_ mutation: KnittingReminderMutation) throws -> KnittingReminder
    public func visibleOccurrences(at counterValue: Int) -> [KnittingReminderOccurrence]
}

public enum KnittingReminderEvaluator {
    public static func evaluate(
        oldValue: Int,
        newValue: Int,
        reminders: [KnittingReminder]
    ) -> KnittingReminderEvaluationResult
}
```

Implement checked arithmetic with `addingReportingOverflow` and `multipliedReportingOverflow`. Sort new occurrences by `originalTarget`, then `createdAt`, then `reminderID.uuidString`. Keep only cumulative counts and the latest handled occurrence; do not append unbounded history.

- [ ] **Step 4: Add RED tests for defer, skip, reset, decreases, overflow, and a direct 10→35 jump**

```swift
@Test func deferredOccurrenceReturnsOnceOnTheNextUpwardRow() throws {
    var reminder = try #require(KnittingReminder(
        counterID: UUID(),
        draft: .oneTime(kind: .measure, target: 20, text: nil),
        createdAt: .now
    ))
    reminder = try reminder.applying(.trigger(through: 20))
    let occurrence = try #require(reminder.progress.pending.first)
    reminder = try reminder.applying(.deferOnce(occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision))

    #expect(reminder.visibleOccurrences(at: 20).isEmpty)
    #expect(reminder.visibleOccurrences(at: 21).first?.phase == .deferredOnce)
    #expect(throws: KnittingReminderMutationError.alreadyDeferred) {
        try reminder.applying(.deferOnce(occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision))
    }
}
```

- [ ] **Step 5: Implement state transitions and make the suite GREEN**

Run: `swift test --disable-sandbox --filter KnittingReminderTests`

Expected: all `KnittingReminderTests` pass with zero failures.

- [ ] **Step 6: Run adjacent legacy reminder tests**

Run: `swift test --disable-sandbox --filter CounterReminderTests`

Expected: all legacy tests remain green; the old types still decode and migrate.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/KnitNoteCore/Projects/KnittingReminder.swift Sources/KnitNoteCore/Projects/CounterReminder.swift Tests/KnitNoteCoreTests/KnittingReminderTests.swift
git commit -m "feat: define project knitting reminders"
```

---

### Task 2: Integrate reminders into StoredProject and JSONProjectStore

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/ProjectCounter.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterTests.swift`
- Create: `Tests/KnitNoteCoreTests/KnittingReminderStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreEntitlementTests.swift`

**Interfaces:**
- Consumes: Task 1 reminder types.
- Produces: `StoredProject.knittingReminders`, `StoredProject.mainCounterID`, mutation results with ordered pending occurrences, and atomic store APIs `addKnittingReminder`, `updateKnittingReminder`, `applyKnittingReminderAction`, and `deleteKnittingReminder`.

- [ ] **Step 1: Write RED project tests for main-counter-only creation and multi-rule triggering**

```swift
@Test func newReminderRequiresTheNormalizedFirstCounter() throws {
    var project = try StoredProject(name: "外套")
    let main = project.counters[0].id
    let secondary = project.counters[1].id
    let draft = KnittingReminderDraft.oneTime(kind: .changeYarn, target: 12, text: nil)

    #expect(try project.addKnittingReminder(counterID: main, draft: draft, now: .now) != nil)
    #expect(throws: KnittingReminderMutationError.newReminderRequiresMainCounter) {
        try project.addKnittingReminder(counterID: secondary, draft: draft, now: .now)
    }
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter 'ProjectCounterTests|KnittingReminderStoreTests'`

Expected: compilation fails on the new `StoredProject` APIs.

- [ ] **Step 3: Add the collection, stable main-counter projection, and mutation APIs**

```swift
public var mainCounterID: UUID { counters[0].id }

@discardableResult
public mutating func addKnittingReminder(
    counterID: UUID,
    draft: KnittingReminderDraft,
    now: Date
) throws -> UUID {
    guard counterID == mainCounterID else {
        throw KnittingReminderMutationError.newReminderRequiresMainCounter
    }
    guard let reminder = KnittingReminder(counterID: counterID, draft: draft, createdAt: now) else {
        throw KnittingReminderMutationError.invalidDraft
    }
    knittingReminders.append(reminder)
    updatedAt = now
    return reminder.id
}
```

Move reminder evaluation to `StoredProject` after a counter value mutation. `ProjectCounter.applyValue` becomes counter-only after archive migration is complete; retain legacy decode fields until Task 3 removes dual-write behavior.

- [ ] **Step 4: Add RED store tests for atomic persistence, stale revisions, completed projects, and entitlement denial**

```swift
@Test func staleOccurrenceActionDoesNotPersistOrPublish() throws {
    let harness = try ReminderStoreHarness()
    let ids = try harness.seedTriggeredReminder()
    let before = try Data(contentsOf: harness.archiveURL)

    #expect(throws: KnittingReminderMutationError.staleRevision) {
        try harness.store.applyKnittingReminderAction(
            projectID: ids.project,
            reminderID: ids.reminder,
            occurrenceID: ids.occurrence,
            observedRevision: 0,
            action: .complete
        )
    }

    #expect(try Data(contentsOf: harness.archiveURL) == before)
}
```

- [ ] **Step 5: Implement JSONProjectStore authorization, staging, persistence, and publication**

Every API must call `requireAccess(.changeCounter)`, mutate a staged project array, persist once, then publish. Use `reminderID + occurrenceID + observedRevision`; never accept a row number as identity.

```swift
public func addKnittingReminder(
    projectID: UUID,
    draft: KnittingReminderDraft,
    now: Date = .now
) throws -> UUID

public func updateKnittingReminder(
    projectID: UUID,
    reminderID: UUID,
    observedRevision: UInt64,
    draft: KnittingReminderDraft,
    now: Date = .now
) throws

public func applyKnittingReminderAction(
    projectID: UUID,
    reminderID: UUID,
    occurrenceID: UUID?,
    observedRevision: UInt64,
    action: KnittingReminderAction,
    now: Date = .now
) throws

public func deleteKnittingReminder(
    projectID: UUID,
    reminderID: UUID,
    observedRevision: UInt64
) throws
```

- [ ] **Step 6: Run focused suites GREEN**

Run: `swift test --disable-sandbox --filter 'ProjectCounterTests|KnittingReminderStoreTests|JSONProjectStoreEntitlementTests'`

Expected: all selected tests pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/KnitNoteCore/Projects/StoredProject.swift Sources/KnitNoteCore/Projects/ProjectCounter.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/ProjectCounterTests.swift Tests/KnitNoteCoreTests/KnittingReminderStoreTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreEntitlementTests.swift
git commit -m "feat: persist project reminder collections"
```

---

### Task 3: Migrate archive version 13 and preserve backups atomically

**Files:**
- Create: `Sources/KnitNoteCore/Projects/KnittingReminderMigrator.swift`
- Modify: `Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- Create: `Tests/KnitNoteCoreTests/KnittingReminderMigrationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: legacy counter reminders and Task 2 project collection.
- Produces: archive version `14`, `ProjectArchive.knittingRemindersIntroducedVersion == 14`, and one migration path shared by startup load and backup restore.

- [ ] **Step 1: Write RED migration tests covering all six counters and exact legacy progress**

```swift
@Test func version13MigratesEveryCounterReminderWithoutRebinding() throws {
    let legacy = try LegacyReminderArchiveFixture.sixCountersWithReminders()
    let migrated = try KnittingReminderMigrator.migrate(legacy)
    let project = try #require(migrated.projects.first)

    #expect(migrated.version == 14)
    #expect(project.knittingReminders.count == 6)
    #expect(project.knittingReminders.map(\.counterID) == project.counters.map(\.id))
    #expect(project.counters.allSatisfy { $0.reminder == nil })
}
```

Also assert exact legacy `id`, `anchorValue`, `message`, `acknowledgedCount`, `nextTarget`, pending range, `isActive`, and `mutationRevision` mapping.

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter KnittingReminderMigrationTests`

Expected: fails because version 14 and the migrator do not exist.

- [ ] **Step 3: Implement one validated migration function and bump the schema**

```swift
extension ProjectArchive {
    public static let currentVersion = 14
    public static let knittingRemindersIntroducedVersion = 14
}

public enum KnittingReminderMigrator {
    public static func migrate(_ archive: ProjectArchive) throws -> ProjectArchive {
        guard archive.version < ProjectArchive.knittingRemindersIntroducedVersion else {
            return archive
        }
        // Build and validate every converted project before returning version 14.
    }
}
```

Do not use `try?`, drop invalid reminders, or write a partially migrated archive. Derive the first repeating target with checked addition.

- [ ] **Step 4: Add RED backup tests for old restore, corrupt reference rollback, unknown version, and round trip**

```swift
@Test func corruptLegacyReminderRestoreLeavesLiveArchiveUnchanged() throws {
    let fixture = try BackupFixture.liveCurrentData()
    let before = try Data(contentsOf: fixture.liveArchiveURL)
    let package = try fixture.version13BackupWithBrokenReminderCounterReference()

    #expect(throws: KnitNoteBackupError.invalidArchive) {
        try fixture.service.restore(package)
    }
    #expect(try Data(contentsOf: fixture.liveArchiveURL) == before)
}
```

- [ ] **Step 5: Route startup and restore through the same migrator; keep manifest summary unchanged**

Update archive validation gates to accept versions 1...14. The backup manifest format follows the existing archive-format evolution but gains no reminder count field.

- [ ] **Step 6: Run migration, backup, and release contract suites GREEN**

Run: `swift test --disable-sandbox --filter 'KnittingReminderMigrationTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'`

Expected: all selected suites pass and static schema checks expect exactly `14`.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/KnitNoteCore/Projects/KnittingReminderMigrator.swift Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift Tests/KnitNoteCoreTests/KnittingReminderMigrationTests.swift Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "feat: migrate legacy counter reminders"
```

---

### Task 4: Build the reminder list and editor

**Files:**
- Create: `KnitNote/Projects/KnittingReminderListView.swift`
- Create: `KnitNote/Projects/KnittingReminderEditorView.swift`
- Create: `KnitNote/Projects/KnittingReminderSummary.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `KnitNote/Projects/CounterManagerView.swift`
- Modify: `KnitNote/Projects/CounterReminderEditor.swift`
- Create: `Tests/KnitNoteCoreTests/KnittingReminderViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes: Task 2 store APIs and project reminder collection.
- Produces: `KnittingReminderListView(projectID:)`, `KnittingReminderEditorView(projectID:reminderID:)`, and locale-aware `KnittingReminderSummary`.

- [ ] **Step 1: Write RED source-contract tests for the two entry points and main-only add flow**

```swift
@Test func projectAndPatternOpenTheSameReminderList() throws {
    let detail = try sourceFile("KnitNote/Projects/ProjectDetailView.swift")
    let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
    #expect(detail.contains("KnittingReminderListView(projectID: projectID)"))
    #expect(reader.contains("KnittingReminderListView(projectID: projectID)"))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter 'KnittingReminderViewContractTests|ProjectDetailLayoutContractTests|PatternReaderCounterContractTests'`

Expected: missing view and entry-point assertions fail.

- [ ] **Step 3: Implement the list projection and editor draft validation**

The list has active and ended sections, sorts by next target/creation/ID, labels migrated secondary reminders with their counter display name, and always passes `project.mainCounterID` for new items.

```swift
NavigationLink {
    KnittingReminderListView(projectID: projectID)
} label: {
    Label("knittingReminder.list.title", systemImage: "bell.badge")
    Spacer()
    Text(project.activeKnittingReminderCount, format: .number)
}
```

The editor exposes kind, optional text, one-time/repeating mode, first target, interval, and finite-limit toggle. A `KnittingReminderDraft` is created only when all integer fields parse and validate.

- [ ] **Step 4: Replace legacy creation UI without removing secondary legacy edit access**

`CounterManagerView` no longer creates reminders. If the selected secondary counter has a migrated legacy reminder, show a link to that reminder's editor; do not offer an add button there. Remove the old `CounterReminderEditor` only after all production references and source contracts move to the new views.

- [ ] **Step 5: Run view contracts and a compile build**

Run: `swift test --disable-sandbox --filter 'KnittingReminderViewContractTests|ProjectDetailLayoutContractTests|PatternReaderCounterContractTests'`

Run: `xcodegen generate`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: tests and unsigned simulator build pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add KnitNote/Projects/KnittingReminderListView.swift KnitNote/Projects/KnittingReminderEditorView.swift KnitNote/Projects/KnittingReminderSummary.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Patterns/PatternReaderView.swift KnitNote/Projects/CounterManagerView.swift KnitNote/Projects/CounterReminderEditor.swift Tests/KnitNoteCoreTests/KnittingReminderViewContractTests.swift Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add smart reminder management"
```

---

### Task 5: Present the ordered queue and one-time haptic feedback

**Files:**
- Create: `KnitNote/Projects/KnittingReminderQueueCard.swift`
- Create: `KnitNote/Projects/KnittingReminderPresentationCoordinator.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Delete: `KnitNote/Patterns/CounterReminderCard.swift`
- Create: `Tests/KnitNoteCoreTests/KnittingReminderPresentationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingReminderViewContractTests.swift`

**Interfaces:**
- Consumes: ordered visible occurrences and Task 2 action APIs.
- Produces: `KnittingReminderPresentationCoordinator.update(project:)`, `current`, `markHapticPresented(occurrenceID:)`, and one shared `KnittingReminderQueueCard`.

- [ ] **Step 1: Write RED tests for queue stability and haptic deduplication**

```swift
@Test func rerenderAndNavigationDoNotRepeatTheInitialHaptic() {
    var coordinator = KnittingReminderPresentationCoordinator()
    let occurrence = ReminderFixture.pendingOccurrence()
    #expect(coordinator.shouldPlayHaptic(for: occurrence))
    coordinator.markHapticPresented(occurrenceID: occurrence.id)
    #expect(!coordinator.shouldPlayHaptic(for: occurrence))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter KnittingReminderPresentationTests`

Expected: presentation coordinator is missing.

- [ ] **Step 3: Implement pure queue projection and occurrence-ID haptic ledger**

Keep the coordinator independent from SwiftUI. It receives persisted occurrences, exposes one current item and total count, and stores only the bounded set of currently pending IDs already haptically presented.

- [ ] **Step 4: Implement the adaptive card and actions**

Initial phase buttons are Complete and Remind Next Row. Deferred phase buttons are Complete and Skip This Time. Put Stop Rule in the overflow menu. Use `sensoryFeedback` or the existing platform feedback abstraction only when the coordinator reports a new occurrence; unsupported platforms do nothing.

- [ ] **Step 5: Add source-contract assertions for one card, 44×44 controls, vertical large-type layout, and no local data mutation**

Run: `swift test --disable-sandbox --filter 'KnittingReminderPresentationTests|KnittingReminderViewContractTests|ProjectCounterViewContractTests'`

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 5**

```bash
git add KnitNote/Projects/KnittingReminderQueueCard.swift KnitNote/Projects/KnittingReminderPresentationCoordinator.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Patterns/PatternReaderView.swift KnitNote/Patterns/CounterReminderCard.swift Tests/KnitNoteCoreTests/KnittingReminderPresentationTests.swift Tests/KnitNoteCoreTests/KnittingReminderViewContractTests.swift
git commit -m "feat: present smart reminder queue"
```

---

### Task 6: Upgrade Watch snapshots and optimistic projections

**Files:**
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchOptimisticState.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchReliableSnapshotFingerprint.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchSyncModelsTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchOptimisticStateTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchReliableSnapshotFingerprintTests.swift`

**Interfaces:**
- Consumes: project reminder collection and occurrence IDs.
- Produces: snapshot schema `4`, `WatchKnittingReminderSnapshot`, `WatchKnittingReminderOccurrenceSnapshot`, and command schema `3` with occurrence/revision payload.

- [ ] **Step 1: Write RED codec and validation tests**

```swift
@Test func watchSnapshotCarriesAnOrderedReminderQueue() throws {
    let snapshot = try WatchFixture.projectWithThreePendingReminders()
    #expect(snapshot.knittingReminders.flatMap(\.pending).map(\.originalTarget) == [12, 12, 16])
    #expect(WatchSyncSnapshot.currentSchemaVersion == 4)
    #expect(WatchCounterCommand.currentSchemaVersion == 3)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter 'WatchSyncModelsTests|WatchOptimisticStateTests|WatchReliableSnapshotFingerprintTests'`

Expected: schema and snapshot shape assertions fail.

- [ ] **Step 3: Define strict snapshot and command payloads**

```swift
public enum WatchCounterOperation: String, Codable, Equatable, Sendable {
    case increment, decrement, reset
    case completeReminder, deferReminderOnce, skipReminder
}

public struct WatchReminderActionPayload: Codable, Equatable, Sendable {
    public let reminderID: UUID
    public let occurrenceID: UUID
    public let observedRevision: UInt64
}
```

Counter operations require no reminder payload; reminder operations require exactly one valid payload. Decode rejects all other combinations.

- [ ] **Step 4: Update builder, optimistic state, and fingerprint**

Project all reminders, including migrated secondary reminders, in deterministic order. Optimistic complete/defer/skip mirrors Core semantics without inventing authoritative IDs or revisions. Fingerprints include every persisted reminder field required to refresh stale Watch state.

- [ ] **Step 5: Run Watch model suites GREEN**

Run: `swift test --disable-sandbox --filter 'WatchSyncModelsTests|WatchOptimisticStateTests|WatchReliableSnapshotFingerprintTests'`

Expected: all pass.

- [ ] **Step 6: Commit Task 6**

```bash
git add Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift Sources/KnitNoteCore/WatchSync/WatchOptimisticState.swift Sources/KnitNoteCore/WatchSync/WatchReliableSnapshotFingerprint.swift Tests/KnitNoteCoreTests/WatchSyncModelsTests.swift Tests/KnitNoteCoreTests/WatchOptimisticStateTests.swift Tests/KnitNoteCoreTests/WatchReliableSnapshotFingerprintTests.swift
git commit -m "feat: sync reminder collections to watch"
```

---

### Task 7: Apply Watch reminder commands durably and stale-safely

**Files:**
- Modify: `Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSyncCache.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchSyncPersistenceTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift`

**Interfaces:**
- Consumes: Task 6 command payload and Task 2 store action API.
- Produces: exactly-once complete/defer/skip application with `.reminderMismatch` for stale/deleted/replaced occurrences.

- [ ] **Step 1: Write RED durability tests for offline order, duplicate delivery, stale revision, and mixed counter/reminder commands**

```swift
@Test func duplicateDeferredCommandAppliesExactlyOnce() throws {
    let harness = try DurableWatchHarness.triggeredReminder()
    let command = try harness.deferCommand()
    let first = try harness.applyDurably(command)
    let second = try harness.applyDurably(command)
    #expect(first.rejection == nil)
    #expect(second == first)
    #expect(harness.reload().pendingOccurrence.phase == .deferredOnce)
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|PhoneWatchSyncSourceContractTests'`

Expected: new operations are unhandled.

- [ ] **Step 3: Extend prepare/apply/acknowledge without bypassing the durable ledger**

Validate project, counter, reminder, occurrence, and revision before staging. Persist the archive before acknowledgement. On mismatch, persist no project mutation, record the rejection exactly once, and return a fresh authoritative snapshot.

- [ ] **Step 4: Prove one rejected reminder command does not roll back adjacent successful counter commands**

Add a queue test with increment → stale reminder action → increment; expected final counter is +2 and only the middle acknowledgement is rejected.

- [ ] **Step 5: Run persistence suites GREEN**

Run: `swift test --disable-sandbox --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|PhoneWatchSyncSourceContractTests'`

Expected: all selected tests pass.

- [ ] **Step 6: Commit Task 7**

```bash
git add Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift Sources/KnitNoteCore/WatchSync/WatchSyncCache.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift Tests/KnitNoteCoreTests/WatchSyncPersistenceTests.swift Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift
git commit -m "feat: apply watch reminder actions durably"
```

---

### Task 8: Add the Apple Watch reminder queue interface

**Files:**
- Create: `KnitNoteWatch/KnittingReminderQueueView.swift`
- Modify: `KnitNoteWatch/ProjectCountersView.swift`
- Modify: `KnitNoteWatch/Sync/WatchSyncCoordinator.swift`
- Modify: `KnitNoteWatch/WatchStoreScreenshotMode.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchConnectivityAdapterSourceContractTests.swift`

**Interfaces:**
- Consumes: Task 6 snapshots and Task 7 durable commands.
- Produces: Watch complete/defer/skip controls and one-item-at-a-time queue UI.

- [ ] **Step 1: Write RED source contracts for queue count, phase-specific buttons, no editing, and 44-point controls**

```swift
@Test func watchReminderQueueOffersOnlyPhaseAppropriateActions() throws {
    let source = try sourceFile("KnitNoteWatch/KnittingReminderQueueView.swift")
    #expect(source.contains("deferReminderOnce"))
    #expect(source.contains("skipReminder"))
    #expect(!source.contains("TextField("))
    #expect(!source.contains("addKnittingReminder"))
}
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter 'WatchCounterViewContractTests|WatchConnectivityAdapterSourceContractTests'`

Expected: missing Watch view assertions fail.

- [ ] **Step 3: Implement Watch queue and coordinator entry points**

Display kind, custom text, original target, and `currentIndex/totalCount`. Initial occurrences call `completeReminder` or `deferReminderOnce`; deferred occurrences call `completeReminder` or `skipReminder`. Trigger one Watch haptic per newly visible occurrence ID.

- [ ] **Step 4: Update deterministic screenshot fixtures and compile Watch**

Run: `xcodegen generate`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: Watch build passes and the fixture contains both initial and deferred examples.

- [ ] **Step 5: Run Watch source contracts GREEN**

Run: `swift test --disable-sandbox --filter 'WatchCounterViewContractTests|WatchConnectivityAdapterSourceContractTests|WatchPackagingContractTests'`

Expected: all pass.

- [ ] **Step 6: Commit Task 8**

```bash
git add KnitNoteWatch/KnittingReminderQueueView.swift KnitNoteWatch/ProjectCountersView.swift KnitNoteWatch/Sync/WatchSyncCoordinator.swift KnitNoteWatch/WatchStoreScreenshotMode.swift Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift Tests/KnitNoteCoreTests/WatchConnectivityAdapterSourceContractTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: handle smart reminders on watch"
```

---

### Task 9: Complete localization, accessibility, and platform contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNoteWatch/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingReminderViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`

**Interfaces:**
- Consumes: all user-visible semantic kinds, summaries, errors, statuses, and actions from Tasks 4, 5, and 8.
- Produces: complete 13-language key domains and accessibility/keyboard guarantees.

- [ ] **Step 1: Add RED localization contracts with the exact required key set**

Require keys for seven kinds, list/editor titles, one-time/repeating summaries, active/ended states, complete/defer/skip/stop/delete/reset actions, stale/invalid errors, queue position, secondary-counter label, and confirmation copy in both catalogs where visible.

```swift
let requiredMainKeys: Set<String> = [
    "knittingReminder.kind.increase",
    "knittingReminder.kind.decrease",
    "knittingReminder.kind.changeYarn",
    "knittingReminder.action.deferOnce",
    "knittingReminder.action.skip",
    "knittingReminder.queue.position"
]
```

- [ ] **Step 2: Run RED**

Run: `swift test --disable-sandbox --filter 'LocalizationContractTests|RuntimeLocalizationBehaviorTests'`

Expected: missing key and language assertions fail.

- [ ] **Step 3: Add reviewed translations and locale-aware formatting**

Populate en, zh-Hant, zh-Hans, de, fr, ja, nb, sv, fi, da, ko, el, and nl. Keep custom text verbatim. Use `LocaleAwareText` or `String(localized:locale:)` at render time; never cache translated kind names in the archive.

- [ ] **Step 4: Add and satisfy accessibility and keyboard contracts**

Verify VoiceOver combines kind, custom text, target, phase, and queue position; buttons expose hints; large type switches actions vertically; controls are at least 44×44; Mac supports Tab/Shift-Tab, Return, Escape, and visible focus; color is not the sole state signal.

- [ ] **Step 5: Run localization and UI contracts GREEN**

Run: `swift test --disable-sandbox --filter 'LocalizationContractTests|RuntimeLocalizationBehaviorTests|KnittingReminderViewContractTests|WatchCounterViewContractTests|ProjectCounterViewContractTests'`

Expected: all selected suites pass.

- [ ] **Step 6: Commit Task 9**

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNoteWatch/Localizable.xcstrings Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift Tests/KnitNoteCoreTests/KnittingReminderViewContractTests.swift Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift
git commit -m "feat: localize smart reminder workflow"
```

---

### Task 10: Run complete regression, build, and acceptance preparation

**Files:**
- Create: `AppStore/Verification/SmartKnittingReminders2Verification.md`
- Modify only if a verified contract requires it: `AppStore/Verification/release_audit.sh`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: reproducible automated evidence and an explicit physical-device checklist; no release or submission action.

- [ ] **Step 1: Run formatting and generated-project checks**

Run: `git diff --check`

Run: `xcodegen generate`

Run: `git diff --exit-code -- KnitNote.xcodeproj/project.pbxproj`

Expected: all commands exit 0 after the generated project is intentionally committed by Tasks 4/8.

- [ ] **Step 2: Run the full Swift package suite once and retain the log**

Run: `swift test --disable-sandbox 2>&1 | tee /tmp/KnitNoteSmartReminders2-full-swift-test.log`

Expected: zero failures; record the exact test/suite counts, duration, byte count, and SHA-256 in the verification file.

- [ ] **Step 3: Run fresh unsigned iOS, macOS, and Watch builds**

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteSmartReminders2-iOS CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteSmartReminders2-macOS CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNoteSmartReminders2-Watch CODE_SIGNING_ALLOWED=NO build`

Expected: each exits 0 with `** BUILD SUCCEEDED **`; record log hashes separately.

- [ ] **Step 4: Run static release and privacy audits without changing version/build**

Run: `bash AppStore/Verification/release_audit.sh --static-only`

Expected: metadata, commercial release, privacy, localization, schema, signing-source, and static audit pass markers. Do not create archives, export packages, upload, submit, or publish.

- [ ] **Step 5: Write the verification record with explicit pending manual gates**

Document source SHA, branch, unchanged `1.5.1 (11)` development identity, exact automated commands/results, archive migration fixture coverage, and these unclaimed manual checks:

```markdown
- [ ] iPhone: multi-rule creation, same-row queue, defer/skip, decrement, relaunch
- [ ] iPad: adaptive layouts and pattern-reader shortcut
- [ ] Mac: Tab/Shift-Tab, Return, Escape, focus, persistence
- [ ] Apple Watch: online/offline queue, reconnect, haptic, stale refresh
- [ ] Overwrite install: six legacy reminders and unrelated project data retained
```

- [ ] **Step 6: Run final document and repository verification**

Run: `git diff --check`

Run: `rg -n 'T[B]D|T[O]DO|F[I]XME' AppStore/Verification/SmartKnittingReminders2Verification.md`

Expected: `git diff --check` is silent; `rg` returns no matches.

- [ ] **Step 7: Commit Task 10**

```bash
git add AppStore/Verification/SmartKnittingReminders2Verification.md AppStore/Verification/release_audit.sh
git commit -m "test: verify smart knitting reminders 2.0"
```

## Execution Review Gates

After every task:

1. Review the task against this plan and the approved spec.
2. Review code quality, data safety, localization boundaries, and test evidence.
3. Fix findings on the same task branch before starting the next task.
4. Keep each task commit independently reviewable.

After Task 10, stop and present the exact branch/SHA, automated evidence, and remaining physical acceptance gates. Do not merge, push, archive, upload, submit, change pricing, or publish without the user's separate explicit authorization.
