# Trial, Lifetime Unlock, and Watch Entitlement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert KnitNote to a seven-day full trial with a non-consumable lifetime unlock, grandfather paid owners through version 1.2.0, enforce read-only mode across every mutation path, and mirror entitlement to Apple Watch.

**Architecture:** Pure entitlement and access-policy types live in `KnitNoteCore`; Keychain and StoreKit adapters live in the main app behind protocols. `EntitlementCoordinator` publishes one verified snapshot and supplies a synchronous mutation authorizer to `JSONProjectStore`. The iPhone adds that snapshot to the existing WatchConnectivity protocol, while the Share Extension reads a minimal App Group projection and the main app remains authoritative.

**Tech Stack:** Swift 6, SwiftUI, StoreKit 2, Security/Keychain, WatchConnectivity, Swift Testing, XcodeGen, StoreKit Configuration

## Global Constraints

- Deployment targets remain iOS 18.0, macOS 15.0, and watchOS 11.0.
- Lifetime product identifier is `com.phillon.KnitNote.lifetimeUnlock`.
- The final paid-app version boundary is `1.2.0`; only Apple-verified `AppTransaction` data can grandfather a paid owner.
- Trial duration is exactly 7 × 24 hours from the first successful project creation or pattern import.
- Trial is per device and stored in Keychain; no developer account, server, analytics, ads, or subscription.
- Trial expiry preserves all user data and permits reading and complete backup, purchase, restore, and code redemption.
- StoreKit verified entitlement is authoritative; a local Boolean must never permanently unlock the app.
- iPhone is authoritative for Apple Watch entitlement; Watch retains the last valid snapshot while disconnected.
- Traditional Chinese and English are required for all new visible strings and VoiceOver text.
- Preserve user-owned untracked `.superpowers/brainstorm/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/`.

---

### Task 1: Entitlement Domain Model and Access Policy

**Files:**
- Create: `Sources/KnitNoteCore/Entitlements/EntitlementSnapshot.swift`
- Create: `Sources/KnitNoteCore/Entitlements/FeatureAccessPolicy.swift`
- Test: `Tests/KnitNoteCoreTests/EntitlementSnapshotTests.swift`
- Test: `Tests/KnitNoteCoreTests/FeatureAccessPolicyTests.swift`

**Interfaces:**
- Produces: `EntitlementSnapshot`, `EntitlementState`, `FeatureMutation`, `FeatureAccessDecision`, and `FeatureAccessPolicy.decision(for:snapshot:)`.
- Consumes: `Date` supplied by callers; domain code must not call `Date.now`.

- [ ] **Step 1: Write failing entitlement boundary tests**

```swift
@Test func activeTrialExpiresAtExactBoundary() {
    let expiry = Date(timeIntervalSince1970: 700)
    #expect(EntitlementSnapshot.trial(startedAt: .init(timeIntervalSince1970: 100), expiresAt: expiry)
        .state(at: expiry.addingTimeInterval(-0.001)) == .trialActive(expiresAt: expiry))
    #expect(EntitlementSnapshot.trial(startedAt: .init(timeIntervalSince1970: 100), expiresAt: expiry)
        .state(at: expiry) == .trialExpired)
}

@Test func permanentAndLegacyNeverExpire() {
    #expect(EntitlementSnapshot.permanentlyUnlocked.state(at: .distantFuture) == .permanentlyUnlocked)
    #expect(EntitlementSnapshot.legacyPaidOwner.state(at: .distantFuture) == .legacyPaidOwner)
}
```

- [ ] **Step 2: Run the new tests and confirm missing-type failures**

Run: `swift test --filter EntitlementSnapshotTests`

Expected: FAIL because `EntitlementSnapshot` does not exist.

- [ ] **Step 3: Implement the immutable snapshot and explicit clock input**

```swift
public enum EntitlementState: Equatable, Sendable {
    case trialNotStarted
    case trialActive(expiresAt: Date)
    case trialExpired
    case permanentlyUnlocked
    case legacyPaidOwner
}

public enum EntitlementSnapshot: Equatable, Codable, Sendable {
    case trialNotStarted
    case trial(startedAt: Date, expiresAt: Date)
    case permanentlyUnlocked
    case legacyPaidOwner

    public func state(at now: Date) -> EntitlementState {
        switch self {
        case .trialNotStarted: .trialNotStarted
        case let .trial(_, expiresAt):
            now < expiresAt ? .trialActive(expiresAt: expiresAt) : .trialExpired
        case .permanentlyUnlocked: .permanentlyUnlocked
        case .legacyPaidOwner: .legacyPaidOwner
        }
    }
}
```

