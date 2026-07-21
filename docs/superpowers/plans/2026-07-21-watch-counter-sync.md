# KnitNote Watch Counter Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sample Watch screen with a production companion that mirrors every iPhone project and its six counters, accepts offline counter commands, and applies every command to the iPhone exactly once.

**Architecture:** `JSONProjectStore` on iPhone remains authoritative. Platform-neutral sync models, queue persistence, snapshot creation, command application, and deduplication live in `KnitNoteCore`; thin iOS and watchOS coordinators adapt those types to `WCSession`. The Watch caches one current snapshot plus an ordered durable command queue, renders optimistic values, and always reconciles to the acknowledged iPhone snapshot.

**Tech Stack:** Swift 6, SwiftUI, Observation via `ObservableObject`, WatchConnectivity, Foundation JSON/atomic file replacement, Swift Testing, XcodeGen 2.45.4, iOS 18, watchOS 11, macOS 15.

## Global Constraints

- iPhone is the only authoritative store; do not add iCloud, a server, an account, analytics, or third-party dependencies.
- Sync only project ID/name/completion/update date, exactly six counter IDs/full names/values, and the selected counter ID.
- Every Watch mutation is durably queued before optimistic presentation and has a unique UUID.
- Delivery is at-least-once; processed command IDs make mutation effects exactly-once.
- Retain deduplication records for both at least 1,000 latest IDs and at least 90 days.
- Completed projects are visible but read-only. Project/counter editing remains off Watch.
- Localize all system text in Traditional Chinese and English; never abbreviate stored user names.
- Preserve `com.phillon.KnitNote`, `com.phillon.KnitNote.watch`, version `1.0.0`, build `1`, and team `9CFPAUL5N5` unless upload validation requires a later build number.
- A real paired iPhone and Apple Watch test is required before release approval.

---

### Task 1: Define the versioned sync protocol

**Files:**
- Create: `Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift`
- Test: `Tests/KnitNoteCoreTests/WatchSyncModelsTests.swift`

**Interfaces:**
- Produces: `WatchProjectSnapshot`, `WatchCounterSnapshot`, `WatchSyncSnapshot`, `WatchCounterCommand`, `WatchCounterOperation`, `WatchCommandRejection`, `WatchCommandAcknowledgement`.
- Produces: `WatchSyncCodec.encode<T: Encodable>(_:) throws -> Data` and `WatchSyncCodec.decode<T: Decodable>(_:from:) throws -> T`.
- Invariant: `WatchProjectSnapshot.init` throws `WatchSyncValidationError.invalidCounterCount` unless there are exactly six counters with unique IDs and the selected ID belongs to that array.

- [ ] **Step 1: Write failing model and codec tests**

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct WatchSyncModelsTests {
    @Test func snapshotRoundTripsSixCounters() throws {
        let counters = (1...6).map {
            WatchCounterSnapshot(id: UUID(), name: "Counter \($0)", value: $0)
        }
        let project = try WatchProjectSnapshot(
            id: UUID(), name: "Sweater", isCompleted: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            counters: counters, selectedCounterID: counters[2].id
        )
        let value = WatchSyncSnapshot(
            schemaVersion: WatchSyncSnapshot.currentSchemaVersion,
            generatedAt: Date(timeIntervalSince1970: 101), projects: [project]
        )
        let decoded = try WatchSyncCodec.decode(
            WatchSyncSnapshot.self,
            from: WatchSyncCodec.encode(value)
        )
        #expect(decoded == value)
    }

    @Test func projectRejectsAnythingOtherThanSixUniqueCounters() {
        #expect(throws: WatchSyncValidationError.invalidCounterCount) {
            _ = try WatchProjectSnapshot(
                id: UUID(), name: "Bad", isCompleted: false, updatedAt: .now,
                counters: [WatchCounterSnapshot(id: UUID(), name: "Only", value: 0)],
                selectedCounterID: UUID()
            )
        }
    }

    @Test func unsupportedSchemaIsRejected() throws {
        let data = Data(#"{"schemaVersion":99,"generatedAt":0,"projects":[]}"#.utf8)
        #expect(throws: WatchSyncValidationError.unsupportedSchema) {
            _ = try WatchSyncCodec.decode(WatchSyncSnapshot.self, from: data)
        }
    }

    @Test func commandCarriesStableIdentityAndOperation() throws {
        let command = WatchCounterCommand(
            id: UUID(), projectID: UUID(), counterID: UUID(),
            operation: .decrement, createdAt: Date(timeIntervalSince1970: 42)
        )
        #expect(try WatchSyncCodec.decode(
            WatchCounterCommand.self,
            from: WatchSyncCodec.encode(command)
        ) == command)
    }
}
```

- [ ] **Step 2: Run the focused tests and confirm the expected compile failure**

Run: `swift test --filter WatchSyncModelsTests`

Expected: FAIL because `WatchSyncSnapshot` and related types do not exist.

- [ ] **Step 3: Implement the protocol types and validated decoding**

```swift
import Foundation

