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