- [ ] **Step 4: Write failing policy tests for every mutation family**

```swift
@Test(arguments: FeatureMutation.allCases)
func expiredTrialRejectsEveryMutation(_ mutation: FeatureMutation) {
    #expect(FeatureAccessPolicy.decision(
        for: mutation,
        snapshot: .trial(startedAt: .distantPast, expiresAt: .distantPast),
        now: .now
    ) == .requiresUnlock)
}

@Test func firstMeaningfulActionsStartTrial() {
    #expect(FeatureAccessPolicy.decision(for: .createProject, snapshot: .trialNotStarted, now: .now) == .startTrial)
    #expect(FeatureAccessPolicy.decision(for: .importPattern, snapshot: .trialNotStarted, now: .now) == .startTrial)
}
```

- [ ] **Step 5: Implement complete mutation coverage**

```swift
public enum FeatureMutation: String, CaseIterable, Codable, Sendable {
    case createProject, editProject, deleteProject, completeProject, resumeProject
    case changeCounter, editNote, editJournal
    case importPattern, editPattern, linkPattern, editPatternReadingState
    case createYarn, editYarn, deleteYarn, linkYarn, scanYarnLabel
}

public enum FeatureAccessDecision: Equatable, Sendable {
    case allow
    case startTrial
    case requiresUnlock
}

public enum FeatureAccessPolicy {
    public static func decision(
        for mutation: FeatureMutation,
        snapshot: EntitlementSnapshot,
        now: Date
    ) -> FeatureAccessDecision {
        switch snapshot.state(at: now) {
        case .trialNotStarted:
            mutation == .createProject || mutation == .importPattern ? .startTrial : .allow
        case .trialActive, .permanentlyUnlocked, .legacyPaidOwner:
            .allow
        case .trialExpired:
            .requiresUnlock
        }
    }
}
```

- [ ] **Step 6: Run domain tests**

Run: `swift test --filter Entitlement`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnitNoteCore/Entitlements Tests/KnitNoteCoreTests/EntitlementSnapshotTests.swift Tests/KnitNoteCoreTests/FeatureAccessPolicyTests.swift
git commit -m "feat: add entitlement access policy"
```

### Task 2: Keychain Trial Persistence

**Files:**
- Create: `Sources/KnitNoteCore/Entitlements/TrialRecord.swift`
- Create: `KnitNote/Entitlements/KeychainTrialStore.swift`
- Test: `Tests/KnitNoteCoreTests/TrialRecordTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `EntitlementSnapshot.trial(startedAt:expiresAt:)`.
- Produces: core `TrialStore.load()`, `TrialStore.startIfNeeded(now:)`, and `TrialRecord`; app `KeychainTrialStore`.

- [ ] **Step 1: Write failing deterministic record tests**

```swift
@Test func recordUsesExactlySevenDays() {
    let now = Date(timeIntervalSince1970: 1_000)
    let record = TrialRecord(startedAt: now)
    #expect(record.expiresAt == now.addingTimeInterval(7 * 24 * 60 * 60))
}

@Test func existingRecordIsNeverRestarted() throws {
    let existing = TrialRecord(startedAt: .init(timeIntervalSince1970: 1_000))
    let store = InMemoryTrialStore(record: existing)
    #expect(try store.startIfNeeded(now: .init(timeIntervalSince1970: 9_000)) == existing)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter TrialRecordTests`

Expected: FAIL because `TrialRecord` is missing.

- [ ] **Step 3: Implement record, protocol, and injectable memory store in app test support**

```swift
struct TrialRecord: Codable, Equatable, Sendable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60
    let version = 1
    let startedAt: Date
    var expiresAt: Date { startedAt.addingTimeInterval(Self.duration) }
}

protocol TrialStore: Sendable {
    func load() throws -> TrialRecord?
    func startIfNeeded(now: Date) throws -> TrialRecord
}
```