public enum WatchSyncValidationError: Error, Equatable {
    case unsupportedSchema
    case invalidCounterCount
    case duplicateCounterID
    case invalidSelectedCounter
}

public struct WatchCounterSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public var value: Int
    public init(id: UUID, name: String, value: Int) {
        self.id = id; self.name = name; self.value = max(0, value)
    }
}

public struct WatchProjectSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let isCompleted: Bool
    public let updatedAt: Date
    public var counters: [WatchCounterSnapshot]
    public let selectedCounterID: UUID

    public init(id: UUID, name: String, isCompleted: Bool, updatedAt: Date,
                counters: [WatchCounterSnapshot], selectedCounterID: UUID) throws {
        guard counters.count == 6 else { throw WatchSyncValidationError.invalidCounterCount }
        guard Set(counters.map(\.id)).count == 6 else { throw WatchSyncValidationError.duplicateCounterID }
        guard counters.contains(where: { $0.id == selectedCounterID }) else {
            throw WatchSyncValidationError.invalidSelectedCounter
        }
        self.id = id; self.name = name; self.isCompleted = isCompleted
        self.updatedAt = updatedAt; self.counters = counters
        self.selectedCounterID = selectedCounterID
    }
}

public struct WatchSyncSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let generatedAt: Date
    public let projects: [WatchProjectSnapshot]
    public init(schemaVersion: Int = currentSchemaVersion, generatedAt: Date, projects: [WatchProjectSnapshot]) {
        self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.projects = projects
    }
}

public enum WatchCounterOperation: String, Codable, Equatable, Sendable { case increment, decrement, reset }
public struct WatchCounterCommand: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let id: UUID
    public let projectID: UUID
    public let counterID: UUID
    public let operation: WatchCounterOperation
    public let createdAt: Date
    public init(schemaVersion: Int = currentSchemaVersion, id: UUID = UUID(), projectID: UUID,
                counterID: UUID, operation: WatchCounterOperation, createdAt: Date = .now) {
        self.schemaVersion = schemaVersion; self.id = id; self.projectID = projectID
        self.counterID = counterID; self.operation = operation; self.createdAt = createdAt
    }
}

public enum WatchCommandRejection: String, Codable, Equatable, Sendable {
    case unsupportedSchema, projectMissing, counterMissing, projectCompleted, storageFailure
}
public struct WatchCommandAcknowledgement: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let rejection: WatchCommandRejection?
    public let snapshot: WatchSyncSnapshot
}

public enum WatchSyncCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(type, from: data)
        if let snapshot = value as? WatchSyncSnapshot,
           snapshot.schemaVersion != WatchSyncSnapshot.currentSchemaVersion {
            throw WatchSyncValidationError.unsupportedSchema
        }
        if let command = value as? WatchCounterCommand,
           command.schemaVersion != WatchCounterCommand.currentSchemaVersion {
            throw WatchSyncValidationError.unsupportedSchema
        }
        return value
    }
}
```

Ensure custom `init(from:)` on `WatchProjectSnapshot` delegates through its throwing initializer so decoded snapshots receive the same validation.

- [ ] **Step 4: Run the focused and complete package suites**

Run: `swift test --filter WatchSyncModelsTests && swift test`

Expected: PASS; all existing suites remain green.

- [ ] **Step 5: Commit the protocol slice**

```bash
git add Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift Tests/KnitNoteCoreTests/WatchSyncModelsTests.swift
git commit -m "feat: define Watch counter sync protocol"
```

### Task 2: Build authoritative snapshots and apply commands exactly once

**Files:**
- Create: `Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift`
- Create: `Sources/KnitNoteCore/WatchSync/ProcessedWatchCommandLedger.swift`
- Modify: `Sources/KnitNoteCore/Projects/ProjectCounter.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Test: `Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift`

