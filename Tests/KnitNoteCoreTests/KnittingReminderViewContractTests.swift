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
        #expect(source.contains("observedRevision: capturedReminderRevision"))
        #expect(source.contains("Text(verbatim: customText)"))
        #expect(source.contains("KnittingReminderDraftValidation.issue("))
        #expect(source.contains("validationIssue == .firstTarget"))
        #expect(source.contains("validationIssue == .interval"))
        #expect(source.contains("validationIssue == .limit"))
    }

    @Test func editorFailsClosedForDeletedEditsAndUsesItsInitiallyLoadedRevision() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderEditorView.swift")

        #expect(source.contains("@State private var capturedReminderRevision: UInt64?"))
        #expect(source.contains("capturedReminderRevision = reminder.mutationRevision"))
        #expect(source.contains("guard let capturedReminderRevision else"))
        #expect(source.contains("knittingReminder.error.unavailable"))
        #expect(source.contains("if let reminderID {"))
        #expect(source.contains("reminderID: reminderID"))
        #expect(source.contains("observedRevision: capturedReminderRevision"))
        #expect(!source.contains("observedRevision: reminder.mutationRevision"))
        #expect(source.contains("isExistingReminderUnavailable"))

        let updateRange = try #require(source.range(of: "try store.updateKnittingReminder("))
        let addRange = try #require(source.range(of: "try store.addKnittingReminder("))
        #expect(updateRange.lowerBound < addRange.lowerBound)
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
        #expect(!source.contains("fallback:"))
        #expect(!source.contains("text.localized"))
    }

    @Test func reminderSurfacesKeepUserTextVerbatimAndMacKeyboardActionsScoped() throws {
        let list = try sourceFile("KnitNote/Projects/KnittingReminderListView.swift")
        let editor = try sourceFile("KnitNote/Projects/KnittingReminderEditorView.swift")
        let card = try sourceFile("KnitNote/Projects/KnittingReminderQueueCard.swift")

        #expect(list.contains("Text(verbatim: text)"))
        #expect(editor.contains("Text(verbatim: customText)"))
        #expect(card.contains("Text(verbatim: text)"))
        #expect(card.contains("ViewThatFits(in: .horizontal)"))
        #expect(card.components(separatedBy: ".frame(minWidth: 44, minHeight: 44)").count - 1 >= 4)
        #expect(card.contains("private func summaryContent(for current:"))
        #expect(card.contains(".accessibilityElement(children: .ignore)"))
        #expect(card.contains(".accessibilityLabel(Text(verbatim: accessibilitySummary(for: current)))"))
        #expect(card.contains("KnittingReminderAccessibilityProjection(presentation: current)"))
        #expect(!card.contains(".accessibilityElement(children: .contain)"))
        #expect(!card.contains(".accessibilityValue(Text(verbatim: accessibilitySummary(for: current)))"))
        #expect(card.contains(".keyboardShortcut(.cancelAction)"))
        #expect(editor.contains(".keyboardShortcut(.defaultAction)"))
        #expect(editor.contains(".keyboardShortcut(.cancelAction)"))
    }

    @Test func everyReminderSurfaceUsesCatalogCopyWithoutEnglishFallbacks() throws {
        let list = try sourceFile("KnitNote/Projects/KnittingReminderListView.swift")
        let editor = try sourceFile("KnitNote/Projects/KnittingReminderEditorView.swift")
        let card = try sourceFile("KnitNote/Projects/KnittingReminderQueueCard.swift")
        let summary = try sourceFile("KnitNote/Projects/KnittingReminderSummary.swift")
        let combined = [list, editor, card, summary].joined(separator: "\n")

        for english in [
            "Project unavailable", "Add reminder", "Delete reminder?",
            "Stop reminder", "Reset reminder", "Reminder kind", "Optional note",
            "Reminder schedule", "One time", "Repeating", "First row", "Interval",
            "Limited repetitions", "Number of times", "Summary", "New reminder",
            "Edit reminder", "This reminder is no longer available.",
        ] {
            #expect(
                !combined.contains("\"" + english + "\""),
                "Raw reminder copy must be localized: \(english)"
            )
        }
        #expect(!summary.contains("fallback:"))
        #expect(!card.contains("fallback:"))
        #expect(list.contains("KnittingReminderSummary.error(error, locale: locale)"))
        #expect(editor.contains("KnittingReminderSummary.error(error, locale: locale)"))
        #expect(card.contains("KnittingReminderSummary.error(error, locale: locale)"))
    }

    @Test func listShowsNonColorStateAndSecondaryCounterLabelsWithConfirmedMutations() throws {
        let source = try sourceFile("KnitNote/Projects/KnittingReminderListView.swift")

        #expect(source.contains("KnittingReminderSummary.state(reminder.state, locale: locale)"))
        #expect(source.contains("KnittingReminderSummary.secondaryCounter("))
        #expect(source.contains("knittingReminder.confirm.stop"))
        #expect(source.contains("knittingReminder.confirm.reset"))
        #expect(source.contains("knittingReminder.confirm.delete"))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
    }

    @Test func cardAndEditorExposeMacPrimaryAndCancelShortcutsWithoutHijackingFields() throws {
        let editor = try sourceFile("KnitNote/Projects/KnittingReminderEditorView.swift")
        let card = try sourceFile("KnitNote/Projects/KnittingReminderQueueCard.swift")

        #expect(editor.components(separatedBy: ".keyboardShortcut(.defaultAction)").count - 1 == 1)
        #expect(editor.components(separatedBy: ".keyboardShortcut(.cancelAction)").count - 1 == 1)
        #expect(card.components(separatedBy: ".keyboardShortcut(.defaultAction)").count - 1 == 1)
        #expect(card.contains(".keyboardShortcut(.cancelAction)"))

        #expect(keyboardShortcutsAreButtonScoped(in: editor))
        #expect(keyboardShortcutsAreButtonScoped(in: card))
        #expect(!keyboardShortcutsAreButtonScoped(in: "TextField(\"Row\", text: $row).keyboardShortcut(.defaultAction)"))
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

    private func keyboardShortcutsAreButtonScoped(in source: String) -> Bool {
        var searchStart = source.startIndex
        while let shortcut = source.range(
            of: ".keyboardShortcut(",
            range: searchStart..<source.endIndex
        ) {
            let prefix = source[..<shortcut.lowerBound]
            guard let button = prefix.range(of: "Button", options: .backwards) else { return false }
            if let textField = prefix.range(of: "TextField", options: .backwards),
               textField.lowerBound > button.lowerBound {
                return false
            }
            searchStart = shortcut.upperBound
        }
        return true
    }
}