- [ ] **Step 4: Implement Keychain storage**

Use service `com.phillon.KnitNote.trial`, account `trial-record-v1`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, JSON with millisecond dates, and `SecItemAdd` with duplicate fallback to a fresh read. Never overwrite an existing valid start time.

- [ ] **Step 5: Add app source membership and run tests/build**

Run: `xcodegen generate && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/entitlement-keychain CODE_SIGNING_ALLOWED=NO build`

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/Entitlements/TrialRecord.swift KnitNote/Entitlements project.yml Tests/KnitNoteCoreTests/TrialRecordTests.swift KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: persist device trial in keychain"
```

### Task 3: StoreKit Purchase and Legacy Paid-Owner Verification

**Files:**
- Create: `KnitNote/Entitlements/PurchaseService.swift`
- Create: `KnitNote/Entitlements/StoreKitPurchaseService.swift`
- Create: `Sources/KnitNoteCore/Entitlements/LegacyPaidVersionPolicy.swift`
- Create: `KnitNote/StoreKit/KnitNote.storekit`
- Test: `Tests/KnitNoteCoreTests/LegacyPaidVersionPolicyTests.swift`
- Test: `Tests/KnitNoteCoreTests/PurchasePresentationTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: `PurchaseService.currentQualification() async`, `purchaseLifetime() async`, `restore() async`, `PurchaseQualification`, and `LegacyPaidVersionPolicy`.
- Consumes: product ID `com.phillon.KnitNote.lifetimeUnlock`.

- [ ] **Step 1: Write failing paid-version boundary tests**

```swift
@Test(arguments: ["1.0", "1.1.9", "1.2.0"])
func paidVersionsAreGrandfathered(_ version: String) {
    #expect(LegacyPaidVersionPolicy(maximumPaidVersion: "1.2.0").qualifies(originalAppVersion: version))
}

@Test(arguments: ["1.2.1", "1.3", "2.0"])
func freeVersionsAreNotGrandfathered(_ version: String) {
    #expect(!LegacyPaidVersionPolicy(maximumPaidVersion: "1.2.0").qualifies(originalAppVersion: version))
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter LegacyPaidVersionPolicyTests`

Expected: FAIL because the policy is missing.

- [ ] **Step 3: Implement numeric version comparison**

Parse dot-separated numeric components, pad missing components with zero, reject empty/non-numeric/negative components, and compare lexicographically. Do not compare version strings alphabetically.

- [ ] **Step 4: Define purchase protocol and result types**

```swift
enum PurchaseQualification: Equatable {
    case none
    case lifetime
    case legacyPaidOwner
}

enum PurchaseOutcome: Equatable {
    case purchased
    case pending
    case cancelled
}

@MainActor protocol PurchaseService {
    var localizedLifetimePrice: String? { get }
    func prepare() async
    func currentQualification() async -> PurchaseQualification
    func purchaseLifetime() async throws -> PurchaseOutcome
    func restore() async throws -> PurchaseQualification
}
```

- [ ] **Step 5: Implement StoreKit 2 adapter**

Fetch exactly the configured product; accept only verified non-consumable current entitlements. Verify `AppTransaction.shared`, pass its verified `originalAppVersion` to `LegacyPaidVersionPolicy(maximumPaidVersion: "1.2.0")`, call `AppStore.sync()` only from explicit restore, and listen to `Transaction.updates` while the app runs.

- [ ] **Step 6: Add StoreKit test configuration**

Define one non-consumable product named “Lifetime Unlock” with identifier `com.phillon.KnitNote.lifetimeUnlock`; attach the configuration to the KnitNote run scheme but never use it as production entitlement truth.

- [ ] **Step 7: Run focused tests and unsigned iOS/macOS builds**