**Interfaces:**
- Consumes: Task 1 protocol models.
- Produces: `WatchSnapshotBuilder.make(projects:locale:generatedAt:) throws -> WatchSyncSnapshot`.
- Produces: `JSONProjectStore.applyWatchCommand(_:ledger:now:) throws -> WatchCommandAcknowledgement`.
- Produces: `ProcessedWatchCommandLedger.contains(_:)`, `record(_:at:)`, and `prune(now:)`.
- Add `ProjectCounter.displayName(locale:) -> String` so the existing localized default format is shared with Watch snapshots.
- Add a Codable `ProjectCounter.mutationRevision: UInt64` that starts at zero, increments for every value-changing increment/decrement/reset/update, and is unchanged by name-only edits. Task 3 uses it for crash-safe transaction recovery.

- [ ] **Step 1: Write failing snapshot, mutation, rejection, and duplicate tests**

```swift
@Test @MainActor func duplicateDeliveryMutatesOnlyOnce() throws {
    let fixture = try WatchStoreFixture()
    let project = try #require(fixture.store.projects.first)
    let counter = project.counters[0]
    let command = WatchCounterCommand(
        id: UUID(), projectID: project.id, counterID: counter.id,
        operation: .increment, createdAt: fixture.now
    )
    var ledger = ProcessedWatchCommandLedger()
    _ = try fixture.store.applyWatchCommand(command, ledger: &ledger, now: fixture.now)
    _ = try fixture.store.applyWatchCommand(command, ledger: &ledger, now: fixture.now)
    #expect(fixture.store.project(id: project.id)?.counters[0].value == 1)
}

@Test @MainActor func completedProjectRejectsWithoutMutation() throws {
    let fixture = try WatchStoreFixture(completed: true)
    let project = try #require(fixture.store.projects.first)
    var ledger = ProcessedWatchCommandLedger()
    let acknowledgement = try fixture.store.applyWatchCommand(
        WatchCounterCommand(projectID: project.id, counterID: project.counters[0].id, operation: .increment),
        ledger: &ledger, now: fixture.now
    )
    #expect(acknowledgement.rejection == .projectCompleted)
    #expect(fixture.store.project(id: project.id)?.counters[0].value == 0)
}

@Test func pruningKeepsRecentThousandAndAllNinetyDayEntries() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    var ledger = ProcessedWatchCommandLedger()
    for offset in 0..<1_100 { ledger.record(UUID(), at: now.addingTimeInterval(Double(-offset))) }
    let withinWindow = UUID(); ledger.record(withinWindow, at: now.addingTimeInterval(-89 * 86_400))
    ledger.prune(now: now)
    #expect(ledger.contains(withinWindow))
    #expect(ledger.entries.count >= 1_000)
}
```

- [ ] **Step 2: Run the tests and verify failure**

Run: `swift test --filter WatchCommandApplicationTests`

Expected: FAIL because builder, ledger, and command-application APIs do not exist.

- [ ] **Step 3: Implement snapshot mapping and ledger pruning**

Use stable sorting: active projects before completed projects, then `updatedAt` descending. Resolve unnamed counters with the existing localized key `counter.defaultNameFormat`, not hard-coded English. Store ledger entries as:

