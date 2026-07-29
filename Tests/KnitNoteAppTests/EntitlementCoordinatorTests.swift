import Combine
import Foundation
import Security
import Testing
@testable import KnitNote

@Suite struct EntitlementCoordinatorTests {
    @Test func projectionWriterRoundTripsAnAtomicProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EntitlementProjectionWriterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(
            EntitlementProjection.fileName,
            isDirectory: false
        )
        let generatedAt = Date(timeIntervalSince1970: 2_000_000)
        let writer = EntitlementProjectionWriter(fileURL: fileURL)

        try writer.write(
            snapshot: .permanentlyUnlocked,
            generatedAt: generatedAt
        )

        let projection = try JSONDecoder().decode(
            EntitlementProjection.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(projection == EntitlementProjection(
            state: .permanentlyUnlocked,
            expiresAt: nil,
            generatedAt: generatedAt
        ))
    }

    @Test @MainActor func preparedSnapshotPublishesProjectionUpdate() async {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000)
        var updates: [(EntitlementSnapshot, Date)] = []
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .lifetime),
            trialStore: TrialStoreSpy(loadedRecord: nil),
            now: { generatedAt },
            onSnapshotChange: { updates.append(($0, $1)) }
        )

        await coordinator.prepare()

        #expect(updates.count == 1)
        #expect(updates.first?.0 == .permanentlyUnlocked)
        #expect(updates.first?.1 == generatedAt)
    }

    @Test @MainActor func trialStartDecisionCommitsBeforeStoreMutation() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var updates: [(EntitlementSnapshot, Date)] = []
        let trialStore = TrialStoreSpy(
            loadedRecord: nil,
            startedRecord: TrialRecord(startedAt: now)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: trialStore,
            now: { now },
            onSnapshotChange: { updates.append(($0, $1)) }
        )
        await coordinator.prepare()
        updates.removeAll()

        let preflight = coordinator.authorize(.createProject)

        #expect(preflight == .startTrial)
        #expect(trialStore.startCallDates.isEmpty)
        #expect(coordinator.snapshot == .trialNotStarted)
        #expect(updates.isEmpty)

        let commit = coordinator.commitSuccessfulMutation(.createProject)

        #expect(commit == .allow)
        #expect(trialStore.startCallDates == [now])
        #expect(updates.count == 1)
        #expect(
            updates.first?.0 == .trial(
                startedAt: now,
                expiresAt: now.addingTimeInterval(TrialRecord.duration)
            )
        )
        #expect(updates.first?.1 == now)

        #expect(coordinator.commitSuccessfulMutation(.importPattern) == .allow)
        #expect(trialStore.startCallDates == [now])
    }

    @Test @MainActor func ensurePreparedWaitsForTheCurrentQualificationFlight() async {
        let purchaseService = ControlledPurchaseService()
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: nil)
        )

        let ensured = Task { await coordinator.ensurePrepared() }
        await purchaseService.waitForQualificationCall(count: 1)

        #expect(purchaseService.prepareCallCount == 1)
        #expect(purchaseService.qualificationCallCount == 1)

        purchaseService.resumeNextQualification(returning: .none)

        #expect(await ensured.value)
        #expect(coordinator.snapshot == .trialNotStarted)
    }

    @Test @MainActor func ensurePreparedFailsClosedWhenPreparationFails() async {
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(
                loadedRecord: nil,
                loadError: TrialStoreSpy.Failure.load
            )
        )

        #expect(await coordinator.ensurePrepared() == false)
        #expect(coordinator.authorize(.importPattern) == .requiresUnlock)
    }

    @Test @MainActor func readerWritesRequireAPreparedNonExpiredEntitlement() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let unprepared = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(loadedRecord: nil),
            now: { now }
        )
        #expect(!unprepared.allowsWrites)
        #expect(!unprepared.allowsAutomaticReaderPersistence)

        await unprepared.prepare()
        #expect(unprepared.allowsWrites)
        #expect(unprepared.allowsAutomaticReaderPersistence)

        let expired = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(
                loadedRecord: TrialRecord(
                    startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
                )
            ),
            now: { now }
        )
        await expired.prepare()
        #expect(!expired.allowsWrites)
        #expect(!expired.allowsAutomaticReaderPersistence)

        let lifetime = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .lifetime),
            trialStore: TrialStoreSpy(loadedRecord: nil),
            now: { now }
        )
        await lifetime.prepare()
        #expect(lifetime.allowsWrites)
        #expect(lifetime.allowsAutomaticReaderPersistence)
    }

    @Test @MainActor func verifiedPurchaseTakesPrecedenceWithoutReadingTheTrialStore() async {
        let purchaseService = PurchaseServiceSpy(qualification: .lifetime)
        let trialStore = TrialStoreSpy(
            loadedRecord: TrialRecord(startedAt: Date(timeIntervalSince1970: 1))
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )

        await coordinator.prepare()

        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(purchaseService.prepareCallCount == 1)
        #expect(purchaseService.qualificationCallCount == 1)
        #expect(trialStore.loadCallCount == 0)
    }

    @Test @MainActor
    func overlappingPreparationSharesOneFlightAndLaterAuthoritativeRefreshRevokesLifetime() async {
        let purchaseService = ControlledPurchaseService()
        let trialStore = TrialStoreSpy(loadedRecord: nil)
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore,
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )

        let first = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 1)
        let secondCallerStarted = MainActorSignal()
        let second = Task {
            secondCallerStarted.signal()
            await coordinator.prepare()
        }
        await secondCallerStarted.wait()

        #expect(purchaseService.prepareCallCount == 1)
        #expect(purchaseService.qualificationCallCount == 1)

        purchaseService.resumeAllQualifications(returning: .lifetime)
        await first.value
        await second.value

        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(purchaseService.prepareCallCount == 1)
        #expect(purchaseService.qualificationCallCount == 1)
        #expect(trialStore.loadCallCount == 0)

        let qualificationCallsBeforeRefresh = purchaseService.qualificationCallCount
        let third = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(
            count: qualificationCallsBeforeRefresh + 1
        )
        purchaseService.resumeAllQualifications(returning: .none)
        await third.value

        #expect(purchaseService.prepareCallCount == 2)
        #expect(purchaseService.qualificationCallCount == 2)
        #expect(trialStore.loadCallCount == 1)
        #expect(coordinator.snapshot == .trialNotStarted)
    }

    @Test @MainActor func unavailableRefreshAfterLifetimePreservesVerifiedEntitlement() async {
        let purchaseService = ControlledPurchaseService()
        let trialStore = TrialStoreSpy(loadedRecord: nil)
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore
        )

        let initial = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 1)
        purchaseService.resumeAllQualifications(returning: .lifetime)
        await initial.value
        #expect(coordinator.snapshot == .permanentlyUnlocked)

        let refresh = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 2)
        purchaseService.resumeAllQualifications(returning: .unavailable)
        await refresh.value

        #expect(purchaseService.prepareCallCount == 2)
        #expect(purchaseService.qualificationCallCount == 2)
        #expect(trialStore.loadCallCount == 0)
        #expect(coordinator.verifiedSnapshot == .permanentlyUnlocked)
        #expect(
            coordinator.purchaseVerificationAvailability == .unavailable
        )
        #expect(coordinator.authorize(.changeCounter) == .allow)
        #expect(coordinator.unlockRequest == nil)
    }

    @Test @MainActor func unavailableRefreshAfterLegacyOwnerPreservesVerifiedEntitlement() async {
        let purchaseService = PurchaseServiceSpy(qualification: .legacyPaidOwner)
        let trialStore = TrialStoreSpy(loadedRecord: nil)
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore
        )
        await coordinator.prepare()
        purchaseService.qualification = .unavailable

        await coordinator.refreshEntitlement()

        #expect(trialStore.loadCallCount == 0)
        #expect(coordinator.verifiedSnapshot == .legacyPaidOwner)
        #expect(
            coordinator.purchaseVerificationAvailability == .unavailable
        )
        #expect(coordinator.authorize(.changeCounter) == .allow)
    }

    @Test @MainActor
    func unavailablePurchaseLookupStillPreparesTrialNotStarted() async {
        let trialStore = TrialStoreSpy(loadedRecord: nil)
        var projectedSnapshots: [EntitlementSnapshot] = []
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .unavailable),
            trialStore: trialStore,
            onSnapshotChange: { snapshot, _ in
                projectedSnapshots.append(snapshot)
            }
        )

        #expect(
            coordinator.purchaseVerificationAvailability == .unknown
        )

        await coordinator.prepare()

        #expect(coordinator.verifiedSnapshot == .trialNotStarted)
        #expect(coordinator.allowsWrites)
        #expect(trialStore.loadCallCount == 1)
        #expect(
            coordinator.purchaseVerificationAvailability == .unavailable
        )
        #expect(projectedSnapshots == [.trialNotStarted])
        #expect(!projectedSnapshots.contains(.permanentlyUnlocked))
        #expect(!projectedSnapshots.contains(.legacyPaidOwner))
    }

    @Test(arguments: [0.0, -TrialRecord.duration - 1])
    @MainActor
    func unavailablePurchaseLookupResolvesExistingTrialRecord(
        startedAtOffset: TimeInterval
    ) async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let record = TrialRecord(
            startedAt: now.addingTimeInterval(startedAtOffset)
        )
        let trialStore = TrialStoreSpy(loadedRecord: record)
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .unavailable),
            trialStore: trialStore,
            now: { now }
        )

        await coordinator.prepare()

        #expect(coordinator.verifiedSnapshot == .trial(
            startedAt: record.startedAt,
            expiresAt: record.expiresAt
        ))
        #expect(coordinator.verifiedSnapshot != .permanentlyUnlocked)
        #expect(coordinator.verifiedSnapshot != .legacyPaidOwner)
        #expect(trialStore.loadCallCount == 1)
    }

    @Test @MainActor
    func availablePurchaseLookupPublishesAvailableVerificationStatus() async {
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(loadedRecord: nil)
        )

        await coordinator.prepare()

        #expect(
            coordinator.purchaseVerificationAvailability == .available
        )
        #expect(coordinator.verifiedSnapshot == .trialNotStarted)
    }

    @Test @MainActor
    func firstProjectAfterInitialUnavailableDurablyStartsKeychainTrial()
        async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let keychain = InMemoryTrialKeychain()
        let trialStore = KeychainTrialStore(
            securityClient: keychain.client
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(
                qualification: .unavailable
            ),
            trialStore: trialStore,
            now: { now }
        )
        await coordinator.prepare()
        let fixture = try StoreFixture(
            authorize: { coordinator.authorize($0) },
            commit: { coordinator.commitSuccessfulMutation($0) }
        )
        defer { fixture.remove() }

        try fixture.store.add(name: "Offline first project")

        #expect(fixture.store.projects.count == 1)
        #expect(
            coordinator.purchaseVerificationAvailability == .unavailable
        )
        #expect(
            coordinator.snapshot == .trial(
                startedAt: now,
                expiresAt: now.addingTimeInterval(TrialRecord.duration)
            )
        )
        #expect(
            try KeychainTrialStore(securityClient: keychain.client).load()
                == TrialRecord(startedAt: now)
        )
    }

    @Test @MainActor func unpreparedCoordinatorBlocksDurableWatchCommandBeforeAnyWrite() throws {
        let purchaseService = PurchaseServiceSpy(qualification: .lifetime)
        let trialStore = TrialStoreSpy(loadedRecord: nil)
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore
        )
        let fixture = try DurableWatchStoreFixture(
            authorize: { coordinator.authorize($0) }
        )
        defer { fixture.remove() }
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)

        #expect(throws: ProjectStoreError.accessRestricted) {
            _ = try fixture.store.applyWatchCommandDurably(
                fixture.command,
                ledgerURL: fixture.ledgerURL,
                preparedCommandURL: fixture.preparedURL
            )
        }

        #expect(coordinator.unlockRequest == .changeCounter)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.preparedURL.path))
        #expect(purchaseService.prepareCallCount == 0)
        #expect(purchaseService.qualificationCallCount == 0)
        #expect(trialStore.loadCallCount == 0)
    }

    @Test @MainActor
    func expiredWatchCommandDoesNotPublishUnlockRequestOrWriteDurableState() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )
        await coordinator.prepare()
        let fixture = try DurableWatchStoreFixture(
            authorize: { coordinator.authorize($0) }
        )
        defer { fixture.remove() }
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)

        #expect(throws: ProjectStoreError.accessRestricted) {
            _ = try fixture.store.applyWatchCommandDurably(
                fixture.command,
                entitlement: coordinator.snapshot,
                ledgerURL: fixture.ledgerURL,
                preparedCommandURL: fixture.preparedURL,
                now: now
            )
        }

        #expect(coordinator.unlockRequest == nil)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.preparedURL.path))
    }

    @Test @MainActor func firstProjectCreationStartsTrialBeforeTheStorePublishes() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let purchaseService = PurchaseServiceSpy(qualification: .none)
        let trialStore = TrialStoreSpy(
            loadedRecord: nil,
            startedRecord: TrialRecord(startedAt: now)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore,
            now: { now }
        )
        await coordinator.prepare()
        let fixture = try StoreFixture(
            authorize: { coordinator.authorize($0) },
            commit: { coordinator.commitSuccessfulMutation($0) }
        )
        defer { fixture.remove() }

        try fixture.store.add(name: "First project")

        #expect(trialStore.startCallDates == [now])
        #expect(
            coordinator.snapshot == .trial(
                startedAt: now,
                expiresAt: now.addingTimeInterval(TrialRecord.duration)
            )
        )
        #expect(fixture.store.projects.map(\.name) == ["First project"])
        #expect(FileManager.default.fileExists(atPath: fixture.archiveURL.path))
    }

    @Test @MainActor func failedTrialCommitFailsClosedBeforeTheStoreWrite() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let trialStore = TrialStoreSpy(
            loadedRecord: nil,
            startError: TrialStoreSpy.Failure.start
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: trialStore,
            now: { now }
        )
        await coordinator.prepare()
        let fixture = try StoreFixture(
            authorize: { coordinator.authorize($0) },
            commit: { coordinator.commitSuccessfulMutation($0) }
        )
        defer { fixture.remove() }

        #expect(throws: ProjectStoreError.accessRestricted) {
            try fixture.store.add(name: "Must not exist")
        }

        #expect(fixture.store.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveURL.path))
        #expect(coordinator.snapshot == .trialNotStarted)
        #expect(coordinator.verifiedSnapshot == nil)
        #expect(coordinator.unlockRequest == .createProject)
        #expect(coordinator.authorize(.createProject) == .requiresUnlock)
        #expect(coordinator.authorize(.changeCounter) == .requiresUnlock)
    }

    @Test @MainActor func expiredTrialPublishesTheRejectedMutation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )
        await coordinator.prepare()
        let fixture = try StoreFixture(authorize: { coordinator.authorize($0) })
        defer { fixture.remove() }

        #expect(throws: ProjectStoreError.accessRestricted) {
            try fixture.store.addYarn(
                StoredYarn(name: "Blocked"),
                photoData: nil
            )
        }

        #expect(fixture.store.yarns.isEmpty)
        #expect(coordinator.unlockRequest == .createYarn)
    }

    @Test @MainActor func screenshotConfigurationDoesNotConstructExternalServices() {
        var purchaseFactoryCalls = 0
        var trialFactoryCalls = 0

        let coordinator = EntitlementCoordinator.configured(
            screenshotMode: true,
            purchaseServiceFactory: {
                purchaseFactoryCalls += 1
                return PurchaseServiceSpy(qualification: .none)
            },
            trialStoreFactory: {
                trialFactoryCalls += 1
                return TrialStoreSpy(loadedRecord: nil)
            }
        )

        #expect(coordinator.snapshot == .legacyPaidOwner)
        #expect(coordinator.authorize(.restoreBackup) == .allow)
        #expect(purchaseFactoryCalls == 0)
        #expect(trialFactoryCalls == 0)
    }

    @Test @MainActor func screenshotConfigurationAllowsDurableWatchCommandWithoutPreparation() throws {
        var purchaseFactoryCalls = 0
        var trialFactoryCalls = 0
        let coordinator = EntitlementCoordinator.configured(
            screenshotMode: true,
            purchaseServiceFactory: {
                purchaseFactoryCalls += 1
                return PurchaseServiceSpy(qualification: .none)
            },
            trialStoreFactory: {
                trialFactoryCalls += 1
                return TrialStoreSpy(loadedRecord: nil)
            }
        )
        let fixture = try DurableWatchStoreFixture(
            authorize: { coordinator.authorize($0) }
        )
        defer { fixture.remove() }

        let acknowledgement = try fixture.store.applyWatchCommandDurably(
            fixture.command,
            ledgerURL: fixture.ledgerURL,
            preparedCommandURL: fixture.preparedURL
        )

        #expect(acknowledgement.rejection == nil)
        #expect(
            fixture.store.project(id: fixture.projectID)?
                .counters.first(where: { $0.id == fixture.counterID })?.value == 1
        )
        #expect(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.preparedURL.path))
        #expect(coordinator.snapshot == .legacyPaidOwner)
        #expect(coordinator.unlockRequest == nil)
        #expect(purchaseFactoryCalls == 0)
        #expect(trialFactoryCalls == 0)
    }

    @Test @MainActor func localizedLifetimePriceIsAvailableWithoutExposingPurchaseService() async {
        let purchaseService = PurchaseServiceSpy(
            qualification: .none,
            localizedLifetimePrice: "US$4.99"
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: nil)
        )

        await coordinator.refreshEntitlement()

        #expect(coordinator.localizedLifetimePrice == "US$4.99")
        #expect(purchaseService.prepareCallCount == 1)
    }

    @Test @MainActor func successfulLifetimePurchaseRefreshesSnapshotAndDismissesUnlockRequest() async throws {
        let purchaseService = PurchaseServiceSpy(
            qualification: .none,
            purchaseOutcome: .purchased
        )
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )
        await coordinator.prepare()
        _ = coordinator.authorize(.changeCounter)
        purchaseService.qualification = .lifetime

        let outcome = try await coordinator.purchaseLifetime()

        #expect(outcome == .purchased)
        #expect(purchaseService.purchaseCallCount == 1)
        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(coordinator.unlockRequest == nil)
    }

    @Test @MainActor
    func authoritativeRefreshWaitsForStartupThenStartsANewQualificationFlight() async {
        let purchaseService = ControlledPurchaseService()
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: nil)
        )

        let startup = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 1)
        let refresh = Task { await coordinator.refreshEntitlement() }

        purchaseService.resumeNextQualification(returning: .none)
        await purchaseService.waitForQualificationCall(count: 2)
        purchaseService.resumeNextQualification(returning: .lifetime)

        await startup.value
        await refresh.value

        #expect(purchaseService.prepareCallCount == 2)
        #expect(purchaseService.qualificationCallCount == 2)
        #expect(coordinator.snapshot == .permanentlyUnlocked)
    }

    @Test @MainActor
    func restoredLifetimeIsNotOverwrittenByAnOlderPreparationFlight() async throws {
        let purchaseService = ControlledPurchaseService(
            restoreQualification: .lifetime
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: nil)
        )

        let preparation = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 1)

        #expect(try await coordinator.restorePurchases() == .lifetime)
        purchaseService.resumeNextQualification(returning: .none)
        await preparation.value

        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(coordinator.verifiedSnapshot == .permanentlyUnlocked)
    }

    @Test @MainActor
    func successfulTrialCommitIsNotOverwrittenByAnOlderRefreshFlight() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let trialStore = TrialStoreSpy(
            loadedRecord: nil,
            startedRecord: TrialRecord(startedAt: now)
        )
        let purchaseService = ControlledPurchaseService()
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore,
            now: { now }
        )
        let preparation = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 1)
        purchaseService.resumeNextQualification(returning: .none)
        await preparation.value

        let refresh = Task { await coordinator.refreshEntitlement() }
        await purchaseService.waitForQualificationCall(count: 2)

        #expect(coordinator.commitSuccessfulMutation(.createProject) == .allow)
        purchaseService.resumeNextQualification(returning: .none)
        await refresh.value

        #expect(coordinator.snapshot == .trial(
            startedAt: now,
            expiresAt: now.addingTimeInterval(TrialRecord.duration)
        ))
        #expect(coordinator.verifiedSnapshot == coordinator.snapshot)
        #expect(purchaseService.qualificationCallCount == 2)
    }

    @Test @MainActor
    func pendingPurchaseUnlocksWhenADeferredVerifiedTransactionArrives() async throws {
        let purchaseService = ControlledPurchaseService(
            purchaseOutcome: .pending
        )
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )

        let preparation = Task { await coordinator.prepare() }
        await purchaseService.waitForQualificationCall(count: 1)
        purchaseService.resumeNextQualification(returning: .none)
        await preparation.value
        _ = coordinator.authorize(.changeCounter)

        #expect(try await coordinator.purchaseLifetime() == .pending)
        #expect(coordinator.unlockRequest == .changeCounter)

        let unlocked = Task { @MainActor in
            for await snapshot in coordinator.$snapshot.values {
                if snapshot == .permanentlyUnlocked {
                    return
                }
            }
        }
        purchaseService.sendEntitlementUpdate()
        await purchaseService.waitForQualificationCall(count: 2)
        purchaseService.resumeNextQualification(returning: .lifetime)
        await unlocked.value

        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(coordinator.unlockRequest == nil)
    }

    @Test @MainActor func cancelledPurchaseKeepsUnlockRequestAndDoesNotRefreshQualification() async throws {
        let purchaseService = PurchaseServiceSpy(
            qualification: .none,
            purchaseOutcome: .cancelled
        )
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )
        await coordinator.prepare()
        _ = coordinator.authorize(.changeCounter)
        let qualificationCallsBeforePurchase = purchaseService.qualificationCallCount

        let outcome = try await coordinator.purchaseLifetime()

        #expect(outcome == .cancelled)
        #expect(purchaseService.purchaseCallCount == 1)
        #expect(purchaseService.qualificationCallCount == qualificationCallsBeforePurchase)
        #expect(coordinator.unlockRequest == .changeCounter)
    }

    @Test @MainActor func successfulRestoreRefreshesSnapshotAndDismissesUnlockRequest() async throws {
        let purchaseService = PurchaseServiceSpy(
            qualification: .none,
            restoreQualification: .lifetime
        )
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )
        await coordinator.prepare()
        _ = coordinator.authorize(.createProject)
        purchaseService.qualification = .lifetime

        let qualification = try await coordinator.restorePurchases()

        #expect(qualification == .lifetime)
        #expect(purchaseService.restoreCallCount == 1)
        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(coordinator.unlockRequest == nil)
    }

    @Test @MainActor func authoritativeNoneRestoreRevokesVerifiedLifetime() async throws {
        let purchaseService = PurchaseServiceSpy(
            qualification: .lifetime,
            restoreQualification: PurchaseQualification.none
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: TrialStoreSpy(loadedRecord: nil)
        )
        await coordinator.prepare()

        #expect(try await coordinator.restorePurchases() == .none)
        #expect(coordinator.snapshot == .trialNotStarted)
        #expect(coordinator.verifiedSnapshot == .trialNotStarted)
    }

    @Test @MainActor func unavailableRestorePreservesVerifiedLifetime() async throws {
        let purchaseService = PurchaseServiceSpy(
            qualification: .lifetime,
            restoreQualification: .unavailable
        )
        let trialStore = TrialStoreSpy(loadedRecord: nil)
        let coordinator = EntitlementCoordinator(
            purchaseService: purchaseService,
            trialStore: trialStore
        )
        await coordinator.prepare()

        #expect(try await coordinator.restorePurchases() == .unavailable)
        #expect(coordinator.snapshot == .permanentlyUnlocked)
        #expect(
            coordinator.purchaseVerificationAvailability == .unavailable
        )
        #expect(trialStore.loadCallCount == 0)
    }

    @Test @MainActor func dismissUnlockClearsOnlyThePublishedRequest() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = TrialRecord(
            startedAt: now.addingTimeInterval(-TrialRecord.duration - 1)
        )
        let coordinator = EntitlementCoordinator(
            purchaseService: PurchaseServiceSpy(qualification: .none),
            trialStore: TrialStoreSpy(loadedRecord: expired),
            now: { now }
        )
        await coordinator.prepare()
        _ = coordinator.authorize(.createYarn)
        let snapshotBeforeDismissal = coordinator.snapshot

        coordinator.dismissUnlock()

        #expect(coordinator.unlockRequest == nil)
        #expect(coordinator.snapshot == snapshotBeforeDismissal)
    }
}

