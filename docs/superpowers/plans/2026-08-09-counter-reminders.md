# Counter Reminders and Adaptive Counter Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe direct counter entry, one optional row reminder per counter, an iPad-friendly manager, reminder cards, and reliable Watch haptics and acknowledgements without changing existing user data.

**Architecture:** Store an optional `CounterReminder` inside each `ProjectCounter` and evaluate all mutations through one platform-neutral engine. Persist a structured mutation outcome through `StoredProject` and `JSONProjectStore`, render it in focused SwiftUI views, and extend the existing reliable Watch snapshot/command protocol with reminder state and idempotent reminder actions.

**Tech Stack:** Swift 6, SwiftUI, Foundation Codable, Swift Testing, WatchConnectivity, XcodeGen.

## Global Constraints

- Existing projects without reminder fields decode unchanged with `reminder == nil`.
- Counter values and reminder targets are non-negative `Int` values; intervals and finite repetition limits are strictly positive.
- Each counter has at most one active reminder.
- Decrement and reset never rewind acknowledged reminder progress.
- Multiple targets crossed by one upward mutation produce one combined pending reminder.
- Completed projects remain immutable until resumed.
- iPhone, iPad, and Mac create/edit reminders; Watch only displays, haptics, completes, and stops them.
- User-authored project names, counter names, and reminder messages are never translated or rewritten.
- Do not change marketing version/build, archive, sign, upload, submit, merge, or push in this plan.

---

### Task 1: Core reminder model and crossing evaluator

**Files:**
- Create: `Sources/KnitNoteCore/Projects/CounterReminder.swift`
- Modify: `Sources/KnitNoteCore/Projects/ProjectCounter.swift`
- Create: `Tests/KnitNoteCoreTests/CounterReminderTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterTests.swift`

**Interfaces:**
- Produces: `CounterReminderDraft`, `CounterReminderEdit`, `CounterReminder`, `CounterReminderRule`, `CounterReminderPending`, `CounterMutationOutcome`, `CounterReminderEvaluation`, and `CounterReminderEvaluator`.
- Produces: `ProjectCounter.applyValue(_:) -> CounterMutationOutcome?`, `configureReminder(_:)`, `completePendingReminder(id:observedCount:)`, and `stopReminder(id:)`.
- Consumes: existing `ProjectCounter.value` and `mutationRevision`.

- [ ] **Step 1: Write failing model and crossing tests**

```swift
@Test func repeatingReminderCombinesEveryCrossedTarget() throws {
    var counter = ProjectCounter(defaultOrdinal: 1, value: 8)
    counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))

    let outcome = try #require(counter.applyValue(35))

    #expect(outcome.oldValue == 8)
    #expect(outcome.newValue == 35)
    #expect(outcome.pendingReminder?.occurrenceCount == 2)
    #expect(outcome.pendingReminder?.firstTarget == 18)
    #expect(outcome.pendingReminder?.lastTarget == 28)
}

@Test func decrementAndResetDoNotRewindAcknowledgedProgress() throws {
    var counter = ProjectCounter(defaultOrdinal: 1, value: 0)
    counter.configureReminder(.repeating(interval: 10, limit: nil, message: nil))
    let due = try #require(counter.applyValue(10)?.pendingReminder)
    #expect(counter.completePendingReminder(id: due.reminderID, observedCount: 1))
    _ = counter.applyValue(0)
    #expect(counter.reminder?.nextTarget == 20)
    #expect(counter.applyValue(10)?.pendingReminder == nil)
}
```

- [ ] **Step 2: Run the focused tests and witness RED**

Run:

```bash
swift test --disable-sandbox --filter CounterReminderTests
```

Expected: FAIL because the reminder types and APIs do not exist.

- [ ] **Step 3: Implement the minimal immutable rule and mutable progress types**

