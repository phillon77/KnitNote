import Foundation
import Testing
@testable import KnitNote

@MainActor
final class OwnerNativeOperations: WatchConnectivitySessionOperations {
    weak var owner: PhoneWatchSession?
    private(set) var activations = 0
    private(set) var removals = 0
    var isReachable: Bool { true }
    func installDelegate(_ owner: PhoneWatchSession) { self.owner = owner }
    func removeDelegate(ifOwnedBy owner: PhoneWatchSession) {
        if self.owner === owner { self.owner = nil }
        removals += 1
    }
    func activate() { activations += 1 }
    func updateApplicationContext(_ applicationContext: [String: Any]) throws {}
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {}
    func enqueueUserInfo(_ userInfo: [String: Any]) {}
}

// Only controls this producer's own drain result. It never replaces the
// resource group's gate or any store admission authority.
@MainActor
final class OwnerDrainProducer: AppSessionProducer {
    enum Mode { case normal, failFirst, holdFirst }
    let mode: Mode
    let entered = ProducerTestMainActorEvent()
    let release = ProducerTestMainActorEvent()
    private(set) var stops = 0
    var onStop: (() -> Void)?
    var onWait: (() -> Void)?
    init(mode: Mode = .normal) { self.mode = mode }
    func stopForSessionTransition() {
        stops += 1
        onStop?()
    }
    func waitForStoppedOperations() async throws {
        entered.signal()
        onWait?()
        let call = entered.count
        if call == 1 {
            switch mode {
            case .normal: break
            case .failFirst: throw ProducerTestFailure.processingFailed
            case .holdFirst: await release.wait()
            }
        }
        try Task.checkCancellation()
    }
}

@MainActor
final class OwnerWorkFixture {
    let root: URL
    let store: JSONProjectStore
    let processing: ProducerTestInboxProcessing
    let inbox: PatternInboxProcessor
    let native: OwnerNativeOperations
    let adapter: PhoneWatchSession
    let watch: PhoneWatchSyncCoordinator
    let probe: OwnerDrainProducer
    let resource: AppSessionResources
    let defaults: UserDefaults
    let suite: String
    var waiters: [Task<Void, any Error>] = []

    init(mode: OwnerDrainProducer.Mode = .normal) throws {
        root = URL(filePath: "/tmp/AppSessionOwnerWorkTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JSONProjectStore(url: root.appending(path: "projects.json"))
        try store.add(name: "owned")
        suite = "AppSessionOwnerTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        processing = ProducerTestInboxProcessing(item: producerTestInboxItem(), result: .success(.created(patternID: UUID())))
        inbox = PatternInboxProcessor(
            driver: PatternInboxDriver(processing: processing),
            backupReminderPresenter: PatternBackupReminderPresenter(history: BackupHistory(defaults: defaults))
        )
        native = OwnerNativeOperations()
        adapter = PhoneWatchSession(session: native, isSupported: { true })
        watch = PhoneWatchSyncCoordinator(
            projectStore: store,
            entitlementCoordinator: .configured(screenshotMode: true),
            transport: adapter,
            applicationSupportRoot: root.appending(path: "Watch", directoryHint: .isDirectory),
            languageCode: { "en" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        probe = OwnerDrainProducer(mode: mode)
        let registered: [any AppSessionProducer] = [probe, inbox, watch, adapter]
        let fixedStore = store
        resource = try AppSessionResources(store: store) { received in
            #expect(received === fixedStore)
            return registered
        }
    }

    func waiter(_ body: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let task = Task { @MainActor in try await body() }
        waiters.append(task)
        return task
    }

    func cleanup() async throws {
        probe.onStop = nil
        probe.onWait = nil
        probe.release.signal()
        await processing.release()
        // Stop/join actual components and store directly. No owner/resource
        // drain is used as cleanup evidence, even during mutation RED runs.
        inbox.stopForSessionTransition()
        watch.stopForSessionTransition()
        adapter.stopForSessionTransition()
        store.revokeSessionWrites()
        try await inbox.waitForStoppedOperations()
        try await watch.waitForStoppedOperations()
        try await adapter.waitForStoppedOperations()
        try await store.waitForTrackedBackgroundWritesAfterRevocation()
        for task in waiters { _ = await task.result }
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
func withOwnerWorkFixture(
    mode: OwnerDrainProducer.Mode = .normal,
    operation: @MainActor (OwnerWorkFixture) async throws -> Void
) async throws {
    let fixture = try OwnerWorkFixture(mode: mode)
    let result: Result<Void, any Error>
    do { result = .success(try await operation(fixture)) }
    catch { result = .failure(error) }
    let cleanup = Task { @MainActor in try await fixture.cleanup() }
    try await cleanup.value
    try result.get()
}
