import SwiftUI

@MainActor
final class PatternBackupReminderPresenter: ObservableObject {
    @Published private(set) var isPresented: Bool
    @Published private(set) var isShowingBackupSettings: Bool
    private var coordinator: PatternBackupReminderCoordinator
    private var nextMutationID: UInt64 = 0
    private var lastMutationID: UInt64?
    private var isPublishing = false

    init(history: BackupHistory = .init()) {
        let coordinator = PatternBackupReminderCoordinator(history: history)
        self.coordinator = coordinator
        isPresented = coordinator.isPresented
        isShowingBackupSettings = coordinator.isShowingBackupSettings
    }

    func accept(_ outcome: PatternImportOutcome) {
        _ = mutateCoordinator { $0.accept(outcome) }
    }

    @discardableResult
    func accept(_ outcomes: [PatternImportOutcome]) -> SessionPresentationMutation {
        mutateCoordinator { $0.accept(outcomes) }
    }

    func acceptCreatedPattern() {
        _ = mutateCoordinator { $0.acceptCreatedPattern() }
    }

    func dismiss(openBackupSettings: Bool) {
        _ = mutateCoordinator {
            $0.dismiss(openBackupSettings: openBackupSettings)
        }
    }

    func closeBackupSettings() {
        _ = mutateCoordinator { $0.closeBackupSettings() }
    }

    private func publish() {
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        while true {
            let mutationID = lastMutationID
            let presented = coordinator.isPresented
            let showingBackupSettings = coordinator.isShowingBackupSettings
            isPresented = presented
            isShowingBackupSettings = showingBackupSettings
            guard lastMutationID != mutationID else { return }
        }
    }

    @discardableResult
    private func mutateCoordinator(
        _ mutation: (inout PatternBackupReminderCoordinator) -> Void
    ) -> SessionPresentationMutation {
        let wasPresented = coordinator.isPresented
        let wasShowingBackupSettings = coordinator.isShowingBackupSettings
        mutation(&coordinator)

        let mutationID: UInt64?
        if coordinator.isPresented != wasPresented
            || coordinator.isShowingBackupSettings != wasShowingBackupSettings {
            nextMutationID &+= 1
            mutationID = nextMutationID
            lastMutationID = mutationID
        } else {
            mutationID = nil
        }
        publish()
        return SessionPresentationMutation(id: mutationID)
    }
}

extension PatternBackupReminderPresenter {
    struct SessionPresentationCheckpoint {
        fileprivate let coordinator: PatternBackupReminderCoordinator
    }

    struct SessionPresentationMutation {
        fileprivate let id: UInt64?
    }

    func sessionPresentationCheckpoint() -> SessionPresentationCheckpoint {
        SessionPresentationCheckpoint(
            coordinator: coordinator
        )
    }

    func restoreSessionPresentation(
        _ checkpoint: SessionPresentationCheckpoint,
        replacing mutation: SessionPresentationMutation
    ) {
        guard let mutationID = mutation.id,
              lastMutationID == mutationID else { return }
        coordinator = checkpoint.coordinator
        nextMutationID &+= 1
        lastMutationID = nextMutationID
        publish()
    }
}