Run: `swift test --filter LegacyPaidVersionPolicyTests`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/storekit-ios CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -derivedDataPath .derived-data/storekit-mac CODE_SIGNING_ALLOWED=NO build`

Expected: tests pass and both builds succeed.

- [ ] **Step 8: Commit**

```bash
git add Sources/KnitNoteCore/Entitlements/LegacyPaidVersionPolicy.swift KnitNote/Entitlements KnitNote/StoreKit project.yml KnitNote.xcodeproj Tests/KnitNoteCoreTests/LegacyPaidVersionPolicyTests.swift Tests/KnitNoteCoreTests/PurchasePresentationTests.swift
git commit -m "feat: verify lifetime and legacy purchases"
```

### Task 4: Entitlement Coordinator and Store Mutation Gate

**Files:**
- Create: `KnitNote/Entitlements/EntitlementCoordinator.swift`
- Create: `Sources/KnitNoteCore/Entitlements/EntitlementResolver.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:430-1520`
- Modify: `KnitNote/App/KnitNoteApp.swift:3-70`
- Test: `Tests/KnitNoteCoreTests/JSONProjectStoreEntitlementTests.swift`
- Test: `Tests/KnitNoteCoreTests/EntitlementResolverTests.swift`
- Test: `Tests/KnitNoteCoreTests/EntitlementCoordinatorSourceContractTests.swift`

**Interfaces:**
- Produces: core `EntitlementResolver`, `MutationAuthorizer = @MainActor (FeatureMutation) -> FeatureAccessDecision`, app `EntitlementCoordinator.authorize(_:)`, and `EntitlementCoordinator.unlockRequest`.
- Consumes: `TrialStore`, `PurchaseService`, and `FeatureAccessPolicy`.

- [ ] **Step 1: Write failing store-boundary tests**

```swift
@Test func expiredStoreCannotMutateThroughPublicAPIs() throws {
    let store = try makeStore(authorize: { _ in .requiresUnlock })
    #expect(throws: ProjectStoreError.accessRestricted) { try store.add(name: "Blocked") }
    #expect(throws: ProjectStoreError.accessRestricted) {
        try store.incrementCounter(projectID: fixtureProject.id, counterID: fixtureProject.counters[0].id)
    }
    #expect(throws: ProjectStoreError.accessRestricted) { try store.addYarn(try StoredYarn(name: "Blocked")) }
}
```

- [ ] **Step 2: Run and verify the store currently mutates**

Run: `swift test --filter JSONProjectStoreEntitlementTests`

Expected: FAIL because the authorizer and `.accessRestricted` do not exist.

- [ ] **Step 3: Inject and enforce the mutation authorizer**

Add a default-allow authorizer for existing tests and screenshot fixtures:

```swift
public typealias MutationAuthorizer = @MainActor (FeatureMutation) -> FeatureAccessDecision

private let authorizeMutation: MutationAuthorizer

private func requireAccess(_ mutation: FeatureMutation) throws {
    guard authorizeMutation(mutation) != .requiresUnlock else {
        throw ProjectStoreError.accessRestricted
    }
}
```

Call `requireAccess` at every public mutation entry point before file writes, including project, counter, note, journal, pattern/library/reader markup, yarn, backup restore, and Watch command application. Backup export and all reads remain allowed. Add a source-contract test listing every public mutator so a later API cannot silently omit the gate.

- [ ] **Step 4: Write failing resolver and coordinator contract tests**

```swift
@Test func purchaseQualificationWinsOverExpiredTrial() {
    let resolver = EntitlementResolver()
    #expect(resolver.resolve(
        purchase: .lifetime,
        trial: TrialRecord(startedAt: .distantPast),
        now: .now
    ) == .permanentlyUnlocked)
}

@Test func expiredTrialRequiresUnlock() {
    let resolver = EntitlementResolver()
    let snapshot = resolver.resolve(purchase: .none, trial: TrialRecord(startedAt: .distantPast), now: .now)
    #expect(FeatureAccessPolicy.decision(for: .changeCounter, snapshot: snapshot, now: .now) == .requiresUnlock)
}
```

- [ ] **Step 5: Implement pure resolver and app coordinator**

`EntitlementResolver.resolve(purchase:trial:now:)` applies the tested precedence: lifetime, legacy paid, existing trial, not started. The app coordinator calls it on prepare. On `.startTrial`, atomically create the Keychain record, publish `.trial`, and return `.allow` so the triggering operation completes. On `.requiresUnlock`, publish the requested mutation and return it unchanged. The source-contract test verifies that `EntitlementCoordinator` calls `TrialStore.startIfNeeded`, republishes the snapshot, and exposes `unlockRequest`.

- [ ] **Step 6: Inject coordinator into live store and SwiftUI environment**

Construct `EntitlementCoordinator` before `JSONProjectStore` in `KnitNoteApp`, pass `{ coordinator.authorize($0) }` to `JSONProjectStore.live`, and expose both objects to the view tree. Screenshot mode uses `.legacyPaidOwner` without touching StoreKit or Keychain.

- [ ] **Step 7: Run focused and full core tests**

Run: `swift test --filter Entitlement`

Run: `swift test --filter JSONProjectStoreEntitlementTests`

Run: `swift test`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/KnitNoteCore/Entitlements/EntitlementResolver.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift KnitNote/Entitlements KnitNote/App/KnitNoteApp.swift Tests/KnitNoteCoreTests
git commit -m "feat: enforce entitlement at store boundary"
```