@MainActor
private final class PurchaseServiceSpy: PurchaseService {
    let entitlementUpdates: AsyncStream<Void>
    private let entitlementUpdatesContinuation: AsyncStream<Void>.Continuation
    var qualification: PurchaseQualification
    private(set) var prepareCallCount = 0
    private(set) var qualificationCallCount = 0
    private(set) var purchaseCallCount = 0
    private(set) var restoreCallCount = 0
    var localizedLifetimePrice: String?
    private let purchaseOutcome: PurchaseOutcome
    private let restoreQualification: PurchaseQualification

    init(
        qualification: PurchaseQualification,
        localizedLifetimePrice: String? = nil,
        purchaseOutcome: PurchaseOutcome = .cancelled,
        restoreQualification: PurchaseQualification? = nil
    ) {
        let updates = AsyncStream<Void>.makeStream()
        entitlementUpdates = updates.stream
        entitlementUpdatesContinuation = updates.continuation
        self.qualification = qualification
        self.localizedLifetimePrice = localizedLifetimePrice
        self.purchaseOutcome = purchaseOutcome
        self.restoreQualification = restoreQualification ?? qualification
    }

    func prepare() async {
        prepareCallCount += 1
    }

    func currentQualification() async -> PurchaseQualification {
        qualificationCallCount += 1
        return qualification
    }

