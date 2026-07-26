import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Suite struct PatternInboxProcessingStoreTests {
    @Test func ambiguousShareCanCreateOneNewCollectionUsingTheExistingAsset() async throws {
        let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
        let item = try harness.enqueueMatchingFile()
        let existingAssetID = try #require(harness.store.patternAssets.first?.id)

        let outcome = try await harness.store.processPatternInboxItem(
            id: item.id,
            duplicateResolution: .createNew
        )

        guard case let .created(patternID) = outcome else {
            Issue.record("Expected an explicitly created collection")
            return
        }
        #expect(harness.store.patternAssets.map(\.id) == [existingAssetID])
        #expect(harness.store.patterns.count == 3)
        #expect(harness.store.patterns.first(where: { $0.id == patternID })?.displayName == "Matching")
        #expect(try harness.inbox.item(id: item.id) == nil)
    }

    @Test func explicitExistingResolutionRemainsIdempotentAfterRestart() async throws {
        let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
        let item = try harness.enqueueMatchingFile()
        let selectedID = try #require(harness.store.patterns.first?.id)

        let outcome = try await harness.store.processPatternInboxItem(
            id: item.id,
            duplicateResolution: .existing(selectedID)
        )
        let reopened = try harness.reopenedStore()

        #expect(outcome == .existing(patternID: selectedID))
        #expect(reopened.patternAssets.count == 1)
        #expect(reopened.patterns.count == 2)
        #expect(try harness.inbox.items().isEmpty)
        await #expect(throws: PatternInboxError.itemNotFound) {
            try await reopened.processPatternInboxItem(
                id: item.id,
                duplicateResolution: .existing(selectedID)
            )
        }
    }

    @Test func pendingItemsAreReadInReceivedTimeOrder() async throws {
        let harness = try PatternImportHarness()
        let source = try harness.makePDF(named: "Queued.pdf")
        let third = try harness.inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 300)
        )
        let first = try harness.inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 100)
        )
        let second = try harness.inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: Date(timeIntervalSince1970: 200)
        )

        let items = try await harness.store.pendingPatternInboxItems()

        #expect(items.map(\.id) == [first.id, second.id, third.id])
    }

    @Test func discardIsIdempotentAndNeverMutatesTheArchive() async throws {
        let harness = try PatternImportHarness()
        let source = try harness.makePDF(named: "Discarded.pdf")
        let item = try harness.inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: .now
        )
        let archiveBefore = try? Data(contentsOf: harness.archiveURL)

        try await harness.store.discardPatternInboxItem(id: item.id)
        try await harness.store.discardPatternInboxItem(id: item.id)

        #expect(try harness.inbox.items().isEmpty)
        #expect((try? Data(contentsOf: harness.archiveURL)) == archiveBefore)
        #expect(harness.store.patternAssets.isEmpty)
        #expect(harness.store.patterns.isEmpty)
    }

    @Test func createNewCleanupFailureRecoversWithoutPublishingADuplicate() async throws {
        let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
        let item = try harness.enqueueMatchingFile()
        let failingStore = JSONProjectStore(
            url: harness.archiveURL,
            patternFileService: PatternFileService(root: harness.assetsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: harness.inbox.root,
                removeItem: { _ in throw PatternInboxProcessingInjectedFailure() }
            )
        )

        let outcome = try await failingStore.processPatternInboxItem(
            id: item.id,
            duplicateResolution: .createNew
        )
        let restarted = try harness.reopenedStore()

        guard case .created = outcome else {
            Issue.record("Expected a created collection before cleanup failed")
            return
        }
        #expect(restarted.patternAssets.count == 1)
        #expect(restarted.patterns.count == 3)
        #expect(restarted.patterns.filter { $0.displayName == "Matching" }.count == 1)
        #expect(try harness.inbox.items().isEmpty)
    }

    @Test func createNewSidecarCommitFailureUsesItemReceiptAcrossFreshRestart() async throws {
        let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
        let item = try harness.enqueueMatchingFile()
        let failingStore = JSONProjectStore(
            url: harness.archiveURL,
            patternFileService: PatternFileService(root: harness.assetsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: harness.inbox.root,
                writeData: { _, _ in throw PatternInboxProcessingInjectedFailure() }
            )
        )

        await #expect(throws: PatternInboxProcessingInjectedFailure.self) {
            try await failingStore.processPatternInboxItem(
                id: item.id,
                duplicateResolution: .createNew
            )
        }
        let restarted = try harness.reopenedStore()

        #expect(restarted.patternAssets.count == 1)
        #expect(restarted.patterns.count == 3)
        #expect(restarted.patterns.filter { $0.displayName == "Matching" }.count == 1)
        #expect(try harness.inbox.items().isEmpty)
        await #expect(throws: PatternInboxError.itemNotFound) {
            try await restarted.processPatternInboxItem(
                id: item.id,
                duplicateResolution: .createNew
            )
        }
        #expect(restarted.patterns.count == 3)
    }

    @Test func newAssetSidecarCommitFailureRecoversTheExactPublishedItem() async throws {
        let harness = try PatternImportHarness()
        let source = try harness.makePDF(named: "New.pdf")
        let item = try harness.inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: .now
        )
        let failingStore = JSONProjectStore(
            url: harness.archiveURL,
            patternFileService: PatternFileService(root: harness.assetsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: harness.inbox.root,
                writeData: { _, _ in throw PatternInboxProcessingInjectedFailure() }
            )
        )

        await #expect(throws: PatternInboxProcessingInjectedFailure.self) {
            try await failingStore.processPatternInboxItem(id: item.id)
        }
        let restarted = try harness.reopenedStore()

        #expect(restarted.patternAssets.count == 1)
        #expect(restarted.patterns.count == 1)
        #expect(restarted.patterns.first?.displayName == "New")
        #expect(try harness.inbox.items().isEmpty)
        await #expect(throws: PatternInboxError.itemNotFound) {
            try await restarted.processPatternInboxItem(id: item.id)
        }
    }

    @Test func existingSidecarCommitFailureRecoversTheExactPublishedItem() async throws {
        let harness = try PatternImportHarness()
        let source = try harness.makePDF(named: "Existing.pdf")
        _ = try await harness.importURL(source)
        try harness.store.add(name: "Target")
        let targetProjectID = try #require(harness.store.projects.first?.id)
        let existingID = try #require(harness.store.patterns.first?.id)
        let item = try harness.inbox.enqueue(
            source: source,
            origin: .project,
            targetProjectID: targetProjectID,
            now: .now
        )
        let failingStore = JSONProjectStore(
            url: harness.archiveURL,
            patternFileService: PatternFileService(root: harness.assetsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: harness.inbox.root,
                writeData: { _, _ in throw PatternInboxProcessingInjectedFailure() }
            )
        )

        await #expect(throws: PatternInboxProcessingInjectedFailure.self) {
            try await failingStore.processPatternInboxItem(id: item.id)
        }
        let restarted = try harness.reopenedStore()

        #expect(restarted.patternAssets.count == 1)
        #expect(restarted.patterns.map(\.id) == [existingID])
        #expect(restarted.patternUsages.count == 1)
        #expect(restarted.patternUsages.first?.patternID == existingID)
        #expect(restarted.patternUsages.first?.projectID == targetProjectID)
        #expect(restarted.patternUsages.first?.isActive == true)
        #expect(try harness.inbox.items().isEmpty)
        await #expect(throws: PatternInboxError.itemNotFound) {
            try await restarted.processPatternInboxItem(id: item.id)
        }
    }

    @Test func publicationReceiptCleanupFailureIsIdempotentAcrossRestarts() async throws {
        let harness = try PatternImportHarness()
        let source = try harness.makePDF(named: "Existing.pdf")
        _ = try await harness.importURL(source)
        let item = try harness.inbox.enqueue(
            source: source,
            origin: .shareExtension,
            targetProjectID: nil,
            now: .now
        )
        let receiptURL = harness.assetsRoot
            .appendingPathComponent("Assets/.PublicationReceipts", isDirectory: true)
            .appendingPathComponent("\(item.id.uuidString).json")
        let failingStore = JSONProjectStore(
            url: harness.archiveURL,
            patternFileService: PatternFileService(root: harness.assetsRoot),
            patternInboxFileService: PatternInboxFileService(root: harness.inbox.root),
            patternPublicationReceiptService: PatternInboxPublicationReceiptService(
                root: harness.assetsRoot,
                removeItem: { _ in throw PatternInboxProcessingInjectedFailure() }
            )
        )

        guard case .existing = try await failingStore.processPatternInboxItem(id: item.id) else {
            Issue.record("Expected the existing pattern outcome")
            return
        }
        #expect(FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(try harness.inbox.items().isEmpty)

        let firstRestart = try harness.reopenedStore()
        let secondRestart = try harness.reopenedStore()

        #expect(firstRestart.patterns.count == 1)
        #expect(secondRestart.patterns.count == 1)
        #expect(!FileManager.default.fileExists(atPath: receiptURL.path))
        #expect(try harness.inbox.items().isEmpty)
    }

    @Test func transientSidecarFailureCannotReplayCreateNewBeforeRestart() async throws {
        let harness = try await PatternImportHarness.withTwoNamesForOneAsset()
        for pattern in harness.store.patterns {
            try harness.store.renamePattern(id: pattern.id, to: "Matching")
        }
        let item = try harness.enqueueMatchingFile()
        let gate = PatternInboxOneShotWriteFailure()
        let recoveringStore = JSONProjectStore(
            url: harness.archiveURL,
            patternFileService: PatternFileService(root: harness.assetsRoot),
            patternInboxFileService: PatternInboxFileService(
                root: harness.inbox.root,
                writeData: { try gate.write($0, to: $1) }
            )
        )

        await #expect(throws: PatternInboxProcessingInjectedFailure.self) {
            try await recoveringStore.processPatternInboxItem(
                id: item.id,
                duplicateResolution: .createNew
            )
        }
        await #expect(throws: PatternInboxError.itemNotFound) {
            try await recoveringStore.processPatternInboxItem(
                id: item.id,
                duplicateResolution: .createNew
            )
        }

        #expect(recoveringStore.patternAssets.count == 1)
        #expect(recoveringStore.patterns.count == 3)
        #expect(try harness.inbox.items().isEmpty)
    }
}

private struct PatternInboxProcessingInjectedFailure: Error {}

private final class PatternInboxOneShotWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var didFail = false

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldFail = !didFail
        didFail = true
        lock.unlock()
        if shouldFail {
            throw PatternInboxProcessingInjectedFailure()
        }
        try data.write(to: url, options: .atomic)
    }
}
