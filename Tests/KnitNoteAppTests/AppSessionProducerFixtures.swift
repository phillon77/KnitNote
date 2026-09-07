import Foundation
@testable import KnitNote

enum ProducerTestFailure: Error, Sendable {
    case processingFailed
}

struct ProducerTestInboxProcessingSnapshot: Equatable, Sendable {
    let pendingItemsCallCount: Int
    let processCallCount: Int
    let discardCallCount: Int
}

struct ProducerTestNoticeDelaySnapshot: Equatable, Sendable {
    let callCount: Int
    let completionCount: Int
}

actor ProducerTestNoticeDelay {
    enum Mode: Sendable {
        case suspendAll
        case suspendFirstOnly
    }

    private let mode: Mode
    private var callCount = 0
    private var completionCount = 0
    private var releaseAllCalls = false
    private var releasedCalls: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func wait() async {
        callCount += 1
        let call = callCount
        let ready = callCountWaiters.filter { callCount >= $0.0 }
        callCountWaiters.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }

        let shouldSuspend: Bool
        switch mode {
        case .suspendAll:
            shouldSuspend = true
        case .suspendFirstOnly:
            shouldSuspend = call == 1
        }

        if shouldSuspend, !releaseAllCalls, !releasedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                if releaseAllCalls || releasedCalls.contains(call) {
                    continuation.resume()
                } else {
                    continuations[call] = continuation
                }
            }
        }

        completionCount += 1
    }

    func waitUntilCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { callCountWaiters.append((expected, $0)) }
    }

    func release(call: Int) {
        guard releasedCalls.insert(call).inserted else { return }
        continuations.removeValue(forKey: call)?.resume()
    }

    func releaseAll() {
        guard !releaseAllCalls else { return }
        releaseAllCalls = true
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func snapshot() -> ProducerTestNoticeDelaySnapshot {
        ProducerTestNoticeDelaySnapshot(
            callCount: callCount,
            completionCount: completionCount
        )
    }
}