```swift
public enum CounterReminderRule: Codable, Hashable, Sendable {
    case oneTime(target: Int)
    case repeating(interval: Int, limit: Int?)
}

public enum CounterReminderDraft: Equatable, Sendable {
    case oneTime(target: Int, message: String?)
    case repeating(interval: Int, limit: Int?, message: String?)
}

public enum CounterReminderEdit: Equatable, Sendable {
    case unchanged
    case replace(CounterReminderDraft)
    case remove(expectedReminderID: UUID?)
}

public struct CounterReminder: Codable, Hashable, Sendable {
    public let id: UUID
    public let anchorValue: Int
    public private(set) var rule: CounterReminderRule
    public private(set) var message: String?
    public private(set) var acknowledgedCount: Int
    public private(set) var nextTarget: Int?
    public private(set) var pending: CounterReminderPending?
    public private(set) var isActive: Bool
    public private(set) var mutationRevision: UInt64
}

public struct CounterReminderPending: Codable, Hashable, Sendable {
    public let reminderID: UUID
    public let occurrenceCount: Int
    public let firstTarget: Int
    public let lastTarget: Int
}

public struct CounterMutationOutcome: Equatable, Sendable {
    public let oldValue: Int
    public let newValue: Int
    public let pendingReminder: CounterReminderPending?
}

public struct CounterReminderEvaluation: Equatable, Sendable {
    public let updatedReminder: CounterReminder
    public let newlyPending: CounterReminderPending?
}

public enum CounterReminderEvaluator {
    public static func applyingUpwardChange(
        from oldValue: Int,
        to newValue: Int,
        reminder: CounterReminder
    ) -> CounterReminderEvaluation
}
```

Implement overflow-checked target calculation with `addingReportingOverflow`, finite-limit capping, pending accumulation, exact reminder-ID matching, and no progress changes for downward mutations.

- [ ] **Step 4: Add backward-compatible Codable normalization tests**

```swift
@Test func legacyCounterWithoutReminderDecodesUnchanged() throws {
    let original = ProjectCounter(defaultOrdinal: 1, value: 42)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object.removeValue(forKey: "reminder")
    let decoded = try JSONDecoder().decode(
        ProjectCounter.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(decoded.value == 42)
    #expect(decoded.reminder == nil)
}
```

Add `reminder` to `ProjectCounter.CodingKeys`, decode with `decodeIfPresent`, and normalize an invalid reminder to `nil` without changing the counter.

- [ ] **Step 5: Run focused tests and commit**

```bash
swift test --disable-sandbox --filter CounterReminderTests
swift test --disable-sandbox --filter ProjectCounterTests
git add Sources/KnitNoteCore/Projects/CounterReminder.swift Sources/KnitNoteCore/Projects/ProjectCounter.swift Tests/KnitNoteCoreTests/CounterReminderTests.swift Tests/KnitNoteCoreTests/ProjectCounterTests.swift
git commit -m "feat: add counter reminder model"
```

Expected: both suites PASS.

---

### Task 2: Transactional project and reader-store mutations

**Files:**
- Modify: `Sources/KnitNoteCore/Projects/StoredProject.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- Modify: `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 `CounterReminder`, `CounterMutationOutcome`.
- Produces: `StoredProjectCounterMutationResult` and `PatternReaderCounterMutationResult`.
- Produces store mutations for configure, complete, and stop that preserve optimistic generation checks.

- [ ] **Step 1: Write failing transaction tests**

```swift
@MainActor @Test func readerMutationPublishesGenerationAndReminderTogether() throws {
    let harness = try PatternLibraryStoreHarness.onePatternAndProject()
    let usage = try harness.store.linkPattern(patternID: harness.patternID, to: harness.projectID)
    let counterID = try #require(harness.store.project(id: harness.projectID)?.counters[0].id)
    try harness.store.configureCounterReminder(
        projectID: harness.projectID,
        counterID: counterID,
        draft: .oneTime(target: 2, message: nil)
    )

    let result = try harness.store.mutatePatternReaderCounterWithOutcome(
        usageID: usage.id,
        counterID: counterID,
        mutation: .update(name: nil, value: 3),
        expectedDataGeneration: harness.store.dataGeneration
    )

    #expect(result.generation == harness.store.dataGeneration)
    #expect(result.outcome.pendingReminder?.occurrenceCount == 1)
    let reopened = try harness.reopenedStore()
    #expect(reopened.project(id: harness.projectID)?.counters[0].reminder?.pending != nil)
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter PatternLibraryStoreTests
```