    func purchaseLifetime() async throws -> PurchaseOutcome {
        purchaseCallCount += 1
        return purchaseOutcome
    }

    func restore() async throws -> PurchaseQualification {
        restoreCallCount += 1
        return restoreQualification
    }
}

@MainActor
private final class ControlledPurchaseService: PurchaseService {
    let entitlementUpdates: AsyncStream<Void>
    private let entitlementUpdatesContinuation: AsyncStream<Void>.Continuation
    private var qualificationContinuations: [
        CheckedContinuation<PurchaseQualification, Never>
    ] = []
    private var qualificationCallWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private(set) var prepareCallCount = 0
    private(set) var qualificationCallCount = 0
    var localizedLifetimePrice: String?
    private let purchaseOutcome: PurchaseOutcome
    private let restoreQualification: PurchaseQualification

    init(
        purchaseOutcome: PurchaseOutcome = .cancelled,
        restoreQualification: PurchaseQualification = .none
    ) {
        let updates = AsyncStream<Void>.makeStream()
        entitlementUpdates = updates.stream
        entitlementUpdatesContinuation = updates.continuation
        self.purchaseOutcome = purchaseOutcome
        self.restoreQualification = restoreQualification
    }

    func prepare() async {
        prepareCallCount += 1
    }

    func currentQualification() async -> PurchaseQualification {
        qualificationCallCount += 1
        resumeSatisfiedQualificationCallWaiters()
        let result = await withCheckedContinuation {
            qualificationContinuations.append($0)
        }
        return result
    }