```swift
public struct ProcessedWatchCommandLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable { public let id: UUID; public let processedAt: Date }
    public private(set) var entries: [Entry] = []
    public mutating func record(_ id: UUID, at date: Date) { /* replace duplicate, append, prune */ }
    public func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }
    public mutating func prune(now: Date) {
        let newest = entries.sorted { $0.processedAt > $1.processedAt }
        let protectedIDs = Set(newest.prefix(1_000).map(\.id))
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        entries = newest.filter { protectedIDs.contains($0.id) || $0.processedAt >= cutoff }
    }
}
```

- [ ] **Step 4: Implement atomic command application**

Before mutation, validate schema/project/counter/completion. If the ID is already in the ledger, return a fresh snapshot without mutation. For a new valid command, delegate the durable transaction ordering to Task 3; the pure application path mutates the project exactly once and advances that counter's `mutationRevision`. If project persistence fails, return/throw storage failure and do not mark processed. Build every acknowledgement from current `store.projects`.

```swift
public func applyWatchCommand(
    _ command: WatchCounterCommand,
    ledger: inout ProcessedWatchCommandLedger,
    now: Date = .now
) throws -> WatchCommandAcknowledgement
```

The decrement path must call `decrementCounter`; its existing floor of zero is the sole lower-bound rule. Reset calls `resetCounter`. Unsupported/rejected commands are recorded after the unchanged authoritative state is durable so background retries do not loop forever.

- [ ] **Step 5: Run focused and regression tests**

Run: `swift test --filter WatchCommandApplicationTests && swift test`

Expected: PASS, including duplicate, floor-at-zero, reset, missing project/counter, completion, order, and interleaved-iPhone-mutation cases.

- [ ] **Step 6: Commit authoritative processing**

```bash
git add Sources/KnitNoteCore/WatchSync Sources/KnitNoteCore/Projects/ProjectCounter.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift
git commit -m "feat: apply Watch counter commands exactly once"
```

### Task 3: Add durable, recoverable synchronization files

**Files:**
- Create: `Sources/KnitNoteCore/WatchSync/AtomicWatchSyncFile.swift`
- Create: `Sources/KnitNoteCore/WatchSync/WatchSyncCache.swift`
- Create: `Sources/KnitNoteCore/WatchSync/PreparedWatchCommand.swift`
- Create: `Tests/KnitNoteCoreTests/WatchSyncPersistenceTests.swift`

**Interfaces:**
- Produces: `AtomicWatchSyncFile<Value: Codable & Sendable>` with `public let url: URL`, `load() throws -> Value?`, `save(_:) throws`, and `quarantineCorruptFile() throws`.
- Produces: `WatchSyncCache(snapshot:pendingCommands:selectedProjectID:selectedCounterID:)`.
- Produces: `WatchSyncPaths.watchCache(in:)`, `processedLedger(in:)`, `preparedCommand(in:)`, and quarantine names containing an ISO-8601 timestamp.
- Produces: `PreparedWatchCommand(command:expectedCounterRevision:)` and a recovery routine that finishes or acknowledges an interrupted transaction before accepting another command.

- [ ] **Step 1: Write failing restart, atomicity, and corruption tests**

Test that pending commands survive creating a new file-store instance, a valid old file remains after an injected pre-replacement write failure, corrupt Watch cache is renamed and returns an empty cache, and corrupt iPhone ledger returns a `requiresFreshHandshake` recovery state rather than accepting commands. Add injected-crash tests at every boundary: after prepared-command save, after project archive save, after ledger save, and after prepared-command deletion; every restart must produce one mutation effect.

```swift
@Test func pendingQueueSurvivesRestart() throws {
    let root = try TemporaryDirectory()
    let file = AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: root.url))
    let command = WatchCounterCommand(projectID: UUID(), counterID: UUID(), operation: .increment)
    try file.save(WatchSyncCache(snapshot: nil, pendingCommands: [command]))
    #expect(try AtomicWatchSyncFile<WatchSyncCache>(url: file.url).load()?.pendingCommands == [command])
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter WatchSyncPersistenceTests`

Expected: FAIL because persistence types are undefined.

- [ ] **Step 3: Implement focused JSON persistence**