actor ProducerTestInboxProcessing: PatternInboxProcessing {
    let item: PatternInboxItem

    private let result: Result<PatternImportOutcome, any Error>
    private var processStarted = false
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingItemsCallCount = 0
    private var processCallCount = 0
    private var discardCallCount = 0

    init(
        item: PatternInboxItem,
        result: Result<PatternImportOutcome, any Error>
    ) {
        self.item = item
        self.result = result
    }

    func pendingItems() async throws -> [PatternInboxItem] {
        pendingItemsCallCount += 1
        return [item]
    }

    func process(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome {
        processCallCount += 1
        processStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        }

        return try result.get()
    }

    func discard(itemID: UUID) async throws {
        discardCallCount += 1
    }

    func waitUntilProcessStarts() async {
        guard !processStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshot() -> ProducerTestInboxProcessingSnapshot {
        ProducerTestInboxProcessingSnapshot(
            pendingItemsCallCount: pendingItemsCallCount,
            processCallCount: processCallCount,
            discardCallCount: discardCallCount
        )
    }
}

@MainActor
struct ProducerTestInboxFixture {
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let presenter: PatternBackupReminderPresenter
    let processing: ProducerTestInboxProcessing
    let processor: PatternInboxProcessor

    init(
        item: PatternInboxItem = producerTestInboxItem(),
        result: Result<PatternImportOutcome, any Error>,
        noticeDelay: (@Sendable () async -> Void)? = nil
    ) throws {
        let suiteName = "ProducerTest.PatternInbox.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ProducerTestFailure.processingFailed
        }
        defaults.removePersistentDomain(forName: suiteName)
        let presenter = PatternBackupReminderPresenter(history: BackupHistory(defaults: defaults))
        let processing = ProducerTestInboxProcessing(item: item, result: result)

        defaultsSuiteName = suiteName
        self.defaults = defaults
        self.presenter = presenter
        self.processing = processing
        let driver = PatternInboxDriver(processing: processing)
        if let noticeDelay {
            processor = PatternInboxProcessor(
                driver: driver,
                backupReminderPresenter: presenter,
                noticeDelay: noticeDelay
            )
        } else {
            processor = PatternInboxProcessor(
                driver: driver,
                backupReminderPresenter: presenter
            )
        }
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    func stopDrainAndCleanup() async {
        processor.stopForSessionTransition()
        await processing.release()
        let cleanupWaiter = Task { @MainActor in
            _ = try? await processor.waitForStoppedOperations()
        }
        await cleanupWaiter.value
        cleanup()
    }
}

func producerTestInboxItem() -> PatternInboxItem {
    PatternInboxItem(
        originalFilename: "fixture.pdf",
        receivedAt: Date(timeIntervalSince1970: 1),
        origin: .shareExtension,
        targetProjectID: nil,
        stagedFilename: "fixture.pdf"
    )
}

@MainActor
final class ProducerTestWatchTransport: WatchConnectivityTransport {
    var onReceivedEnvelope: WatchConnectivityReceivedEnvelope?
    var onReachabilityChanged: WatchConnectivityReachabilityChanged?
    var onActivationCompleted: WatchConnectivityActivationCompleted?
    var onTransferCompleted: WatchConnectivityTransferCompleted?
    var isReachable = true

    private(set) var activationCount = 0
    private(set) var applicationContexts: [WatchConnectivityEnvelope] = []
    private(set) var sentMessages: [WatchConnectivityEnvelope] = []
    private(set) var sentEnvelopes: [WatchConnectivityEnvelope] = []
    var onActivate: (() -> Void)?
    var onUpdateApplicationContext: (() -> Void)?

    func activate() {
        activationCount += 1
        onActivate?()
    }

    func updateApplicationContext(_ envelope: WatchConnectivityEnvelope) throws {
        applicationContexts.append(envelope)
        onUpdateApplicationContext?()
    }

    func sendMessage(
        _ envelope: WatchConnectivityEnvelope,
        reply: @escaping WatchConnectivityEnvelopeReply,
        failure: @escaping WatchConnectivityFailure
    ) {
        sentMessages.append(envelope)
    }

    func transferUserInfo(_ envelope: WatchConnectivityEnvelope) {
        sentEnvelopes.append(envelope)
    }
}

struct ProducerTestDiskSnapshot: Equatable {
    struct Entry: Equatable {
        enum Kind: Equatable { case directory, regularFile }
        let relativePath: String
        let kind: Kind
        let data: Data?
    }

    let entries: [Entry]

    static func capture(root: URL) throws -> Self {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return .init(entries: []) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: (any Error)?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ProducerTestFailure.processingFailed
        }

        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw ProducerTestFailure.processingFailed
            }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            if values.isDirectory == true {
                entries.append(.init(relativePath: relativePath, kind: .directory, data: nil))
            } else if values.isRegularFile == true {
                entries.append(.init(
                    relativePath: relativePath,
                    kind: .regularFile,
                    data: try Data(contentsOf: url)
                ))
            } else {
                throw ProducerTestFailure.processingFailed
            }
        }
        if let enumerationError { throw enumerationError }
        return .init(entries: entries.sorted { $0.relativePath < $1.relativePath })
    }
}

@MainActor
final class ProducerTestMainActorEvent {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func wait(for expected: Int = 1) async {
        guard count < expected else { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
}

@MainActor
final class ProducerTestWatchSleep {
    private var durations: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var released: Set<Int> = []
    private var releaseEverything = false

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        let call = durations.count
        let ready = waiters.filter { durations.count >= $0.0 }
        waiters.removeAll { durations.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard !releaseEverything, !released.contains(call) else { return }
        await withCheckedContinuation { continuation in
            if releaseEverything || released.contains(call) {
                continuation.resume()
            } else {
                continuations[call] = continuation
            }
        }
    }

