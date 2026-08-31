import Foundation
import Testing

@Suite struct KnittingReminderViewContractTests {
    @Test func listProjectsActiveAndEndedRemindersInStableOrder() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderListView.swift")

        #expect(source.contains("struct KnittingReminderListView: View"))
        #expect(source.contains("private func ordered(_ reminders: [KnittingReminder])"))
        #expect(source.contains("lhs.progress.nextTarget ?? Int.max"))
        #expect(source.contains("lhs.createdAt"))
        #expect(source.contains("lhs.id.uuidString"))
        #expect(source.contains("Section(\"knittingReminder.section.active\")"))
        #expect(source.contains("Section(\"knittingReminder.section.ended\")"))
    }

    @Test func listCreatesOnlyMainCounterRemindersAndLabelsMigratedSecondaryRules() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderListView.swift")

        #expect(source.contains("project.mainCounterID"))
        #expect(source.contains("reminder.counterID != project.mainCounterID"))
        #expect(source.contains("projectCounterDisplayName(counter, locale: locale)"))
        #expect(source.contains("KnittingReminderEditorView(projectID: projectID, reminderID: reminder.id)"))
    }

    @Test func editorValidatesIntegerDraftBeforeAtomicCreateOrUpdate() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderEditorView.swift")

        #expect(source.contains("CounterValueInput.parse(firstTargetText)"))
        #expect(source.contains("CounterValueInput.parse(intervalText)"))
        #expect(source.contains("CounterValueInput.parse(limitText)"))
        #expect(source.contains("return .oneTime(kind: kind, target: firstTarget, text: text)"))
        #expect(source.contains("return .repeating("))
        #expect(source.contains("store.addKnittingReminder(projectID: projectID, draft: draft)"))
        #expect(source.contains("store.updateKnittingReminder("))
        #expect(source.contains("observedRevision: reminder.mutationRevision"))
        #expect(source.contains("Text(verbatim: customText)"))
    }

    @Test func listMutationsUseExactReminderIdentityAndRevision() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderListView.swift")

        #expect(source.contains("store.applyKnittingReminderAction("))
        #expect(source.contains("reminderID: reminder.id"))
        #expect(source.contains("observedRevision: reminder.mutationRevision"))
        #expect(source.contains("store.deleteKnittingReminder("))
        #expect(source.contains("if project.isCompleted"))
    }

    @Test func summaryLocalizesSystemCopyWithoutChangingVerbatimText() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderSummary.swift")

        #expect(source.contains("enum KnittingReminderSummary"))
        #expect(source.contains("LocaleAwareText.string"))
        #expect(source.contains("return copy == key ? fallback : copy"))
        #expect(!source.contains("text.localized"))
    }

    @Test func counterManagerHasNoLegacyCreationAffordanceButKeepsSecondaryEditLink() throws {
        let source = try sourceFile("KnitNote/Projects/CounterManagerView.swift")

        #expect(!source.contains("CounterReminderEditor("))
        #expect(!source.contains("CounterReminderDraft"))
        #expect(source.contains("KnittingReminderEditorView(projectID: projectID, reminderID: reminderID)"))
        #expect(source.contains("counter.id != mainCounterID"))
    }

    private func sourceFile(_ path: String) throws -> String {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }
}
