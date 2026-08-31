import Foundation
import Testing

@Suite struct KnittingReminderPresentationTests {
    @Test func coordinatorDefinesStableSingleItemQueueAndBoundedHapticLedger() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderPresentationCoordinator.swift")

        #expect(source.contains("struct KnittingReminderPresentationCoordinator"))
        #expect(source.contains("mutating func update(project: StoredProject)"))
        #expect(source.contains("private(set) var current"))
        #expect(source.contains("private(set) var totalCount"))
        #expect(source.contains("markHapticPresented(occurrenceID:"))
        #expect(source.contains("shouldPlayHaptic(for occurrence:"))
        #expect(source.contains("formIntersection"))
        #expect(source.contains("originalTarget"))
        #expect(source.contains("createdAt"))
        #expect(source.contains("uuidString"))
    }

    @Test func coordinatorAdvancesByPersistedOccurrenceIdentity() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderPresentationCoordinator.swift")

        #expect(source.contains("occurrence.id"))
        #expect(source.contains("occurrence.reminderID"))
        #expect(source.contains("reminder.mutationRevision"))
        #expect(source.contains("visibleOccurrences(at:"))
        #expect(source.contains("queue.first"))
    }

    @Test func queueCardOffersPhaseSpecificActionsAndExactStoreIdentity() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderQueueCard.swift")

        #expect(source.contains("struct KnittingReminderQueueCard: View"))
        #expect(source.contains("store.applyKnittingReminderAction("))
        #expect(source.contains("reminderID: current.occurrence.reminderID"))
        #expect(source.contains("occurrenceID: current.occurrence.id"))
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
}
