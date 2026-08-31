import Foundation
import Testing

@Suite struct CounterReminderViewContractTests {
    @Test func managerDoesNotKeepTheLegacyReminderCreationFlow() throws {
        let source = try sourceFile("KnitNote/Projects/CounterManagerView.swift")

        #expect(!source.contains("CounterReminderEditor("))
        #expect(!source.contains("CounterReminderDraft"))
        #expect(!source.contains("CounterReminderEdit"))
    }

    @Test func reminderCardHasExactlyTheApprovedActions() throws {
        let source = try sourceFile("KnitNote/Patterns/CounterReminderCard.swift")

        #expect(source.contains("struct CounterReminderCard: View"))
        #expect(source.contains("let pending: CounterReminderPending"))
        #expect(source.contains("let message: String?"))
        #expect(source.contains("let onComplete: () -> Void"))
        #expect(source.contains("let onStop: () -> Void"))
        #expect(source.contains("counter.reminder.complete"))
        #expect(source.contains("counter.reminder.stop"))
        #expect(!source.lowercased().contains("snooze"))
        #expect(!source.lowercased().contains("later"))
    }

    @Test func reminderCardShowsCombinedOccurrencesUsingTheCurrentLocale() throws {
        let source = try sourceFile("KnitNote/Patterns/CounterReminderCard.swift")

        #expect(source.contains("pending.occurrenceCount"))
        #expect(source.contains("pending.lastTarget"))
        #expect(source.contains("counter.reminder.crossedCount"))
        #expect(source.contains("counter.reminder.reached"))
        #expect(source.contains(".formatted(.number.locale(locale))"))
        #expect(source.contains("Text(verbatim: message)"))
        #expect(source.contains("return \"\\(reachedCopy) · \\(crossedCountCopy)\""))
    }

    @Test func reminderCardNeverRendersTheReachedFormatKeyWithoutItsRowArgument() throws {
        let source = try sourceFile("KnitNote/Patterns/CounterReminderCard.swift")

        #expect(!source.contains("Label(\"counter.reminder.reached\""))
        #expect(source.contains("Text(localizedCopy(key: \"counter.reminder.reached\", value: pending.lastTarget))"))
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }
}