### Task 5: Trial Pill, Unlock Sheet, Restore, and Redeem

**Files:**
- Create: `KnitNote/Entitlements/TrialStatusPill.swift`
- Create: `KnitNote/Entitlements/UnlockSheet.swift`
- Create: `Sources/KnitNoteCore/Entitlements/UnlockPresentation.swift`
- Modify: `KnitNote/App/RootView.swift:30-150`
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/UnlockPresentationTests.swift`
- Test: `Tests/KnitNoteCoreTests/UnlockViewContractTests.swift`

**Interfaces:**
- Consumes: coordinator snapshot, localized StoreKit price, purchase/restore methods, and `unlockRequest`.
- Produces: quiet trial status pill and one central unlock sheet.

- [ ] **Step 1: Write failing presentation tests**

```swift
@Test func trialPillUsesCalendarSafeRemainingDays() {
    let expiry = Date(timeIntervalSince1970: 200_000)
    #expect(UnlockPresentation.remainingDays(now: expiry.addingTimeInterval(-86_400), expiresAt: expiry) == 1)
    #expect(UnlockPresentation.remainingDays(now: expiry.addingTimeInterval(-1), expiresAt: expiry) == 1)
}

@Test func expiredCopyPromisesDataRetention() {
    #expect(UnlockPresentation.expiredMessageKey == "unlock.expired.dataRetained")
}
```

- [ ] **Step 2: Run and verify failure**

Run: `swift test --filter UnlockPresentationTests`

Expected: FAIL because presentation types are missing.

- [ ] **Step 3: Implement presentation logic and localized strings**

Use `max(1, Int(ceil((expiresAt.timeIntervalSince(now)) / 86_400)))` for the compact day count. Add Traditional Chinese and English strings for trial state, data retention, lifetime unlock, pending, cancellation-neutral state, restore, redeem, retry, read-only, Watch guidance, and VoiceOver labels.

- [ ] **Step 4: Implement the quiet pill and central sheet**

Show the pill only on the projects home while the trial is active. Present the sheet from `RootView` when the pill is tapped or coordinator publishes a blocked mutation. Price must come from `Product.displayPrice`; disable duplicate purchase taps while busy.

- [ ] **Step 5: Wire purchase, restore, and redemption**

Purchase calls `purchaseLifetime()`. Restore calls `restore()`. Redeem uses StoreKit’s code-redemption sheet on supported Apple platforms and shows a platform-appropriate explanation when unavailable. Successful qualification refreshes coordinator state and dismisses the sheet.

- [ ] **Step 6: Run contract tests and iPhone/iPad UI smoke builds**

Run: `swift test --filter Unlock`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/unlock-ui CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnitNoteCore/Entitlements/UnlockPresentation.swift KnitNote/Entitlements KnitNote/App/RootView.swift KnitNote/Projects/ProjectsView.swift KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests
git commit -m "feat: add trial and lifetime unlock interface"
```

### Task 6: Share Extension Read-Only Projection

**Files:**
- Create: `Sources/KnitNoteCore/Entitlements/EntitlementProjection.swift`
- Create: `KnitNote/Entitlements/EntitlementProjectionWriter.swift`
- Create: `KnitNoteShare/EntitlementProjectionReader.swift`
- Modify: `KnitNoteShare/ShareImportController.swift:61-210`
- Modify: `KnitNoteShare/ShareImportView.swift`
- Modify: `KnitNoteShare/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/EntitlementProjectionTests.swift`
- Test: `Tests/KnitNoteCoreTests/ShareExtensionEntitlementContractTests.swift`

