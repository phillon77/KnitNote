import Foundation
import Testing
@testable import KnitNote

@Suite struct EntitlementCoordinatorTests {
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

    @Test @MainActor func firstProjectCreationAtomicallyStartsTrialBeforeTheStoreWrites() async throws {
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
        let fixture = try StoreFixture(authorize: { coordinator.authorize($0) })
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

    @Test @MainActor func failedTrialStartBlocksTheTriggeringStoreWrite() async throws {
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
        let fixture = try StoreFixture(authorize: { coordinator.authorize($0) })
        defer { fixture.remove() }

        #expect(throws: ProjectStoreError.accessRestricted) {
            try fixture.store.add(name: "Must not exist")
        }

        #expect(fixture.store.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveURL.path))
        #expect(coordinator.snapshot == .trialNotStarted)
        #expect(coordinator.unlockRequest == .createProject)
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
}

@MainActor
private final class PurchaseServiceSpy: PurchaseService {
    private let qualification: PurchaseQualification
    private(set) var prepareCallCount = 0
    private(set) var qualificationCallCount = 0
    var localizedLifetimePrice: String?

    init(qualification: PurchaseQualification) {
        self.qualification = qualification
    }

    func prepare() async {
        prepareCallCount += 1
    }

    func currentQualification() async -> PurchaseQualification {
        qualificationCallCount += 1
        return qualification
    }

    func purchaseLifetime() async throws -> PurchaseOutcome {
        .cancelled
    }

    func restore() async throws -> PurchaseQualification {
        qualification
    }
}

private final class TrialStoreSpy: TrialStore, @unchecked Sendable {
    enum Failure: Error {
        case start
    }

    private let loadedRecord: TrialRecord?
    private let startedRecord: TrialRecord?
    private let startError: Error?
    private(set) var loadCallCount = 0
    private(set) var startCallDates: [Date] = []

    init(
        loadedRecord: TrialRecord?,
        startedRecord: TrialRecord? = nil,
        startError: Error? = nil
    ) {
        self.loadedRecord = loadedRecord
        self.startedRecord = startedRecord
        self.startError = startError
    }

    func load() throws -> TrialRecord? {
        loadCallCount += 1
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

@MainActor
private struct StoreFixture {
    let root: URL
    let archiveURL: URL
    let store: JSONProjectStore

    init(authorize: @escaping MutationAuthorizer) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntitlementCoordinatorTests-\(UUID().uuidString)")
        archiveURL = root.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        store = JSONProjectStore(
            url: archiveURL,
            authorizeMutation: authorize
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
