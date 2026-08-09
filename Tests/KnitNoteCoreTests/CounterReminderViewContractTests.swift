import Foundation
import Testing

@Suite struct CounterReminderViewContractTests {
    @Test func reminderEditorExposesTheApprovedDraftBoundaryAndControls() throws {
        let source = try sourceFile("KnitNote/Projects/CounterReminderEditor.swift")

        #expect(source.contains("struct CounterReminderEditor: View"))
        #expect(source.contains("@Binding var draft: CounterReminderDraft?"))
        #expect(source.contains("let counterValue: Int"))
        #expect(source.contains("counter.reminder.mode.oneTime"))
        #expect(source.contains("counter.reminder.mode.repeating"))
        #expect(source.contains("counter.reminder.target"))
        #expect(source.contains("counter.reminder.interval"))
        #expect(source.contains("counter.reminder.limit"))
        #expect(source.contains("counter.reminder.message"))
    }

    @Test func reminderEditorRejectsInvalidTargetsIntervalsAndFiniteCounts() throws {
        let source = try sourceFile("KnitNote/Projects/CounterReminderEditor.swift")

        #expect(source.contains("target > counterValue"))
        #expect(source.contains("interval > 0"))
        #expect(source.contains("limit > 0"))
        #expect(source.contains(".disabled(validDraft == nil)"))
    }

    @Test func reminderEditorTrimsCustomCopyAndNormalizesEmptyCopyToNil() throws {
        let source = try sourceFile("KnitNote/Projects/CounterReminderEditor.swift")

        #expect(source.contains("trimmingCharacters(in: .whitespacesAndNewlines)"))
        #expect(source.contains("trimmedMessage.isEmpty ? nil : trimmedMessage"))
        #expect(source.contains("TextField(\"counter.reminder.message\", text: $messageText"))
    }

    @Test func managerConfirmsReplacingAReminderThatAlreadyHasProgress() throws {
        let source = try sourceFile("KnitNote/Projects/CounterManagerView.swift")

        #expect(source.contains("CounterReminderEditor(draft: $reminderDraft, counterValue:"))
        #expect(source.contains("counter.reminder?.acknowledgedCount ?? 0) > 0"))
        #expect(source.contains("counter.reminder?.pending != nil"))
        #expect(source.contains(".confirmationDialog(\"counter.reminder.replace\""))
        #expect(source.contains("reminderEdit: reminderEdit"))
    }

    @Test func managerRevalidatesAReplacementAgainstTheValueThatWillBeSaved() throws {
        let source = try sourceFile("KnitNote/Projects/CounterManagerView.swift")

        #expect(source.contains("private var hasValidReminderEdit: Bool"))
        #expect(source.contains("CounterReminder(draft: draft, anchorValue: value) != nil"))
        #expect(source.contains(".disabled(!hasValidReminderEdit)"))
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

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }
}