**Interfaces:**
- Produces: versioned `EntitlementProjection` in the existing App Group and `canAcceptImport(now:)`.
- Consumes: coordinator updates from the main app.

- [ ] **Step 1: Write failing projection tests**

```swift
@Test func expiredProjectionRejectsShareImport() {
    let projection = EntitlementProjection(schemaVersion: 1, state: .trial, expiresAt: .distantPast, generatedAt: .now)
    #expect(!projection.canAcceptImport(now: .now))
}

@Test func absentProjectionAllowsStagingForFirstTrialStart() {
    #expect(EntitlementProjection.canAcceptImport(nil, now: .now))
}
```

- [ ] **Step 2: Implement atomic App Group projection**

Projection contains only schema version, `trialNotStarted/trial/permanentlyUnlocked/legacyPaidOwner`, optional expiry, and generation date. Main app writes atomically whenever entitlement changes. Share Extension treats missing projection as first-use eligible, verified expired as blocked, and malformed/unsupported data as blocked with “Open KnitNote to continue.”

- [ ] **Step 3: Gate extension before loading provider bytes**

Check projection before `NSItemProvider.loadFileRepresentation`. If blocked, do not enqueue a file; show localized data-retained/unlock guidance and an “Open KnitNote” action. The main app store gate still authorizes inbox publication and starts the first trial when appropriate.

- [ ] **Step 4: Run tests and extension build**

Run: `swift test --filter EntitlementProjectionTests`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteShare -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-data/share-entitlement CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KnitNoteCore/Entitlements KnitNote/Entitlements KnitNoteShare Tests/KnitNoteCoreTests
git commit -m "feat: enforce trial state in share extension"
```

### Task 7: Apple Watch Entitlement Snapshot and Command Enforcement

**Files:**
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSyncModels.swift`
- Modify: `Sources/KnitNoteCore/WatchSync/WatchSnapshotBuilder.swift`
- Modify: `Sources/KnitNoteCore/Projects/JSONProjectStore.swift:844-890`
- Modify: `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift`
- Modify: `KnitNoteWatch/Sync/WatchSyncCoordinator.swift`
- Modify: `KnitNoteWatch/ProjectCountersView.swift`
- Modify: `KnitNoteWatch/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/WatchEntitlementSnapshotTests.swift`
- Test: `Tests/KnitNoteCoreTests/WatchCommandApplicationTests.swift`
- Test: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`

**Interfaces:**
- Produces: `WatchEntitlementSnapshot`, Watch read-only presentation, and `.entitlementRequired` command rejection.
- Consumes: iPhone `EntitlementSnapshot` and existing Watch snapshot/command queue.

- [ ] **Step 1: Write failing Watch snapshot tests**

```swift
@Test func watchSnapshotRoundTripsTrialExpiry() throws {
    let entitlement = WatchEntitlementSnapshot(kind: .trial, expiresAt: .init(timeIntervalSince1970: 10_000), generatedAt: .init(timeIntervalSince1970: 1_000))
    let decoded = try WatchSyncCodec.decode(WatchEntitlementSnapshot.self, from: WatchSyncCodec.encode(entitlement))
    #expect(decoded == entitlement)
}

