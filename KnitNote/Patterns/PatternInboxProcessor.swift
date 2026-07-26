import Foundation

struct PendingInboxPatternSelection: Identifiable {
    let item: PatternInboxItem
    let candidatePatternIDs: [UUID]
    var id: UUID { item.id }
}

struct PatternInboxFailure: Identifiable {
    let itemID: UUID?
    let id = UUID()
}

struct PatternInboxNotice: Identifiable {
    let id = UUID()
    let importCount: Int
}

@MainActor
final class PatternInboxProcessor: ObservableObject {
    @Published private(set) var pendingSelection: PendingInboxPatternSelection?
    @Published private(set) var failure: PatternInboxFailure?
    @Published private(set) var notice: PatternInboxNotice?

    private let driver: PatternInboxDriver
    private var operationTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(store: JSONProjectStore) {
        driver = PatternInboxDriver(processing: PatternInboxStoreAdapter(store: store))
    }

    func processPending() {
        startOperation { [driver] in
            try await driver.processPending()
        }
    }

    func resolve(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) {
        pendingSelection = nil
        startOperation { [driver] in
            try await driver.resolve(itemID: itemID, resolution: resolution)
        }
    }

    func retry() {
        failure = nil
        processPending()
    }

    func discard() {
        guard let itemID = failure?.itemID else { return }
        failure = nil
        startOperation { [driver] in
            try await driver.discard(itemID: itemID)
        }
    }

    private func startOperation(
        _ operation: @escaping @Sendable () async throws -> PatternInboxDriverUpdate
    ) {
        guard operationTask == nil else { return }
        operationTask = Task {
            defer { operationTask = nil }
            do {
                apply(try await operation())
            } catch is CancellationError {
                return
            } catch {
                failure = PatternInboxFailure(itemID: nil)
            }
        }
    }

    private func apply(_ update: PatternInboxDriverUpdate) {
        guard !update.isBusy else { return }
        if !update.imported.isEmpty {
            showNotice(importCount: update.imported.count)
        }
        switch update.blocking {
        case let .selection(item, candidatePatternIDs):
            failure = nil
            pendingSelection = PendingInboxPatternSelection(
                item: item,
                candidatePatternIDs: candidatePatternIDs
            )
        case let .failure(itemID):
            pendingSelection = nil
            failure = PatternInboxFailure(itemID: itemID)
        case nil:
            pendingSelection = nil
            failure = nil
        }
    }

    private func showNotice(importCount: Int) {
        noticeTask?.cancel()
        let value = PatternInboxNotice(importCount: importCount)
        notice = value
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, notice?.id == value.id else { return }
            notice = nil
        }
    }
}

private final class PatternInboxStoreAdapter: PatternInboxProcessing, @unchecked Sendable {
    private let store: JSONProjectStore

    @MainActor
    init(store: JSONProjectStore) {
        self.store = store
    }

    func pendingItems() async throws -> [PatternInboxItem] {
        try await store.pendingPatternInboxItems()
    }

    func process(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome {
        try await store.processPatternInboxItem(
            id: itemID,
            duplicateResolution: resolution
        )
    }

    func discard(itemID: UUID) async throws {
        try await store.discardPatternInboxItem(id: itemID)
    }
}