Expected: FAIL because transactional reminder store APIs are missing.

- [ ] **Step 3: Add result-returning project mutations while preserving existing callers**

```swift
public struct StoredProjectCounterMutationResult: Equatable, Sendable {
    public let counter: ProjectCounter
    public let outcome: CounterMutationOutcome?
}

public struct PatternReaderCounterMutationResult: Equatable, Sendable {
    public let generation: UInt64
    public let outcome: CounterMutationOutcome?
}
```

Make existing `incrementCounter`, `decrementCounter`, `resetCounter`, and `updateCounter` `@discardableResult` and return the exact persisted counter outcome. Keep this exact compatibility API as a wrapper over `mutatePatternReaderCounterWithOutcome` so current generation-chaining tests and callers remain valid:

```swift
@discardableResult
public func mutatePatternReaderCounter(
    usageID: UUID,
    counterID: UUID,
    mutation: PatternReaderCounterMutation,
    expectedDataGeneration: UInt64
) throws -> UInt64 {
    try mutatePatternReaderCounterWithOutcome(
        usageID: usageID,
        counterID: counterID,
        mutation: mutation,
        expectedDataGeneration: expectedDataGeneration
    ).generation
}
```

- [ ] **Step 4: Add explicit reminder persistence operations**

```swift
public func configureCounterReminder(
    projectID: UUID,
    counterID: UUID,
    draft: CounterReminderDraft
) throws

public func completeCounterReminder(
    projectID: UUID,
    counterID: UUID,
    reminderID: UUID,
    observedCount: Int
) throws

public func stopCounterReminder(
    projectID: UUID,
    counterID: UUID,
    reminderID: UUID
) throws
```

Route each operation through `requireAccess(.changeCounter)`, the completed-project guard, a staged project copy, and the existing atomic `persist(projects:yarns:)` boundary.

Extend the reader mutation enum so the manager save and reminder actions remain one generation-checked transaction:

```swift
public enum PatternReaderCounterMutation: Sendable {
    case increment
    case reset
    case update(name: String?, value: Int)
    case manage(name: String?, value: Int, reminder: CounterReminderEdit)
    case completeReminder(reminderID: UUID, observedCount: Int)
    case stopReminder(reminderID: UUID)
}
```

- [ ] **Step 5: Verify stale-generation and reopen behavior, then commit**

```bash
swift test --disable-sandbox --filter ProjectCounterTests
swift test --disable-sandbox --filter PatternLibraryStoreTests
swift test --disable-sandbox --filter JSONProjectStoreTests
git add Sources/KnitNoteCore/Projects/StoredProject.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/ProjectCounterTests.swift Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift
git commit -m "feat: persist reminder-aware counter mutations"
```

Expected: all focused suites PASS, including prior stale-writer rejection tests.

---

### Task 3: Direct value parsing and adaptive counter manager

**Files:**
- Create: `Sources/KnitNoteCore/Projects/CounterValueInput.swift`
- Test: `Tests/KnitNoteCoreTests/CounterValueInputTests.swift`
- Rename: `KnitNote/Projects/EditCounterNameView.swift` to `KnitNote/Projects/CounterManagerView.swift`
- Modify: `KnitNote/Projects/ProjectDetailView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Produces: `CounterValueInput.parse(_:) throws -> Int`.
- Produces: `CounterManagerView(counter:onSave:)` and `CounterManagerSave`.
- Consumes: Task 2 transactional counter update APIs.

- [ ] **Step 1: Write failing parser and layout-contract tests**

```swift
@Test(arguments: ["", "-1", "1.5", "abc", "999999999999999999999999"])
func invalidCounterDraftsAreRejected(_ text: String) {
    #expect(throws: CounterValueInputError.self) {
        try CounterValueInput.parse(text)
    }
}

@Test func validCounterDraftUsesTheWholeNumber() throws {
    #expect(try CounterValueInput.parse("2048") == 2048)
}
```

Add source contracts requiring an editable value affordance, `ViewThatFits` or an equivalent geometry policy, visible minus/reset controls, and no `.presentationDetents([.medium])` lock on iPad.

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter CounterValueInputTests
swift test --disable-sandbox --filter ProjectCounterViewContractTests
```

