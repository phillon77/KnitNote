import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternInboxDriverTests {
    @Test func processesInOrderAndStopsAtTheFirstAmbiguousItem() async throws {
        let first = inboxItem(seconds: 1)
        let second = inboxItem(seconds: 2)
        let third = inboxItem(seconds: 3)
        let candidateIDs = [UUID(), UUID()]
        let processing = PatternInboxProcessingSpy(
            items: [first, second, third],
            outcomes: [
                first.id: [.created(patternID: UUID())],
                second.id: [.needsSelection(itemID: second.id, candidatePatternIDs: candidateIDs)],
                third.id: [.existing(patternID: UUID())]
            ]
        )
        let driver = PatternInboxDriver(processing: processing)

        let update = try await driver.processPending()

        #expect(update.imported.count == 1)
        #expect(update.blocking == .selection(item: second, candidatePatternIDs: candidateIDs))
        #expect(await processing.processedItemIDs == [first.id, second.id])
    }

    @Test func concurrentSceneActivationsUseOneExplicitGate() async throws {
        let item = inboxItem(seconds: 1)
        let processing = PatternInboxProcessingSpy(
            items: [item],
            outcomes: [item.id: [.created(patternID: UUID())],
            ],
            suspendedItemID: item.id
        )
        let driver = PatternInboxDriver(processing: processing)

        let firstRun = Task { try await driver.processPending() }
        await processing.waitUntilSuspendedProcessStarts()
        let overlappingRun = try await driver.processPending()

        #expect(overlappingRun == .busy)
        await processing.resumeSuspendedProcess()
        _ = try await firstRun.value
        #expect(await processing.processedItemIDs == [item.id])
    }

    @Test func cancellationEscapesWithoutBecomingAUserFailureAndReleasesTheGate() async throws {
        let item = inboxItem(seconds: 1)
        let processing = PatternInboxProcessingSpy(
            items: [item],
            outcomes: [
                item.id: [
                    .failure(CancellationError()),
                    .success(.created(patternID: UUID()))
                ]
            ]
        )
        let driver = PatternInboxDriver(processing: processing)

        await #expect(throws: CancellationError.self) {
            try await driver.processPending()
        }
        let retry = try await driver.processPending()

        #expect(retry.imported.count == 1)
        #expect(retry.blocking == nil)
    }

    @Test func explicitResolutionAndDiscardContinueWithTheRemainingQueue() async throws {
        let ambiguous = inboxItem(seconds: 1)
        let discarded = inboxItem(seconds: 2)
        let final = inboxItem(seconds: 3)
        let newPatternID = UUID()
        let processing = PatternInboxProcessingSpy(
            items: [ambiguous, discarded, final],
            outcomes: [
                ambiguous.id: [
                    .success(.needsSelection(
                        itemID: ambiguous.id,
                        candidatePatternIDs: [UUID(), UUID()]
                    )),
                    .success(.created(patternID: newPatternID))
                ],
                discarded.id: [.failure(TestFailure())],
                final.id: [.success(.existing(patternID: UUID()))]
            ]
        )
        let driver = PatternInboxDriver(processing: processing)

        _ = try await driver.processPending()
        let resolved = try await driver.resolve(
            itemID: ambiguous.id,
            resolution: .createNew
        )
        #expect(resolved.imported == [.created(patternID: newPatternID)])
        #expect(resolved.blocking == .failure(itemID: discarded.id))

        let afterDiscard = try await driver.discard(itemID: discarded.id)
        #expect(afterDiscard.imported.count == 1)
        #expect(afterDiscard.blocking == nil)
        #expect(await processing.discardedItemIDs == [discarded.id])
    }

    private func inboxItem(seconds: TimeInterval) -> PatternInboxItem {
        PatternInboxItem(
            originalFilename: "\(seconds).pdf",
            receivedAt: Date(timeIntervalSince1970: seconds),
            origin: .shareExtension,
            targetProjectID: nil,
            stagedFilename: "\(UUID().uuidString).pdf"
        )
    }
}

private struct TestFailure: Error {}

private actor PatternInboxProcessingSpy: PatternInboxProcessing {
    private var items: [PatternInboxItem]
    private var outcomes: [UUID: [Result<PatternImportOutcome, any Error>]]
    private let suspendedItemID: UUID?
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var processDidStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var processedItemIDs: [UUID] = []
    private(set) var discardedItemIDs: [UUID] = []

    init(
        items: [PatternInboxItem],
        outcomes: [UUID: [PatternImportOutcome]],
        suspendedItemID: UUID? = nil
    ) {
        self.items = items
        self.outcomes = outcomes.mapValues { $0.map(Result.success) }
        self.suspendedItemID = suspendedItemID
    }

    init(
        items: [PatternInboxItem],
        outcomes: [UUID: [Result<PatternImportOutcome, any Error>]],
        suspendedItemID: UUID? = nil
    ) {
        self.items = items
        self.outcomes = outcomes
        self.suspendedItemID = suspendedItemID
    }

    func pendingItems() async throws -> [PatternInboxItem] {
        items
    }

    func process(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome {
        processedItemIDs.append(itemID)
        if itemID == suspendedItemID {
            processDidStart = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { suspendedContinuation = $0 }
        }
        guard var queued = outcomes[itemID], !queued.isEmpty else {
            throw PatternInboxError.itemNotFound
        }
        let next = queued.removeFirst()
        outcomes[itemID] = queued
        switch next {
        case let .success(outcome):
            if case .needsSelection = outcome {
                return outcome
            }
            items.removeAll { $0.id == itemID }
            return outcome
        case let .failure(error):
            throw error
        }
    }

    func discard(itemID: UUID) async throws {
        discardedItemIDs.append(itemID)
        items.removeAll { $0.id == itemID }
    }

    func waitUntilSuspendedProcessStarts() async {
        if processDidStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resumeSuspendedProcess() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }
}
