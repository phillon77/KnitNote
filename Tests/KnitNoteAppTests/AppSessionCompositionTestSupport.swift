import Foundation
import Testing
@testable import KnitNote

@MainActor
final class CompositionFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    var stores: [JSONProjectStore] = []
    var sessions: [AppSessionResources] = []
    var natives: [CompositionNativeOperations] = []
    var watches: [AppSessionWatchResources] = []

    init() throws {
        root = URL(filePath: "/tmp/AppSessionCompositionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "AppSessionCompositionTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func makeStore(at directory: URL? = nil) -> JSONProjectStore {
        let directory = directory ?? root.appending(path: UUID().uuidString)
        let store = JSONProjectStore.live(baseDirectory: directory)
        stores.append(store)
        return store
    }

    func makeSession(store: JSONProjectStore? = nil, withWatch: Bool = true) throws -> AppSessionResources {
        let store = store ?? makeStore()
        let session = try AppSessionComposition.make(
            store: store, backupHistory: BackupHistory(defaults: defaults),
            makeWatch: { receivedStore in
                #expect(receivedStore === store)
                guard withWatch else { return nil }
                return self.makeWatch(store: receivedStore)
            }
        )
        sessions.append(session)
        return session
    }

    func makeWatch(store: JSONProjectStore) -> AppSessionWatchResources {
        let native = CompositionNativeOperations()
        let adapter = PhoneWatchSession(session: native, isSupported: { true })
        let watch = AppSessionWatchResources(
            coordinator: PhoneWatchSyncCoordinator(
                projectStore: store,
                entitlementCoordinator: .configured(screenshotMode: true),
                transport: adapter,
                applicationSupportRoot: root.appending(path: "Watch-\(UUID().uuidString)"),
                languageCode: { "en" }
            ), adapter: adapter
        )
        natives.append(native)
        watches.append(watch)
        return watch
    }

    func cleanup() async throws {
        // Independently stop/join every real component; never trust the group
        // under test as the cleanup authority (including mutation RED runs).
        for session in sessions { session.presentation?.patternInboxProcessor.stopForSessionTransition() }
        for watch in watches {
            watch.coordinator.stopForSessionTransition()
            watch.adapter.stopForSessionTransition()
        }
        for store in stores { store.revokeSessionWrites() }
        for session in sessions { try await session.presentation?.patternInboxProcessor.waitForStoppedOperations() }
        for watch in watches {
            try await watch.coordinator.waitForStoppedOperations()
            try await watch.adapter.waitForStoppedOperations()
        }
        for store in stores { try await store.waitForTrackedBackgroundWritesAfterRevocation() }
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
final class CompositionNativeOperations: WatchConnectivitySessionOperations {
    weak var owner: PhoneWatchSession?
    private(set) var activations = 0
    private(set) var removals = 0
    private(set) var snapshots: [WatchSyncSnapshot] = []
    var isReachable: Bool { true }
    func installDelegate(_ owner: PhoneWatchSession) { self.owner = owner }
    func removeDelegate(ifOwnedBy owner: PhoneWatchSession) {
        if self.owner === owner { self.owner = nil }
        removals += 1
    }
    func activate() { activations += 1 }
    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        if case let .snapshot(snapshot) = try WatchConnectivityEnvelope(dictionary: applicationContext) {
            snapshots.append(snapshot)
        }
    }
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {}
    func enqueueUserInfo(_ userInfo: [String: Any]) {}
}

@MainActor
func withCompositionFixture(_ operation: @MainActor (CompositionFixture) async throws -> Void) async throws {
    let fixture = try CompositionFixture()
    let result: Result<Void, any Error>
    do { result = .success(try await operation(fixture)) }
    catch { result = .failure(error) }
    try await Task { @MainActor in try await fixture.cleanup() }.value
    try result.get()
}