- [ ] **Step 3: Implement strict parser and manager state**

```swift
public enum CounterValueInputError: Error, Equatable, Sendable {
    case empty
    case invalidWholeNumber
    case negative
    case overflow
}

public enum CounterValueInput {
    public static func parse(_ text: String) throws -> Int
}

struct CounterManagerSave {
    let name: String
    let value: Int
    let reminderEdit: CounterReminderEdit
}

struct CounterManagerView: View {
    let counter: ProjectCounter
    let onSave: (CounterManagerSave) -> Bool
}
```

The parser accepts only trimmed ASCII decimal digits and checks `Int` conversion. The SwiftUI editor keeps the original saved value until Save succeeds; Cancel and validation failure do not call persistence.

- [ ] **Step 4: Implement adaptive iPhone/iPad/Mac layout**

Use one `CounterManagerView` with platform-specific presentation sizing. Keep name, editable value, minus, plus, reset, and the reminder summary in the initially visible essential region. Use a large centered iPad frame in both orientations and a resizable Mac minimum size; retain a narrow single-column phone layout. Add VoiceOver labels and Dynamic Type-safe button labels.

- [ ] **Step 5: Wire PatternReaderView and commit**

Replace `EditCounterNameView` at both existing `.sheet(item: $managingCounter)` boundaries. `ProjectDetailView` saves through the direct project transaction; `PatternReaderView` saves one `.manage(name:value:reminder:)` mutation through the generation-checked reader store method. Dismiss only after successful persistence.

```bash
swift test --disable-sandbox --filter CounterValueInputTests
swift test --disable-sandbox --filter ProjectCounterViewContractTests
swift test --disable-sandbox --filter PatternReaderCounterContractTests
git add Sources/KnitNoteCore/Projects/CounterValueInput.swift Tests/KnitNoteCoreTests/CounterValueInputTests.swift KnitNote/Projects/CounterManagerView.swift KnitNote/Projects/ProjectDetailView.swift KnitNote/Patterns/PatternReaderView.swift Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git rm KnitNote/Projects/EditCounterNameView.swift
git commit -m "feat: make counter management adaptive and editable"
```

Expected: focused suites PASS.

---

### Task 4: Reminder editor and reader reminder card

**Files:**
- Create: `KnitNote/Projects/CounterReminderEditor.swift`
- Create: `KnitNote/Patterns/CounterReminderCard.swift`
- Modify: `KnitNote/Projects/CounterManagerView.swift`
- Modify: `KnitNote/Patterns/PatternReaderView.swift`
- Create: `Tests/KnitNoteCoreTests/CounterReminderViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`

**Interfaces:**
- Consumes: Task 1 reminder types and Task 2 store mutations.
- Produces: `CounterReminderEditor(draft:counterValue:)` and `CounterReminderCard(pending:message:onComplete:onStop:)`.

- [ ] **Step 1: Write failing presentation contracts**

```swift
@Test func reminderCardHasExactlyTheApprovedActions() throws {
    let source = try projectSource(named: "CounterReminderCard")
    #expect(source.contains("counter.reminder.complete"))
    #expect(source.contains("counter.reminder.stop"))
    #expect(!source.contains("snooze"))
    #expect(!source.contains("later"))
}
```

Add contracts for one-time/repeating controls, optional repetition limit, optional message, combined occurrence copy, and current-locale rendering.

Use these exact view boundaries:

```swift
struct CounterReminderEditor: View {
    @Binding var draft: CounterReminderDraft?
    let counterValue: Int
}

struct CounterReminderCard: View {
    let pending: CounterReminderPending
    let message: String?
    let onComplete: () -> Void
    let onStop: () -> Void
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter CounterReminderViewContractTests
```

- [ ] **Step 3: Implement reminder editor validation**

The editor disables Save for a one-time target not greater than the current value, a zero interval, or a non-positive finite count. Saving a replacement with progress presents an explicit replacement confirmation. The custom message is trimmed; an empty result becomes `nil`.

- [ ] **Step 4: Implement persisted reminder-card presentation**