Use `FileManager.createDirectory`, `WatchSyncCodec`, and `Data.write(to:options:.atomic)`. Do not reuse the full backup package. `WatchSyncCache` has `schemaVersion = 1`, optional snapshot, ordered commands, optional selected IDs, and validates selected IDs against the current snapshot on load.

For each accepted phone-side command, use this exact write-ahead sequence on the coordinator's serial executor:

1. atomically save `PreparedWatchCommand` with the counter's current `mutationRevision`;
2. apply and atomically persist the project mutation, which advances the revision by one;
3. atomically save the ledger containing the command ID;
4. atomically remove the prepared-command file;
5. acknowledge only after step 4.

On launch, recover before activating `WCSession`. If current revision equals the prepared revision, the project mutation was not committed: apply once, save ledger, then clear the receipt. If current revision equals prepared revision plus one, the mutation committed: record without reapplying, save ledger, then clear the receipt. Any other revision, missing project/counter, or corrupt receipt enters `requiresFreshHandshake` and must not replay unverifiable commands. This revision protocol closes the crash window between the project archive and focused ledger files while retaining the approved separate synchronization file.

Corrupt Watch cache behavior: rename to `watch-sync-cache.corrupt-<timestamp>.json`, return `.empty`, and request a snapshot. Corrupt iPhone ledger behavior: rename it, create an empty ledger marked `requiresFreshHandshake = true`, reject incoming background commands until a Watch handshake carries its current queue IDs, then seed the ledger safely before normal processing.

- [ ] **Step 4: Run persistence and full tests**

Run: `swift test --filter WatchSyncPersistenceTests && swift test`

Expected: PASS with no corruption test modifying `projects-v1.json`.

- [ ] **Step 5: Commit persistence**

```bash
git add Sources/KnitNoteCore/WatchSync Tests/KnitNoteCoreTests/WatchSyncPersistenceTests.swift
git commit -m "feat: persist Watch sync state safely"
```

### Task 4: Create testable WatchConnectivity envelopes and adapters

**Files:**
- Create: `Sources/KnitNoteCore/WatchSync/WatchConnectivityEnvelope.swift`
- Create: `KnitNote/WatchSync/PhoneWatchSession.swift`
- Create: `KnitNoteWatch/Sync/WatchSession.swift`
- Test: `Tests/KnitNoteCoreTests/WatchConnectivityEnvelopeTests.swift`

**Interfaces:**
- Produces: message keys `kind`, `payload`, with kinds `snapshotRequest`, `snapshot`, `command`, `acknowledgement`, and `queueHandshake`.
- Produces core `WatchConnectivityEnvelope` encode/decode to `[String: Any]` using a `Data` payload.
- Phone/Watch adapters expose closures for received envelope, reachability, activation, and transfer completion; coordinators never depend directly on `WCSession.default` in tests.

- [ ] **Step 1: Write failing envelope tests**

```swift
@Test func commandEnvelopeRoundTripsThroughPropertyListDictionary() throws {
    let command = WatchCounterCommand(projectID: UUID(), counterID: UUID(), operation: .reset)
    let dictionary = try WatchConnectivityEnvelope.command(command).dictionaryRepresentation()
    #expect(try WatchConnectivityEnvelope(dictionary: dictionary) == .command(command))
}
```

Also test missing kind, missing payload, wrong payload type, and an unsupported kind.

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter WatchConnectivityEnvelopeTests`

Expected: FAIL because the envelope type does not exist.

- [ ] **Step 3: Implement envelope and platform adapters**

`PhoneWatchSession` and `WatchSession` are `NSObject, WCSessionDelegate`, activate only when `WCSession.isSupported()`, and immediately hop delegate callbacks into their coordinator's serialized task. Implement:

```swift
func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws
func sendMessage(_ envelope: WatchConnectivityEnvelope,
                 reply: @escaping @Sendable (WatchConnectivityEnvelope) -> Void,
                 failure: @escaping @Sendable (Error) -> Void)