    func waitUntilCallCount(_ expected: Int) async {
        guard durations.count < expected else { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }

    func release(call: Int) {
        guard released.insert(call).inserted else { return }
        continuations.removeValue(forKey: call)?.resume()
    }

    func releaseAll() {
        releaseEverything = true
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

}

final class ProducerTestGateProbe: @unchecked Sendable {
    let states: AsyncStream<AppSessionCallbackGate.State>
    private let continuation: AsyncStream<AppSessionCallbackGate.State>.Continuation

    init() {
        let events = AsyncStream<AppSessionCallbackGate.State>.makeStream()
        states = events.stream
        continuation = events.continuation
    }

    func record(_ state: AppSessionCallbackGate.State) {
        continuation.yield(state)
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
final class ProducerTestTrialPurchaseService: PurchaseService {
    let entitlementUpdates: AsyncStream<Void>
    let localizedLifetimePrice: String? = nil

    init() {
        entitlementUpdates = AsyncStream { continuation in continuation.finish() }
    }

    func prepare() async {}
    func currentQualification() async -> PurchaseQualification { .none }
    func purchaseLifetime() async throws -> PurchaseOutcome { .cancelled }
    func restore() async throws -> PurchaseQualification { .none }
}

struct ProducerTestFixedTrialStore: TrialStore {
    let record: TrialRecord
    func load() throws -> TrialRecord? { record }
    func startIfNeeded(now: Date) throws -> TrialRecord { record }
}

@MainActor
struct ProducerTestWatchFixture {
    let root: URL
    let watchRoot: URL
    let now: Date
    let store: JSONProjectStore
    let entitlement: EntitlementCoordinator
    let transport: ProducerTestWatchTransport

    init(entitlement: EntitlementCoordinator? = nil) throws {
        root = URL(filePath: "/tmp/PhoneWatchSessionProducerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let liveRoot = root.appending(path: "A/Live", directoryHint: .isDirectory)
        watchRoot = root.appending(path: "A/Watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        now = Date(timeIntervalSince1970: 1_800_000_000)
        store = JSONProjectStore(
            url: liveRoot.appending(path: "projects.json"),
            authorizeMutation: { mutation in
                FeatureAccessPolicy.decision(
                    for: mutation,
                    snapshot: .legacyPaidOwner,
                    now: Date(timeIntervalSince1970: 1_800_000_000)
                )
            }
        )
        try store.add(name: "A")
        self.entitlement = entitlement ?? .configured(screenshotMode: true)
        transport = ProducerTestWatchTransport()
    }

    func makeCoordinator(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        observeCallbackGateState: @escaping @Sendable (AppSessionCallbackGate.State) -> Void = { _ in }
    ) -> PhoneWatchSyncCoordinator {
        PhoneWatchSyncCoordinator(
            projectStore: store,
            entitlementCoordinator: entitlement,
            transport: transport,
            applicationSupportRoot: watchRoot,
            languageCode: { "en" },
            now: { now },
            sleep: sleep,
            observeCallbackGateState: observeCallbackGateState
        )
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: root)
    }
}

@MainActor
func withProducerTestWatchFixture(
    entitlement: EntitlementCoordinator? = nil,
    controlledSleep: ProducerTestWatchSleep? = nil,
    observeCallbackGateState: @escaping @Sendable (AppSessionCallbackGate.State) -> Void = { _ in },
    operation: @MainActor (
        ProducerTestWatchFixture,
        PhoneWatchSyncCoordinator
    ) async throws -> Void
) async throws {
    let fixture = try ProducerTestWatchFixture(entitlement: entitlement)
    let coordinator = fixture.makeCoordinator(sleep: { duration in
        if let controlledSleep {
            try await controlledSleep.sleep(for: duration)
        } else {
            try await Task.sleep(for: duration)
        }
    }, observeCallbackGateState: observeCallbackGateState)
    let result: Result<Void, any Error>
    do {
        result = .success(try await operation(fixture, coordinator))
    } catch {
        result = .failure(error)
    }

    let cleanup = Task { @MainActor in
        controlledSleep?.releaseAll()
        fixture.transport.onActivate = nil
        fixture.transport.onUpdateApplicationContext = nil
        coordinator.stopForSessionTransition()
        _ = try? await coordinator.waitForStoppedOperations()
        try? fixture.cleanup()
    }
    await cleanup.value
    try result.get()
}
