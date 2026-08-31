import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnittingReminderPresentationTests {
    @Test func coordinatorDefinesStableSingleItemQueueAndBoundedHapticLedger() throws {
        let source = try sourceFile("Sources/KnitNoteCore/Projects/KnittingReminderPresentationCoordinator.swift")

        #expect(source.contains("struct KnittingReminderPresentationCoordinator"))
        #expect(source.contains("KnittingReminderPresentationStore"))
        #expect(source.contains("mutating func update(project: StoredProject)"))
        #expect(source.contains("private(set) var current"))
        #expect(source.contains("private(set) var totalCount"))
        #expect(source.contains("markHapticPresented(occurrenceID:"))
        #expect(source.contains("shouldPlayHaptic(for occurrence:"))
        #expect(source.contains("formIntersection"))
        #expect(source.contains("activeLeasesByProject"))
        #expect(source.contains("acquireSurface"))
        #expect(source.contains("releaseSurface"))
        #expect(source.contains("generation"))
        #expect(source.contains("originalTarget"))
        #expect(source.contains("createdAt"))
        #expect(source.contains("uuidString"))
    }

    @Test func coordinatorAdvancesByPersistedOccurrenceIdentity() throws {
        let source = try sourceFile("Sources/KnitNoteCore/Projects/KnittingReminderPresentationCoordinator.swift")

        #expect(source.contains("occurrence.id"))
        #expect(source.contains("occurrence.reminderID"))
        #expect(source.contains("reminder.mutationRevision"))
        #expect(source.contains("visibleOccurrences(at:"))
        #expect(source.contains("queue.first"))
    }

    @Test func coordinatorOrdersVisibleOccurrencesAcrossOwningCounters() throws {
        let mainID = UUID()
        let secondaryID = UUID()
        var mainReminder = try #require(KnittingReminder(
            id: UUID(),
            counterID: mainID,
            draft: .oneTime(kind: .changeYarn, target: 3, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        mainReminder = try mainReminder.applying(.trigger(through: 3))
        var secondaryReminder = try #require(KnittingReminder(
            id: UUID(),
            counterID: secondaryID,
            draft: .oneTime(kind: .measure, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        secondaryReminder = try secondaryReminder.applying(.trigger(through: 2))
        let project = try StoredProject(
            id: UUID(),
            name: "Queue",
            counters: [
                ProjectCounter(id: mainID, defaultOrdinal: 1, value: 3),
                ProjectCounter(id: secondaryID, defaultOrdinal: 2, value: 2),
            ],
            knittingReminders: [mainReminder, secondaryReminder]
        )

        var coordinator = KnittingReminderPresentationCoordinator()
        coordinator.update(project: project)

        #expect(coordinator.totalCount == 2)
        #expect(coordinator.current?.occurrence.originalTarget == 2)
        #expect(coordinator.current?.occurrence.reminderID == secondaryReminder.id)
    }

    @Test func coordinatorUsesTheOwningCounterForDeferredSecondaryOccurrences() throws {
        let mainID = UUID()
        let secondaryID = UUID()
        var secondaryReminder = try #require(KnittingReminder(
            counterID: secondaryID,
            draft: .oneTime(kind: .measure, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        secondaryReminder = try secondaryReminder.applying(.trigger(through: 1))
        let occurrence = try #require(secondaryReminder.progress.pending.first)
        secondaryReminder = try secondaryReminder.applying(
            .deferOnce(
                occurrenceID: occurrence.id,
                observedRevision: secondaryReminder.mutationRevision
            )
        )
        var project = try StoredProject(
            id: UUID(),
            name: "Secondary queue",
            counters: [
                ProjectCounter(id: mainID, defaultOrdinal: 1, value: 0),
                ProjectCounter(id: secondaryID, defaultOrdinal: 2, value: 1),
            ],
            knittingReminders: [secondaryReminder]
        )
        var coordinator = KnittingReminderPresentationCoordinator()
        coordinator.update(project: project)
        #expect(coordinator.current == nil)

        _ = project.incrementCounter(id: mainID)
        coordinator.update(project: project)
        #expect(coordinator.current == nil)

        let evaluation = KnittingReminderEvaluator.evaluate(
            oldValue: 1,
            newValue: 2,
            reminders: [secondaryReminder]
        )
        project = try StoredProject(
            id: project.id,
            name: project.name,
            counters: [
                ProjectCounter(id: mainID, defaultOrdinal: 1, value: 1),
                ProjectCounter(id: secondaryID, defaultOrdinal: 2, value: 2),
            ],
            knittingReminders: evaluation.reminders
        )
        coordinator.update(project: project)
        #expect(coordinator.current?.occurrence.id == occurrence.id)
        #expect(coordinator.current?.phase == .deferredOnce)
    }

    @Test @MainActor func presentationStoreSharesHapticsAcrossSurfacesAndIsolatesProjects() throws {
        let projectID = UUID()
        let (project, occurrence) = try presentationProject(id: projectID)
        let store = KnittingReminderPresentationStore()

        #expect(store.update(project: project)?.id == occurrence.id)
        #expect(store.update(project: project)?.id == occurrence.id)
        #expect(store.shouldPlayHaptic(for: occurrence, projectID: projectID))
        store.markHapticPresented(occurrenceID: occurrence.id, projectID: projectID)
        #expect(!store.shouldPlayHaptic(for: occurrence, projectID: projectID))
        #expect(store.update(project: project)?.id == occurrence.id)
        #expect(!store.shouldPlayHaptic(for: occurrence, projectID: projectID))

        var completedReminder = try #require(project.knittingReminders.first)
        completedReminder = try completedReminder.applying(
            .complete(
                occurrenceID: occurrence.id,
                observedRevision: completedReminder.mutationRevision
            )
        )
        let completedProject = try StoredProject(
            id: projectID,
            name: project.name,
            counters: project.counters,
            knittingReminders: [completedReminder]
        )
        #expect(store.update(project: completedProject) == nil)

        let (replacementProject, replacementOccurrence) = try presentationProject(id: projectID)
        #expect(store.update(project: replacementProject)?.id == replacementOccurrence.id)
        #expect(store.shouldPlayHaptic(for: replacementOccurrence, projectID: projectID))

        let secondProjectID = UUID()
        let (secondProject, secondOccurrence) = try presentationProject(id: secondProjectID)
        #expect(store.update(project: secondProject)?.id == secondOccurrence.id)
        #expect(store.shouldPlayHaptic(for: secondOccurrence, projectID: secondProjectID))
    }

    @Test @MainActor func visibleSurfaceMustClaimHapticAndHiddenDetailCannotConsumeIt() throws {
        let projectID = UUID()
        let (project, occurrence) = try presentationProject(id: projectID)
        let store = KnittingReminderPresentationStore()
        let detailSurfaceID = UUID()
        let readerSurfaceID = UUID()

        let detailLease = store.acquireSurface(projectID: projectID, surfaceID: detailSurfaceID)
        #expect(store.update(project: project)?.id == occurrence.id)

        // The detail remains mounted during navigation. The reader overlays it
        // and becomes the sole claimant before either card refreshes.
        let readerLease = store.acquireSurface(projectID: projectID, surfaceID: readerSurfaceID)
        #expect(store.update(project: project)?.id == occurrence.id)
        #expect(!store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: detailLease
        ))

        #expect(store.update(project: project)?.id == occurrence.id)
        #expect(store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: readerLease
        ))
        #expect(!store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: readerLease
        ))

        store.releaseSurface(projectID: projectID, lease: readerLease)
        #expect(store.update(project: project)?.id == occurrence.id)
        #expect(!store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: detailLease
        ))

        let oldReminder = try #require(project.knittingReminders.first)
        let completedOldReminder = try oldReminder.applying(.complete(
            occurrenceID: occurrence.id,
            observedRevision: oldReminder.mutationRevision
        ))
        var reminder = try #require(KnittingReminder(
            counterID: oldReminder.counterID,
            draft: .oneTime(kind: .custom, target: 2, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        reminder = try reminder.applying(.trigger(through: 2))
        let futureProject = try StoredProject(
            id: projectID,
            name: project.name,
            counters: project.counters.map {
                ProjectCounter(id: $0.id, defaultOrdinal: $0.defaultOrdinal, value: 2)
            },
            knittingReminders: [completedOldReminder, reminder]
        )
        #expect(store.update(project: futureProject)?.occurrence.id == reminder.progress.pending[0].id)
        #expect(store.claimHaptic(
            for: reminder.progress.pending[0],
            projectID: projectID,
            lease: detailLease
        ))
    }

    @Test @MainActor func presentationStorePrunesDeletedProjectsWithoutCrossProjectLedgerLeakage() throws {
        let deletedProjectID = UUID()
        let (deletedProject, deletedOccurrence) = try presentationProject(id: deletedProjectID)
        let retainedProjectID = UUID()
        let (retainedProject, retainedOccurrence) = try presentationProject(id: retainedProjectID)
        let store = KnittingReminderPresentationStore()
        let deletedSurfaceID = UUID()
        let retainedSurfaceID = UUID()

        let deletedLease = store.acquireSurface(projectID: deletedProjectID, surfaceID: deletedSurfaceID)
        #expect(store.update(project: deletedProject)?.id == deletedOccurrence.id)
        #expect(store.claimHaptic(
            for: deletedOccurrence,
            projectID: deletedProjectID,
            lease: deletedLease
        ))
        let retainedLease = store.acquireSurface(projectID: retainedProjectID, surfaceID: retainedSurfaceID)
        #expect(store.update(project: retainedProject)?.id == retainedOccurrence.id)
        #expect(store.claimHaptic(
            for: retainedOccurrence,
            projectID: retainedProjectID,
            lease: retainedLease
        ))
        store.pruneProjects(keeping: [retainedProjectID])

        // Reusing the deleted project ID starts with a fresh coordinator and
        // cannot inherit the old project's haptic claim.
        let replacement = try presentationProject(id: deletedProjectID)
        let replacementLease = store.acquireSurface(projectID: deletedProjectID, surfaceID: deletedSurfaceID)
        #expect(replacementLease.generation > deletedLease.generation)
        #expect(store.update(project: replacement.0)?.id == replacement.1.id)
        #expect(store.claimHaptic(
            for: replacement.1,
            projectID: deletedProjectID,
            lease: replacementLease
        ))
        store.releaseSurface(projectID: deletedProjectID, lease: deletedLease)
        #expect(store.isActive(replacementLease))
        #expect(store.update(project: retainedProject)?.id == retainedOccurrence.id)
        #expect(!store.shouldPlayHaptic(for: retainedOccurrence, projectID: retainedProjectID))
    }

    @Test @MainActor func surfaceLeasesAreGenerationSafeAndReleaseOutOfOrder() throws {
        let projectID = UUID()
        let (project, occurrence) = try presentationProject(id: projectID)
        let store = KnittingReminderPresentationStore()
        let surfaceID = UUID()
        let overlayID = UUID()

        let firstLease = store.acquireSurface(projectID: projectID, surfaceID: surfaceID)
        #expect(store.acquireSurface(projectID: projectID, surfaceID: surfaceID) == firstLease)
        store.releaseSurface(projectID: projectID, lease: firstLease)
        let reacquiredLease = store.acquireSurface(projectID: projectID, surfaceID: surfaceID)
        #expect(reacquiredLease.generation > firstLease.generation)
        store.releaseSurface(projectID: projectID, lease: firstLease)
        #expect(store.isActive(reacquiredLease))
        #expect(store.update(project: project)?.id == occurrence.id)

        let overlayLease = store.acquireSurface(projectID: projectID, surfaceID: overlayID)
        #expect(!store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: reacquiredLease
        ))
        #expect(store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: overlayLease
        ))
        store.releaseSurface(projectID: projectID, lease: reacquiredLease)
        store.releaseSurface(projectID: projectID, lease: overlayLease)
        #expect(!store.claimHaptic(
            for: occurrence,
            projectID: projectID,
            lease: reacquiredLease
        ))
    }

    @Test func coordinatorRefreshesAfterAuthoritativeCompleteDeferAndSkip() throws {
        let counterID = UUID()
        var reminder = try #require(KnittingReminder(
            counterID: counterID,
            draft: .oneTime(kind: .custom, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        reminder = try reminder.applying(.trigger(through: 1))
        let occurrence = try #require(reminder.progress.pending.first)
        let baseProject = try StoredProject(
            id: UUID(),
            name: "Authoritative refresh",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, value: 1)],
            knittingReminders: [reminder]
        )
        var coordinator = KnittingReminderPresentationCoordinator()

        coordinator.update(project: baseProject)
        #expect(coordinator.current?.id == occurrence.id)

        let completed = try reminder.applying(.complete(
            occurrenceID: occurrence.id,
            observedRevision: reminder.mutationRevision
        ))
        let completedProject = try StoredProject(
            id: baseProject.id,
            name: baseProject.name,
            counters: baseProject.counters,
            knittingReminders: [completed]
        )
        coordinator.update(project: completedProject)
        #expect(coordinator.current == nil)

        var deferredReminder = try #require(KnittingReminder(
            counterID: counterID,
            draft: .oneTime(kind: .custom, target: 1, text: nil),
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        deferredReminder = try deferredReminder.applying(.trigger(through: 1))
        let deferredID = try #require(deferredReminder.progress.pending.first).id
        deferredReminder = try deferredReminder.applying(.deferOnce(
            occurrenceID: deferredID,
            observedRevision: deferredReminder.mutationRevision
        ))
        let deferredProject = try StoredProject(
            id: baseProject.id,
            name: baseProject.name,
            counters: baseProject.counters,
            knittingReminders: [deferredReminder]
        )
        coordinator.update(project: deferredProject)
        #expect(coordinator.current == nil)
        let released = KnittingReminderEvaluator.evaluate(
            oldValue: 1,
            newValue: 2,
            reminders: [deferredReminder]
        )
        let releasedProject = try StoredProject(
            id: baseProject.id,
            name: baseProject.name,
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, value: 2)],
            knittingReminders: released.reminders
        )
        coordinator.update(project: releasedProject)
        #expect(coordinator.current?.id == deferredID)

        let skipped = try deferredReminder.applying(.skip(
            occurrenceID: deferredID,
            observedRevision: deferredReminder.mutationRevision
        ))
        let skippedProject = try StoredProject(
            id: baseProject.id,
            name: baseProject.name,
            counters: baseProject.counters,
            knittingReminders: [skipped]
        )
        coordinator.update(project: skippedProject)
        #expect(coordinator.current == nil)
    }

    @Test func coordinatorPrunesMultiOccurrenceHapticLedgerAndRefreshesReplacement() throws {
        let counterID = UUID()
        var reminder = try #require(KnittingReminder(
            counterID: counterID,
            draft: .repeating(kind: .custom, firstTarget: 1, interval: 1, limit: 3, text: nil),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        reminder = try reminder.applying(.trigger(through: 3))
        let projectID = UUID()
        var project = try StoredProject(
            id: projectID,
            name: "Ledger",
            counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, value: 3)],
            knittingReminders: [reminder]
        )
        var coordinator = KnittingReminderPresentationCoordinator()

        coordinator.update(project: project)
        let first = try #require(coordinator.current)
        #expect(coordinator.shouldPlayHaptic(for: first.occurrence))
        coordinator.markHapticPresented(occurrenceID: first.id)
        #expect(!coordinator.shouldPlayHaptic(for: first.occurrence))

        reminder = try reminder.applying(.complete(
            occurrenceID: first.id,
            observedRevision: reminder.mutationRevision
        ))
        project = try StoredProject(
            id: projectID,
            name: project.name,
            counters: project.counters,
            knittingReminders: [reminder]
        )
        coordinator.update(project: project)
        let second = try #require(coordinator.current)
        #expect(second.id != first.id)
        #expect(coordinator.shouldPlayHaptic(for: second.occurrence))
        coordinator.markHapticPresented(occurrenceID: second.id)

        reminder = try reminder.applying(.skip(
            occurrenceID: second.id,
            observedRevision: reminder.mutationRevision
        ))
        project = try StoredProject(
            id: projectID,
            name: project.name,
            counters: project.counters,
            knittingReminders: [reminder]
        )
        coordinator.update(project: project)
        let third = try #require(coordinator.current)
        #expect(third.id != first.id)
        #expect(third.id != second.id)
        #expect(coordinator.shouldPlayHaptic(for: third.occurrence))

        reminder = try reminder.applying(.complete(
            occurrenceID: third.id,
            observedRevision: reminder.mutationRevision
        ))
        project = try StoredProject(
            id: projectID,
            name: project.name,
            counters: project.counters,
            knittingReminders: [reminder]
        )
        coordinator.update(project: project)
        #expect(coordinator.current == nil)
        #expect(coordinator.shouldPlayHaptic(for: first.occurrence))
    }

    @Test @MainActor func staleActionFollowedByAuthoritativeRefreshAdvancesPresentation() throws {
        let harness = try KnittingReminderStoreHarness(triggeredReminder: true)
        defer { harness.removeFiles() }
        let initialProject = try #require(harness.store.project(id: harness.projectID))
        let initialReminder = try #require(initialProject.knittingReminders.first)
        let occurrence = try #require(initialReminder.progress.pending.first)
        var coordinator = KnittingReminderPresentationCoordinator()
        coordinator.update(project: initialProject)
        #expect(coordinator.current?.id == occurrence.id)

        #expect(throws: KnittingReminderMutationError.staleRevision) {
            try harness.store.applyKnittingReminderAction(
                projectID: harness.projectID,
                reminderID: initialReminder.id,
                occurrenceID: occurrence.id,
                observedRevision: initialReminder.mutationRevision &+ 1,
                action: .complete
            )
        }
        #expect(coordinator.current?.id == occurrence.id)

        // A later authoritative mutation succeeds; the next refresh removes
        // the handled occurrence instead of retaining stale card state.
        try harness.store.applyKnittingReminderAction(
            projectID: harness.projectID,
            reminderID: initialReminder.id,
            occurrenceID: occurrence.id,
            observedRevision: initialReminder.mutationRevision,
            action: .complete
        )
        coordinator.update(project: try #require(harness.store.project(id: harness.projectID)))
        #expect(coordinator.current == nil)
    }

    @Test func queueCardOffersPhaseSpecificActionsAndExactStoreIdentity() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderQueueCard.swift")

        #expect(source.contains("struct KnittingReminderQueueCard: View"))
        #expect(source.contains("store.applyKnittingReminderAction("))
        #expect(source.contains("reminderID: current.occurrence.reminderID"))
        #expect(source.contains("occurrenceID: occurrenceID"))
        #expect(source.contains("occurrenceID = current.occurrence.id"))
        #expect(source.contains("observedRevision: current.reminderRevision"))
        #expect(source.contains(".complete"))
        #expect(source.contains(".deferOnce"))
        #expect(source.contains(".skip"))
        #expect(source.contains(".stop"))
        #expect(source.contains("Text(verbatim:"))
        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(source.contains("frame(minWidth: 44, minHeight: 44)"))
        #expect(source.contains("accessibilityValue"))
        #expect(source.contains("sensoryFeedback"))
        #expect(source.contains("presentationStore"))
        #expect(source.contains("claimHaptic("))
        #expect(source.contains("lease"))
        #expect(source.contains("authoritativeProject"))
    }

    @Test func bothProductionSurfacesUseOnlyTheSharedQueueCard() throws {
        let detail = try sourceFile("KnitNote/Projects/ProjectDetailView.swift")
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(detail.components(separatedBy: "KnittingReminderQueueCard(").count - 1 == 1)
        #expect(reader.components(separatedBy: "KnittingReminderQueueCard(").count - 1 == 1)
        #expect(!detail.contains("CounterReminderCard"))
        #expect(!reader.contains("CounterReminderCard"))
        #expect(!detail.contains("completeCounterReminder"))
        #expect(!reader.contains("completeCounterReminder"))
    }

    @Test func rootReconcilesPresentationStoreWithAuthoritativeProjects() throws {
        let root = try sourceFile("KnitNote/App/RootView.swift")
        #expect(root.contains("reminderPresentationStore.pruneProjects"))
        #expect(root.contains("Set(projects.map(\\.id))"))
    }

    @Test func queueCardDoesNotMutateProjectLocallyAndLegacyCardIsRemoved() throws {
        let card = try sourceFile("KnitNote/Projects/KnittingReminderQueueCard.swift")
        #expect(!card.contains("project.knittingReminders ="))
        #expect(!card.contains("project.counters ="))

        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent("KnitNote/Patterns/CounterReminderCard.swift").path))
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }

    private func presentationProject(id: UUID) throws -> (StoredProject, KnittingReminderOccurrence) {
        let counterID = UUID()
        var reminder = try #require(KnittingReminder(
            counterID: counterID,
            draft: .oneTime(kind: .custom, target: 1, text: "Do not translate"),
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        reminder = try reminder.applying(.trigger(through: 1))
        let occurrence = try #require(reminder.progress.pending.first)
        return (
            try StoredProject(
                id: id,
                name: "Haptic",
                counters: [ProjectCounter(id: counterID, defaultOrdinal: 1, value: 1)],
                knittingReminders: [reminder]
            ),
            occurrence
        )
    }
}