func transferUserInfo(_ envelope: WatchConnectivityEnvelope)
```

On iOS implement activation, inactive, deactivation, and reactivation delegate methods. On watchOS implement activation completion, `didReceiveApplicationContext`, message/reply, and user-info delivery. Never force-cast incoming dictionaries.

- [ ] **Step 4: Run tests and platform compile checks**

Run: `swift test --filter WatchConnectivityEnvelopeTests && xcodegen generate && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and both builds exit 0.

- [ ] **Step 5: Commit transport adapters**

```bash
git add Sources/KnitNoteCore/WatchSync/WatchConnectivityEnvelope.swift KnitNote/WatchSync KnitNoteWatch/Sync Tests/KnitNoteCoreTests/WatchConnectivityEnvelopeTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: adapt WatchConnectivity transport"
```

### Task 5: Coordinate iPhone publication, deduplication, and acknowledgements

**Files:**
- Create: `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Create: `Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift`

**Interfaces:**
- Consumes: `JSONProjectStore`, Task 2 builder/application, Task 3 ledger file, Task 4 session adapter.
- Produces: `@MainActor final class PhoneWatchSyncCoordinator: ObservableObject` with `start()`, `publishLatestSnapshot()`, `receive(_:) async`.
- App owns coordinator for its full process lifetime and subscribes once to `projectStore.$projects`.

- [ ] **Step 1: Add failing source-contract tests**

Read the two source files and assert the app owns a `@StateObject` coordinator, calls `start`, observes project-store changes, and the coordinator handles all five envelope kinds without using `try!`, `as!`, or `fatalError`.

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter PhoneWatchSyncSourceContractTests`

Expected: FAIL because coordinator integration is absent.

- [ ] **Step 3: Implement serialized phone coordination**

Initialize from the live Application Support root, load the ledger, activate session, and publish an initial snapshot. Use an `AsyncStream` or private serial `Task` chain so two delegate callbacks never concurrently mutate the ledger/store. On every `projectStore.$projects` event, debounce only redundant snapshot sends; never delay a command acknowledgement.

For a command: validate/execute, durably save the updated ledger, generate acknowledgement, reply immediately if there is a reply handler, otherwise enqueue background acknowledgement, and call `updateApplicationContext` with the same snapshot. For a queue handshake after ledger corruption, reconcile IDs without replaying unverifiable commands, clear `requiresFreshHandshake`, persist, and request/reply with the latest snapshot.

- [ ] **Step 4: Run tests and iOS/macOS builds**

The coordinator must compile only for iOS (`#if os(iOS)` or XcodeGen destination filter); macOS retains normal app behavior without WatchConnectivity startup.

Run: `swift test && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`

Expected: all commands exit 0.

- [ ] **Step 5: Commit phone coordination**

```bash
git add KnitNote/WatchSync KnitNote/App/KnitNoteApp.swift Tests/KnitNoteCoreTests/PhoneWatchSyncSourceContractTests.swift
git commit -m "feat: coordinate iPhone Watch synchronization"
```

### Task 6: Coordinate Watch optimistic state and offline replay

**Files:**
- Create: `KnitNoteWatch/Sync/WatchSyncCoordinator.swift`
- Modify: `KnitNoteWatch/KnitNoteWatchApp.swift`
- Test: `Tests/KnitNoteCoreTests/WatchOptimisticStateTests.swift`

**Interfaces:**
- Produces: `@MainActor final class WatchSyncCoordinator: ObservableObject` with published snapshot, pending count, selected IDs, and localized error reason.
- Produces: `increment`, `decrement`, `reset` that queue before applying optimistic state.
- Produces: pure `WatchOptimisticState.enqueue(_:)`, `acknowledge(_:)`, `replaceSnapshot(_:)` for deterministic tests.

- [ ] **Step 1: Write failing offline/acknowledgement tests**

Cover: queue-before-display, three ordered offline operations, restart/reload, immediate acknowledgement, rejected completion, retry of same ID, snapshot winning after acknowledgement, and removal of selections that no longer exist.

