import Foundation
import Combine

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
final class PatternInboxProcessor: ObservableObject, AppSessionProducer {
    @Published private(set) var pendingSelection: PendingInboxPatternSelection?
    @Published private(set) var failure: PatternInboxFailure?
    @Published private(set) var notice: PatternInboxNotice?

    private let driver: PatternInboxDriver
    private let backupReminderPresenter: PatternBackupReminderPresenter
    private let noticeDelay: @Sendable () async -> Void
    private var operationTask: Task<Void, Never>?
    private var noticeTasks: [UUID: Task<Void, Never>] = [:]
    private var currentNoticeTaskID: UUID?
    private var isStopped = false
    private var stoppedTasks: [Task<Void, Never>] = []

    convenience init(
        store: JSONProjectStore,
        backupReminderPresenter: PatternBackupReminderPresenter
    ) {
        self.init(
            driver: PatternInboxDriver(processing: PatternInboxStoreAdapter(store: store)),
            backupReminderPresenter: backupReminderPresenter
        )
    }

    init(
        driver: PatternInboxDriver,
        backupReminderPresenter: PatternBackupReminderPresenter,
        noticeDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(3))
        }
    ) {
        self.driver = driver
        self.backupReminderPresenter = backupReminderPresenter
        self.noticeDelay = noticeDelay
    }

    func stopForSessionTransition() {
        guard !isStopped else { return }
        isStopped = true
        stoppedTasks = [operationTask].compactMap { $0 } + Array(noticeTasks.values)
        clearStoppedPresentationState()
        stoppedTasks.forEach { $0.cancel() }
    }

    func waitForStoppedOperations() async throws {
        guard isStopped else {
            throw AppSessionProducerDrainError.producerStillActive
        }
        try Task.checkCancellation()
        for task in stoppedTasks {
            await task.value
        }
        try Task.checkCancellation()
    }

    func processPending() {
        guard !isStopped else { return }
        startOperation { [driver] in
            try await driver.processPending()
        }
    }

    func resolve(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) {
        guard !isStopped else { return }
        pendingSelection = nil
        startOperation { [driver] in
            try await driver.resolve(itemID: itemID, resolution: resolution)
        }
    }

    func retry() {
        guard !isStopped else { return }
        failure = nil
        processPending()
    }

    func dismissFailure() {
        guard !isStopped else { return }
        failure = nil
    }

    func discard() {
        guard !isStopped else { return }
        guard let itemID = failure?.itemID else { return }
        failure = nil
        startOperation { [driver] in
            try await driver.discard(itemID: itemID)
        }
    }

    private func startOperation(
        _ operation: @escaping @Sendable () async throws -> PatternInboxDriverUpdate
    ) {
        guard !isStopped, operationTask == nil else { return }
        operationTask = Task {
            defer { operationTask = nil }
            do {
                apply(try await operation())
            } catch is CancellationError {
                return
            } catch {
                _ = publishPresentationChange {
                    failure = PatternInboxFailure(itemID: nil)
                }
            }
        }
    }

    private func apply(_ update: PatternInboxDriverUpdate) {
        guard !isStopped, !update.isBusy else { return }
        let reminderCheckpoint = backupReminderPresenter.sessionPresentationCheckpoint()
        let reminderMutation = backupReminderPresenter.accept(update.imported)
        guard !isStopped else {
            backupReminderPresenter.restoreSessionPresentation(
                reminderCheckpoint,
                replacing: reminderMutation
            )
            clearStoppedPresentationState()
            return
        }
        if !update.imported.isEmpty {
            showNotice(importCount: update.imported.count)
            guard !isStopped else { return }
        }
        switch update.blocking {
        case let .selection(item, candidatePatternIDs):
            guard publishPresentationChange({ failure = nil }) else { return }
            _ = publishPresentationChange {
                pendingSelection = PendingInboxPatternSelection(
                    item: item,
                    candidatePatternIDs: candidatePatternIDs
                )
            }
        case let .failure(itemID):
            guard publishPresentationChange({ pendingSelection = nil }) else { return }
            _ = publishPresentationChange {
                failure = PatternInboxFailure(itemID: itemID)
            }
        case nil:
            guard publishPresentationChange({ pendingSelection = nil }) else { return }
            _ = publishPresentationChange { failure = nil }
        }
    }

    private func showNotice(importCount: Int) {
        guard !isStopped else { return }
        if let currentNoticeTaskID {
            noticeTasks[currentNoticeTaskID]?.cancel()
        }
        let value = PatternInboxNotice(importCount: importCount)
        guard publishPresentationChange({ notice = value }) else { return }

        let taskID = UUID()
        let task = Task { [noticeDelay] in
            defer { noticeTaskDidFinish(taskID) }
            await noticeDelay()
            guard !isStopped,
                  !Task.isCancelled,
                  notice?.id == value.id else { return }
            _ = publishPresentationChange { notice = nil }
        }
        currentNoticeTaskID = taskID
        noticeTasks[taskID] = task
    }

    private func noticeTaskDidFinish(_ taskID: UUID) {
        noticeTasks[taskID] = nil
        if currentNoticeTaskID == taskID {
            currentNoticeTaskID = nil
        }
    }

    private func publishPresentationChange(_ change: () -> Void) -> Bool {
        guard !isStopped else {
            clearStoppedPresentationState()
            return false
        }
        change()
        guard !isStopped else {
            clearStoppedPresentationState()
            return false
        }
        return true
    }

    private func clearStoppedPresentationState() {
        if pendingSelection != nil {
            pendingSelection = nil
        }
        if failure != nil {
            failure = nil
        }
        if notice != nil {
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