Derive the visible pending reminder from the latest stored project/counter, not transient view state. On upward mutation, refresh from the exact committed store result. Complete passes the visible reminder ID and occurrence count; Stop passes the visible reminder ID. Both keep the card open and show `LocalizedMessage.key("error.saveFailed")` on failure.

- [ ] **Step 5: Verify and commit**

```bash
swift test --disable-sandbox --filter CounterReminderTests
swift test --disable-sandbox --filter CounterReminderViewContractTests
swift test --disable-sandbox --filter PatternReaderCounterContractTests
git add KnitNote/Projects/CounterReminderEditor.swift KnitNote/Patterns/CounterReminderCard.swift KnitNote/Projects/CounterManagerView.swift KnitNote/Patterns/PatternReaderView.swift Tests/KnitNoteCoreTests/CounterReminderViewContractTests.swift Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift
git commit -m "feat: add counter reminder editing and cards"
```

---

### Task 5: Watch reminder snapshots, haptics, and idempotent actions

**Files:**
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchOptimisticState.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift`
- Modify: `KnitNoteWatch/Sync/WatchSyncCoordinator.swift`
- Modify: `KnitNoteWatch/ProjectCountersView.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchSyncModelsTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchOptimisticStateTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`

**Interfaces:**
- Produces: `WatchCounterReminderSnapshot` on `WatchCounterSnapshot.reminder`.
- Extends: `WatchCounterOperation` with `.completeReminder` and `.stopReminder`.
- Extends: `WatchCounterCommand` with optional `reminderID` and `observedPendingCount`, validated by operation.

- [ ] **Step 1: Write failing Watch codec and optimistic-state tests**

```swift
@Test func duplicateReminderAcknowledgementCannotCompleteTwice() throws {
    var ledger = ProcessedWatchCommandLedger()
    let command = WatchCounterCommand(
        id: UUID(),
        projectID: project.id,
        counterID: counter.id,
        operation: .completeReminder,
        reminderID: reminder.id,
        observedPendingCount: 1
    )
    _ = try store.applyWatchCommand(command, ledger: &ledger)
    let afterFirst = store.project(id: project.id)?.counters[0].reminder?.acknowledgedCount
    _ = try store.applyWatchCommand(command, ledger: &ledger)
    #expect(store.project(id: project.id)?.counters[0].reminder?.acknowledgedCount == afterFirst)
}
```

Add tests for schema validation, optimistic increment crossing, no invented reminder when snapshot state is absent, stale reminder-ID rejection, and Stop winning over stale completion.

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter WatchSyncModelsTests
swift test --disable-sandbox --filter WatchOptimisticStateTests
swift test --disable-sandbox --filter WatchCommandApplicationTests
```

- [ ] **Step 3: Extend the versioned Watch protocol**

Increment `WatchSyncSnapshot.currentSchemaVersion` and `WatchCounterCommand.currentSchemaVersion`. Decode only the exact current schema. Include only the reminder state Watch needs: stable ID, next target, pending summary, optional user message, and active state.

Validate that increment/decrement/reset commands have no reminder payload; complete/stop commands require a reminder ID, and complete requires a positive observed pending count.

- [ ] **Step 4: Add optimistic reminder evaluation and UI**

Apply the same core crossing policy to the Watch optimistic snapshot. When an increment creates a new local pending reminder, call `WKInterfaceDevice.current().play(.notification)` once for that local transition. Render a reminder confirmation with only Complete and Stop. Do not replay haptic when an authoritative snapshot confirms an already-visible pending state or when a queued acknowledgement merges.

- [ ] **Step 5: Verify reliable reconnect behavior and commit**

```bash
swift test --disable-sandbox --filter WatchSyncModelsTests
swift test --disable-sandbox --filter WatchOptimisticStateTests
swift test --disable-sandbox --filter WatchCommandApplicationTests
swift test --disable-sandbox --filter PhoneWatchSyncSourceContractTests
swift test --disable-sandbox --filter WatchCounterViewContractTests
git add Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift Sources/KnitNoteCore/WatchSync/WatchOptimisticState.swift Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift KnitNoteWatch/Sync/WatchSyncCoordinator.swift KnitNoteWatch/ProjectCountersView.swift Tests/KnitNoteCoreTests/WatchSyncModelsTests.swift Tests/KnitNoteCoreTests/WatchOptimisticStateTests.swift Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift
git commit -m "feat: sync counter reminders with Apple Watch"
```