```swift
@Test func rejectionRemovesCommandAndUsesPhoneSnapshot() throws {
    var state = WatchOptimisticState(cache: fixtureCache(value: 4))
    let command = state.makeAndEnqueue(projectID: projectID, counterID: counterID, operation: .increment)
    #expect(state.displayedValue(projectID: projectID, counterID: counterID) == 5)
    state.acknowledge(.init(commandID: command.id, rejection: .projectCompleted, snapshot: fixtureSnapshot(value: 4)))
    #expect(state.pendingCommands.isEmpty)
    #expect(state.displayedValue(projectID: projectID, counterID: counterID) == 4)
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter WatchOptimisticStateTests`

Expected: FAIL because optimistic state/coordinator do not exist.

- [ ] **Step 3: Implement queue-first optimistic state**

The mutation sequence is fixed: create command → append queue → atomically persist → update presentation → try `sendMessage` if reachable → also retain/transfer until acknowledgement. Never remove a command on transport completion; remove only on matching acknowledgement. On activation/reachability, send queue handshake then replay pending commands in their original order.

- [ ] **Step 4: Integrate app lifecycle and run tests**

`KnitNoteWatchApp` owns the coordinator with `@StateObject`, starts it once, and injects it into `WatchCounterView`. Run `swift test --filter WatchOptimisticStateTests && swift test`.

Expected: PASS.

- [ ] **Step 5: Commit Watch coordination**

```bash
git add KnitNoteWatch/Sync KnitNoteWatch/KnitNoteWatchApp.swift Tests/KnitNoteCoreTests/WatchOptimisticStateTests.swift
git commit -m "feat: queue and replay Watch counter changes"
```

### Task 7: Replace the sample Watch UI with accessible project and counter screens

**Files:**
- Replace: `KnitNoteWatch/WatchCounterView.swift`
- Create: `KnitNoteWatch/ProjectListView.swift`
- Create: `KnitNoteWatch/ProjectCountersView.swift`
- Modify: `KnitNoteWatch/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: published state/actions from Task 6.
- Project list navigates by project ID; counter list invokes actions by stable project/counter IDs.
- Long press opens `confirmationDialog` with decrement and reset; tap increments.

- [ ] **Step 1: Write failing UI/localization contract tests**

Assert that the sample `KnittingProject` is gone, `NavigationStack` and project/counter `ForEach` exist, the counter row has tap and long-press/confirmation actions, completed rows are disabled, pending/error text is visible, and each of these keys has non-empty `en` and `zh-Hant` values:

```text
watch.projects.title
watch.projects.empty
watch.project.completed
watch.sync.pending
watch.sync.error.projectCompleted
watch.sync.error.projectMissing
watch.sync.error.counterMissing
watch.sync.error.unsupportedSchema
watch.sync.error.storageFailure
watch.counter.incrementHint
watch.counter.actions
watch.counter.decrement
watch.counter.reset
watch.counter.cancel
```

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter WatchCounterViewContractTests && swift test --filter LocalizationContractTests`

Expected: FAIL on sample UI and missing keys.

- [ ] **Step 3: Implement the compact two-level UI**

Use active-before-completed snapshot order. Each counter row shows full name (two lines allowed), large value, pending icon plus text when relevant, and a completed lock indicator. Provide accessibility label containing project, counter, and value; `.accessibilityAction(named:)` for increment/decrement/reset; and at least 44-point interactive rows. Do not rely on color alone.

- [ ] **Step 4: Add exact bilingual strings and build**

Traditional Chinese examples: `待同步`, `減 1`, `歸零`, `作品已完成，計數器僅供查看`. English examples: `Waiting to sync`, `Decrease by 1`, `Reset to zero`, `Completed project; counters are read-only`.

Run: `swift test && xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and build exit 0.

- [ ] **Step 5: Commit the Watch experience**

```bash
git add KnitNoteWatch Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m "feat: present six project counters on Watch"
```

### Task 8: Package the Watch app as the iOS companion

**Files:**
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Create: `Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift`

**Interfaces:**
- Main iOS target embeds/associates `KnitNoteWatch`; macOS destination must not attempt to embed it.
- Watch Info contains `WKCompanionAppBundleIdentifier = com.phillon.KnitNote`.

- [ ] **Step 1: Write a failing packaging contract**

Assert `project.yml` contains the companion key and an iOS-filtered target dependency, and after generation use `xcodebuild -showBuildSettings`/project text to confirm the Watch product is in the iOS embed phase but not the macOS product.

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter WatchPackagingContractTests`