@Test func expiredIPhoneRejectsWatchMutation() throws {
    let result = try store.applyWatchCommand(command, entitlement: .trial(startedAt: .distantPast, expiresAt: .distantPast), now: .now)
    #expect(result.rejection == .entitlementRequired)
}
```

- [ ] **Step 2: Bump Watch snapshot schema and implement backward rejection**

Add entitlement to `WatchSyncSnapshot`, bump `currentSchemaVersion` from 1 to 2, and ensure schema 1 is rejected cleanly so the Watch requests a fresh snapshot rather than assuming write access.

- [ ] **Step 3: Enforce on iPhone before applying commands**

Add `.entitlementRequired` to `WatchCommandRejection`; call `FeatureAccessPolicy` at the authoritative iPhone command boundary before deduplication publishes a mutation. A rejected command is acknowledged and removed from Watch queue without changing counters.

- [ ] **Step 4: Implement offline presentation**

Watch stores the last entitlement with its snapshot. It allows commands while disconnected only when the last snapshot was active/unlocked, preserving the approved generous offline behavior. After a newer iPhone snapshot reports expired, controls become read-only and show localized “Unlock on iPhone.”

- [ ] **Step 5: Run Watch tests and build**

Run: `swift test --filter Watch`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath .derived-data/watch-entitlement CODE_SIGNING_ALLOWED=NO build`

Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KnitNoteCore/WatchSync Sources/KnitNoteCore/Projects/JSONProjectStore.swift KnitNote/WatchSync KnitNoteWatch Tests/KnitNoteCoreTests
git commit -m "feat: sync unlock state to apple watch"
```

### Task 8: App Store Metadata, Submission Configuration, and Full Verification

**Files:**
- Modify: `AppStore/Metadata/en-US.md`
- Modify: `AppStore/Metadata/zh-Hant.md`
- Modify: `AppStore/AppStoreSubmission.md`
- Modify: `AppStore/Screenshots/capture.sh`
- Modify: `project.yml`
- Test: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`
- Test: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`

**Interfaces:**
- Consumes: approved Watch-first positioning and lifetime product ID.
- Produces: submission-ready metadata/checklist and verified Release artifacts.

- [ ] **Step 1: Write failing metadata/release contract tests**

Assert the en-US name is `KnitNote: Row Counter & PDF`, subtitle is `Knitting with Apple Watch`, promotional copy contains `7 days`, `Apple Watch`, and `one purchase`, the product ID is present in submission docs, and screenshot fixtures include a Watch-first scene.

- [ ] **Step 2: Update metadata and screenshot order**

Use the approved six-image order. Avoid repeating name/subtitle words in keywords; retain `crochet`, `pattern`, `gauge`, `yarn`, `stitch`, `needle`, `hook`, `journal`, `tracker`, `craft`, and `sweater` within App Store limits.

- [ ] **Step 3: Add submission checklist**

Document: create the non-consumable IAP, attach its review screenshot, submit the first IAP with the new app version, configure US$2.99 launch pricing then US$4.99, create 20 free codes, validate legacy owner behavior, and verify the free app price before release.

- [ ] **Step 4: Run all automated verification**

Run: `swift test`

Run: `xcodegen generate`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -configuration Release -derivedDataPath .derived-data/release-ios CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=macOS' -configuration Release -derivedDataPath .derived-data/release-mac CODE_SIGNING_ALLOWED=NO build`

Run: `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS' -configuration Release -derivedDataPath .derived-data/release-watch CODE_SIGNING_ALLOWED=NO build`

Expected: all tests pass and all three Release builds succeed.

- [ ] **Step 5: Perform manual StoreKit and physical-device acceptance**

On a fresh iPhone/iPad/Mac and paired Watch verify: browsing does not start trial; first project/pattern does; expiry is read-only; backup remains available; sandbox purchase unlocks all devices; restore after reinstall works; a legacy paid build upgrades without paywall; Watch offline commands reconcile; Share Extension blocks after confirmed expiry. Record exact device/OS/build evidence in `AppStore/AppStoreSubmission.md`.

- [ ] **Step 6: Commit**

```bash
git add AppStore project.yml KnitNote.xcodeproj Tests/KnitNoteCoreTests
git commit -m "docs: prepare lifetime unlock release"
```

### Task 9: Final Review Gate

**Files:**
- Review only: all files changed by Tasks 1–8

**Interfaces:**
- Consumes: completed commits and verification evidence.
- Produces: a reviewed branch ready for an explicit integration decision.

- [ ] **Step 1: Run diff hygiene**

Run: `git diff --check main...HEAD`

Expected: no output.

- [ ] **Step 2: Confirm only intended files are tracked**

Run: `git status --short && git diff --stat main...HEAD`

Expected: only the preserved pre-existing untracked directories remain outside the task diff.

- [ ] **Step 3: Request two-stage review**

Use `superpowers:requesting-code-review` for specification compliance first and code quality second. Fix every confirmed finding with a focused test and commit.

- [ ] **Step 4: Re-run the complete verification matrix**

Repeat Task 8 Step 4 and confirm current output, not cached historical results.

- [ ] **Step 5: Stop for integration choice**

Use `superpowers:finishing-a-development-branch`. Do not merge, push, create a PR, change App Store pricing, or submit for review without the user’s explicit choice.