    func waitForQualificationCall(count: Int) async {
        guard qualificationCallCount < count else { return }
        await withCheckedContinuation {
            qualificationCallWaiters.append((count, $0))
        }
    }

    func resumeAllQualifications(returning qualification: PurchaseQualification) {
        let continuations = qualificationContinuations
        qualificationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: qualification)
        }
    }

    func resumeNextQualification(returning qualification: PurchaseQualification) {
        guard !qualificationContinuations.isEmpty else { return }
        qualificationContinuations.removeFirst().resume(returning: qualification)
    }

    func sendEntitlementUpdate() {
        entitlementUpdatesContinuation.yield()
    }

    func purchaseLifetime() async throws -> PurchaseOutcome {
        purchaseOutcome
    }

    func restore() async throws -> PurchaseQualification {
        restoreQualification
    }

    private func resumeSatisfiedQualificationCallWaiters() {
        let satisfied = qualificationCallWaiters.filter {
            qualificationCallCount >= $0.count
        }
        qualificationCallWaiters.removeAll {
            qualificationCallCount >= $0.count
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

}

@MainActor
private final class MainActorSignal {
    private var isSignaled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signal() {
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation {
            continuation = $0
        }
    }
}

private final class TrialStoreSpy: TrialStore, @unchecked Sendable {
    enum Failure: Error {
        case load
        case start
    }

    private let loadedRecord: TrialRecord?
    private let startedRecord: TrialRecord?
    private let loadError: Error?
    private let startError: Error?
    private(set) var loadCallCount = 0
    private(set) var startCallDates: [Date] = []

    init(
        loadedRecord: TrialRecord?,
        startedRecord: TrialRecord? = nil,
        loadError: Error? = nil,
        startError: Error? = nil
    ) {
        self.loadedRecord = loadedRecord
        self.startedRecord = startedRecord
        self.loadError = loadError
        self.startError = startError
    }

    func load() throws -> TrialRecord? {
        loadCallCount += 1
        if let loadError {
            throw loadError
        }
        return loadedRecord
    }

    func startIfNeeded(now: Date) throws -> TrialRecord {
        startCallDates.append(now)
        if let startError {
            throw startError
        }
        return startedRecord ?? TrialRecord(startedAt: now)
    }
}

private final class InMemoryTrialKeychain: @unchecked Sendable {
    private var storedData: Data?

    var client: KeychainTrialStore.SecurityClient {
        .init(
            copyMatching: { [self] _, result in
                guard let storedData else {
                    return errSecItemNotFound
                }
                result?.pointee = storedData as CFData
                return errSecSuccess
            },
            add: { [self] attributes, _ in
                guard storedData == nil else {
                    return errSecDuplicateItem
                }
                let dictionary = attributes as NSDictionary
                guard let data = dictionary[kSecValueData] as? Data else {
                    return errSecParam
                }
                storedData = data
                return errSecSuccess
            }
        )
    }
}

@MainActor
private struct StoreFixture {
    let root: URL
    let archiveURL: URL
    let store: JSONProjectStore

    init(
        authorize: @escaping MutationAuthorizer,
        commit: @escaping MutationSuccessCommitter = { _ in .allow }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementCoordinatorTests-\(UUID().uuidString)")
        archiveURL = root.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        store = JSONProjectStore(
            url: archiveURL,
            authorizeMutation: authorize,
            commitSuccessfulMutation: commit
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private struct DurableWatchStoreFixture {
    let root: URL
    let archiveURL: URL
    let ledgerURL: URL
    let preparedURL: URL
    let projectID: UUID
    let counterID: UUID
    let command: WatchCounterCommand
    let store: JSONProjectStore

    init(authorize: @escaping MutationAuthorizer) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementCoordinatorWatchTests-\(UUID().uuidString)")
        archiveURL = root.appendingPathComponent("projects-v1.json")
        ledgerURL = WatchSyncPaths.processedLedger(in: root)
        preparedURL = WatchSyncPaths.preparedCommand(in: root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let now = Date(timeIntervalSince1970: 1_000)
        let project = try StoredProject(
            name: "Watch project",
            counters: [ProjectCounter(defaultOrdinal: 1)],
            now: now
        )
        projectID = project.id
        counterID = project.counters[0].id
        command = WatchCounterCommand(
            projectID: projectID,
            counterID: counterID,
            operation: .increment,
            createdAt: now
        )
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project]
        )).write(to: archiveURL, options: .atomic)
        store = JSONProjectStore(
            url: archiveURL,
            authorizeMutation: authorize
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