---

### Task 6: Existing-language copy and accessibility contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNoteWatch/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ShareExtensionLocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift`

**Interfaces:**
- Consumes: semantic keys introduced in Tasks 3–5.
- Produces: complete reminder/counter copy for the existing twelve locales.

- [ ] **Step 1: Add failing exact key-domain tests**

Require these semantic families in main and Watch catalogs as applicable:

```swift
let requiredReminderKeys = [
    "counter.value.edit",
    "counter.value.invalid",
    "counter.reminder.mode.oneTime",
    "counter.reminder.mode.repeating",
    "counter.reminder.target",
    "counter.reminder.interval",
    "counter.reminder.limit",
    "counter.reminder.message",
    "counter.reminder.complete",
    "counter.reminder.stop",
    "counter.reminder.reached",
    "counter.reminder.crossedCount",
]
```

Use `SupportedLocalization.v141Identifiers` and assert non-empty, non-stale translations with matching format/plural tokens.

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter StringCatalogLocalizationContractTests
swift test --disable-sandbox --filter ShareExtensionLocalizationContractTests
```

- [ ] **Step 3: Add reviewed copy to all twelve existing languages**

Add source comments describing row-counter semantics, explicit plural variations for crossed occurrence count, and localized default “Reached row %lld.” Preserve custom user messages verbatim. Keep Watch copy short enough for its existing compact UI contracts.

- [ ] **Step 4: Add accessibility source contracts**

Require localized labels/hints for editable value, next target, combined pending count, complete, and stop; require 44-point minimum actions and no fixed-height clipping at accessibility Dynamic Type.

- [ ] **Step 5: Verify and commit**

```bash
swift test --disable-sandbox --filter StringCatalogLocalizationContractTests
swift test --disable-sandbox --filter ShareExtensionLocalizationContractTests
swift test --disable-sandbox --filter ProjectCounterViewContractTests
git add KnitNote/Localization/Localizable.xcstrings KnitNoteWatch/Localizable.xcstrings Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/ShareExtensionLocalizationContractTests.swift Tests/KnitNoteCoreTests/ProjectCounterViewContractTests.swift
git commit -m "feat: localize accessible counter reminders"
```

---

### Task 7: Full verification and physical acceptance record

**Files:**
- Create: `AppStore/Verification/CounterReminders150Verification.md`
- Modify only if a failing contract proves necessary: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: an evidence record that distinguishes automated verification, builds, and physical acceptance.

- [ ] **Step 1: Run the full Swift suite**

```bash
swift test --disable-sandbox
```

Expected: all suites PASS with an exact test/suite count recorded.

- [ ] **Step 2: Build every shipping product without archive or upload**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -target KnitNoteShare -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: four exit codes are zero.

- [ ] **Step 3: Run automated UI geometry and accessibility checks**

Verify iPad portrait/landscape essential controls, iPhone narrow layout, Mac keyboard order, reminder-card actions, VoiceOver labels, and existing-data overlay-install fixtures. Record exact test commands and results.

- [ ] **Step 4: Install a Debug build over existing physical data and obtain scoped user acceptance**

Do not uninstall or erase data. Verify on physical iPhone and iPad:

- original projects and counter values remain present;
- iPad portrait and landscape show minus, plus, reset, value editing, and reminder controls without scrolling;
- direct entry validation and combined crossing behavior match the spec.

Verify on physical Watch:

- increment crossing plays one haptic;
- Complete and Stop synchronize;
- an offline action reconnects without duplicate completion or haptic.

Record pending items as pending; do not infer physical PASS from builds.

- [ ] **Step 5: Verify Mac and commit the evidence record**

Verify resizable layout, keyboard navigation, VoiceOver, persistence, and card behavior on Mac. Then:

```bash
git add AppStore/Verification/CounterReminders150Verification.md
git commit -m "test: verify counter reminders across platforms"
```

Do not mark the overall feature accepted until every required physical assertion has explicit evidence.