Expected: FAIL because the current targets are independent.

- [ ] **Step 3: Add the companion association in XcodeGen**

Use the XcodeGen 2.45.4 dependency form verified by `xcodegen dump`:

```yaml
targets:
  KnitNote:
    dependencies:
      - target: KnitNoteWatch
        embed: true
        platformFilter: iOS
  KnitNoteWatch:
    info:
      path: KnitNoteWatch/Info.plist
      properties:
        CFBundleDisplayName: KnitNote
        WKCompanionAppBundleIdentifier: com.phillon.KnitNote
```

Before replacing generated project state, run `xcodegen dump --spec project.yml --type json` and confirm the KnitNote dependency contains `"platformFilter":"iOS"`. Then run `xcodegen generate`; the generated `PBXBuildFile` for `KnitNoteWatch.app in Embed Watch Content` must contain `platformFilter = ios`.

- [ ] **Step 4: Verify all destinations**

Run:

```bash
swift test
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -configuration Release -archivePath /tmp/KnitNote-WatchCheck.xcarchive archive
```

Expected: tests/builds pass; archive exits 0. Verify the archive with:

```bash
find /tmp/KnitNote-WatchCheck.xcarchive/Products -name '*.app' -maxdepth 8 -print
plutil -p /tmp/KnitNote-WatchCheck.xcarchive/Products/Applications/KnitNote.app/Watch/KnitNoteWatch.app/Info.plist
```

Expected: embedded Watch app exists, bundle ID is `com.phillon.KnitNote.watch`, companion ID is `com.phillon.KnitNote`, and version/build match the iOS archive.

- [ ] **Step 5: Commit packaging**

```bash
git add project.yml KnitNoteWatch/Info.plist KnitNote.xcodeproj/project.pbxproj Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift
git commit -m "build: package Watch as KnitNote companion"
```

### Task 9: Perform end-to-end Watch release verification

**Files:**
- Create: `AppStore/Verification/WatchSyncVerification.md`
- Modify: `AppStore/AppStoreSubmission.md`

**Interfaces:**
- Produces dated automated and physical-device evidence for the App Store release plan.

- [ ] **Step 1: Record automated evidence**

Run the full suite and five clean release destinations from the release specification. Paste command, date, Xcode version, OS/runtime, and exit status into `WatchSyncVerification.md`; do not write “passed” without captured command output.

- [ ] **Step 2: Exercise a physical paired iPhone and Watch**

Check: initial snapshot, immediate +1, iPhone rename reflected on Watch, all six counters, long-name wrapping, decrement/reset, Airplane Mode ordered queue, reconnect, duplicate delivery, force-quit with pending queue, completion rejection, resumption, and VoiceOver actions. Record device models/OS versions and each observed result.

- [ ] **Step 3: Inspect the signed archive and upload validation**

Create the Release archive in Xcode Organizer, run Validate App, and record all validation messages. Any signing, Watch packaging, localization, icon, or privacy warning blocks this task.

- [ ] **Step 4: Run final regression and commit evidence**

Run: `swift test && git diff --check`

Expected: PASS and no whitespace errors.

```bash
git add AppStore/Verification/WatchSyncVerification.md AppStore/AppStoreSubmission.md
git commit -m "docs: verify Watch companion release"
```

## Spec Coverage Checklist

- Protocol/version/six-counter invariants: Tasks 1–2.
- iPhone authority, ordering, rejection, exactly-once effects: Task 2.
- Watch cache, durable queue, dedup ledger, corruption behavior: Tasks 3 and 6.
- Application context, immediate messages, and background transfers: Tasks 4–6.
- Optimistic offline behavior and authoritative reconciliation: Task 6.
- Two-level UI, completion rules, localization, accessibility: Task 7.
- Companion bundle association and archive validation: Task 8.
- Real-device and end-to-end release evidence: Task 9.
- Explicit exclusions remain absent from every task.
