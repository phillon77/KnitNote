import Foundation
import Testing

@Suite struct ProjectCounterViewContractTests {
    @Test func projectDetailUsesCompactTapAndLongPressCounterControls() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("CounterSelectorGrid("))
        #expect(source.contains("onIncrement:"))
        #expect(source.contains("onManage:"))
        #expect(!source.contains("project.completeRow"))
        #expect(!source.contains("project.undo"))
    }

    @Test func projectDetailPlacesNotesBeforeCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let notes = try #require(source.range(of: "projectActionCard(\"notes.edit\""))

        #expect(notes.lowerBound < counters.lowerBound)
    }

    @Test func projectDetailShowsPhotoOrDefaultIconBeforeCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let photo = try #require(source.range(of: "ProjectCoverView(project: project)"))
        let counters = try #require(source.range(of: "CounterSelectorGrid("))

        #expect(photo.lowerBound < counters.lowerBound)
        #expect(source.contains(".frame(width: 96, height: 96)"))
        #expect(source.contains(".clipShape(.rect(cornerRadius: 22))"))
    }

    @Test func projectDetailRoutesNotesThroughCompositeCounterRowSelections() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("CounterRowSelection("))
        #expect(source.contains("counterID: project.selectedCounterID"))
        #expect(source.contains("row: project.selectedCounter.value"))
        #expect(source.contains("AllNotesView(projectID: projectID, counterID: project.selectedCounterID)"))
        #expect(source.contains("counterID: selection.counterID"))
        #expect(source.contains("row: selection.row"))
    }

    @Test func noteViewsUseCounterScopedStoreAPIs() throws {
        let editSource = try projectSource(named: "EditRowNoteView")
        let notesSource = try projectSource(named: "AllNotesView")

        #expect(editSource.contains("let counterID: UUID"))
        #expect(editSource.contains("store.saveNote(projectID: projectID, counterID: counterID, row: row, text: text)"))
        #expect(editSource.contains("note(counterID: counterID, row: row)"))
        #expect(notesSource.contains("let counterID: UUID"))
        #expect(notesSource.contains("selectedCounter.rowNotes.sorted { $0.row > $1.row }"))
        #expect(notesSource.contains("store.deleteNote(projectID: projectID, counterID: counterID, row: note.row)"))
    }

    @Test func projectCardDoesNotShowCounterDetailsBelowTheProjectName() throws {
        let source = try projectSource(named: "ProjectCard")

        #expect(!source.contains("projectCounterDisplayName"))
        #expect(!source.contains("project.selectedCounter.value"))
        #expect(!source.contains("Text(\"project.currentRow\")"))
    }

    @Test func selectorShowsFullNamesAndUsesTapAndLongPress() throws {
        let source = try projectSource(named: "CounterSelectorGrid")

        #expect(source.contains(".counterActionTouchTarget()"))
        #expect(source.contains("projectCounterDisplayName(counter, locale: locale)"))
        #expect(source.contains("onIncrement(counter.id)"))
        #expect(source.contains("onLongPressGesture"))
        #expect(source.contains("onManage(counter.id)"))
    }

    @Test func counterManagerKeepsValueEditingAndEssentialControlsVisible() throws {
        let source = try projectSource(named: "CounterManagerView")

        #expect(source.contains("TextField(\"counter.value\""))
        #expect(source.contains("ViewThatFits"))
        #expect(source.contains("Button(\"counter.reset\""))
        #expect(!source.contains(".presentationDetents([.medium])"))
    }

    @Test func counterManagerUsesCompactEqualWidthValueControlsWithFullAccessibilityLabels() throws {
        let source = try projectSource(named: "CounterManagerView")
        let decrement = try #require(sourceSection(
            source,
            from: "private var decrementButton:",
            to: "private var incrementButton:"
        ))
        let increment = try #require(sourceSection(
            source,
            from: "private var incrementButton:",
            to: "private var resetButton:"
        ))
        let reset = try #require(sourceSection(
            source,
            from: "private var resetButton:",
            to: "private var currentValue:"
        ))

        #expect(decrement.contains("adjustValue(by: -1)"))
        #expect(decrement.contains("Text(\"−1\")"))
        #expect(decrement.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 1)
        #expect(decrement.contains(".disabled(currentValue == 0)"))
        #expect(decrement.contains(".accessibilityLabel(Text(\"counter.minusOne\"))"))

        #expect(increment.contains("adjustValue(by: 1)"))
        #expect(increment.contains("Text(\"+1\")"))
        #expect(increment.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 1)
        #expect(increment.contains(".disabled(currentValue == .max)"))
        #expect(increment.contains(".accessibilityLabel(Text(\"counter.increment\"))"))

        #expect(reset.contains("Image(systemName: \"arrow.counterclockwise\")"))
        #expect(reset.contains("Text(\"0\")"))
        #expect(reset.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 1)
        #expect(reset.contains("role: .destructive"))
        #expect(reset.contains("confirmingValueReset = true"))
        #expect(reset.contains(".accessibilityLabel(Text(\"counter.reset\"))"))
        #expect(source.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 3)
    }

    @Test func counterManagerUsesExplicitPlatformSizingWithoutScrollDependentEssentials() throws {
        let source = try projectSource(named: "CounterManagerView")

        #expect(source.contains("private enum CounterManagerPresentationPolicy"))
        #expect(source.contains("static let iPadWidth: CGFloat = 720"))
        #expect(source.contains("static let iPadHeight: CGFloat = 560"))
        #expect(source.contains("UIDevice.current.userInterfaceIdiom == .pad"))
        #expect(source.contains("CounterManagerPresentationPolicy.iPadWidth"))
        #expect(source.contains("CounterManagerPresentationPolicy.iPhoneWidth"))
        #expect(source.contains("CounterManagerPresentationPolicy.macMinimumWidth"))
        #expect(!source.contains("ScrollView"))
    }

    @Test func counterManagerConfirmsResetAndExposesSemanticValidationAndReminderContent() throws {
        let source = try projectSource(named: "CounterManagerView")

        #expect(source.contains("@State private var confirmingValueReset = false"))
        #expect(source.contains(".confirmationDialog(\"counter.reset\""))
        #expect(source.contains("Text(\"counter.value.invalid\")"))
        #expect(source.contains(".accessibilityLabel(Text(reminderSummary))"))
        #expect(source.contains(".accessibilityValue(Text(reminderSummary))"))
        #expect(source.contains("counter.reminder.none"))
        #expect(source.contains("counter.reminder.nextTarget"))
    }

    @Test func projectCounterManagerKeepsItsSheetOpenWithTheSelectedAppLanguageWhenTheStoreRejects() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("guard let _ = try store.manageCounter("))
        #expect(source.contains("LocaleAwareText.string(\"counter.error.notSaved\", locale: locale)"))
        #expect(!source.contains("String(localized: \"counter.error.notSaved\")"))
        #expect(!source.contains("try store.updateCounter(projectID:"))
    }

    @Test func projectCounterManagerPersistsValueNameAndReminderInOneTransaction() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("try store.manageCounter("))
        #expect(source.contains("projectID: projectID"))
        #expect(source.contains("counterID: counter.id"))
        #expect(source.contains("name: save.name"))
        #expect(source.contains("value: save.value"))
        #expect(source.contains("reminder: save.reminderEdit"))
        #expect(!source.contains("try store.configureCounterReminder("))
    }

    @Test func projectDetailShowsSelectedPendingReminderBelowCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let reminderSection = try #require(sourceSection(
            source,
            from: "CounterSelectorGrid(",
            to: "ProjectYarnSection("
        ))

        #expect(reminderSection.contains("project.selectedCounter.reminder"))
        #expect(reminderSection.contains("if let pending = reminder.pending"))
        #expect(reminderSection.contains("CounterReminderCard("))
        #expect(reminderSection.contains("pending: pending"))
        #expect(reminderSection.contains("message: reminder.message"))
        #expect(reminderSection.contains("completeProjectCounterReminder("))
        #expect(reminderSection.contains("stopProjectCounterReminder("))

        let card = try #require(sourceSection(
            source,
            from: "CounterReminderCard(",
            to: "WatercolorCard {\n                            ProjectYarnSection("
        ))
        let normalizedCard = normalized(card)
        #expect(normalizedCard.contains("pending:pending,message:reminder.message,onComplete:{completeProjectCounterReminder(counterID:counterID,pending:pending)},onStop:{stopProjectCounterReminder(counterID:counterID,pending:pending)}"))
        #expect(card.components(separatedBy: "completeProjectCounterReminder(").count - 1 == 1)
        #expect(card.components(separatedBy: "stopProjectCounterReminder(").count - 1 == 1)
    }

    @Test func projectDetailReminderActionsAreStoreBackedAndFailClosed() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let complete = normalized(try #require(sourceSection(
            source,
            from: "private func completeProjectCounterReminder(",
            to: "private func stopProjectCounterReminder("
        )))
        let stop = normalized(try #require(sourceSection(
            source,
            from: "private func stopProjectCounterReminder(",
            to: "private func reminderActionFailed("
        )))

        #expect(complete.contains("guardletcurrentProject=store.project(id:projectID),currentProject.selectedCounterID==counterID,letcurrentCounter=currentProject.counters.first(where:{$0.id==counterID}),currentCounter.id==counterID,letcurrentReminder=currentCounter.reminder,currentReminder.id==pending.reminderID,letcurrentPending=currentReminder.pending,currentPending.reminderID==pending.reminderID,currentPending.occurrenceCount==pending.occurrenceCountelse{reminderActionFailed()return}"))
        #expect(complete.contains("letdataGenerationBefore=store.dataGenerationtrystore.completeCounterReminder(projectID:projectID,counterID:counterID,reminderID:pending.reminderID,observedCount:pending.occurrenceCount)guardstore.dataGeneration>dataGenerationBefore,letupdatedProject=store.project(id:projectID),updatedProject.selectedCounterID==counterID,letupdatedCounter=updatedProject.counters.first(where:{$0.id==counterID}),updatedCounter.id==counterID,letupdatedReminder=updatedCounter.reminder,updatedReminder.id==pending.reminderID,updatedReminder.pending==nilelse{reminderActionFailed()return}"))
        #expect(complete.contains("catch{counterSaveError=error.localizedDescription}"))
        #expect(complete.components(separatedBy: "trystore.completeCounterReminder(").count - 1 == 1)
        #expect(complete.components(separatedBy: "reminderActionFailed()").count - 1 == 2)

        #expect(stop.contains("guardletcurrentProject=store.project(id:projectID),currentProject.selectedCounterID==counterID,letcurrentCounter=currentProject.counters.first(where:{$0.id==counterID}),currentCounter.id==counterID,letcurrentReminder=currentCounter.reminder,currentReminder.id==pending.reminderID,currentReminder.isActive==true,letcurrentPending=currentReminder.pending,currentPending.reminderID==pending.reminderID,currentPending.occurrenceCount==pending.occurrenceCountelse{reminderActionFailed()return}"))
        #expect(stop.contains("letdataGenerationBefore=store.dataGenerationtrystore.stopCounterReminder(projectID:projectID,counterID:counterID,reminderID:pending.reminderID)guardstore.dataGeneration>dataGenerationBefore,letupdatedProject=store.project(id:projectID),updatedProject.selectedCounterID==counterID,letupdatedCounter=updatedProject.counters.first(where:{$0.id==counterID}),updatedCounter.id==counterID,letupdatedReminder=updatedCounter.reminder,updatedReminder.id==pending.reminderID,updatedReminder.pending==nil,updatedReminder.isActive!=trueelse{reminderActionFailed()return}"))
        #expect(stop.contains("catch{counterSaveError=error.localizedDescription}"))
        #expect(stop.components(separatedBy: "trystore.stopCounterReminder(").count - 1 == 1)
        #expect(stop.components(separatedBy: "reminderActionFailed()").count - 1 == 2)
    }

    @Test func rejectedDirectReminderSaveKeepsTheManagerOpen() throws {
        let detail = try projectSource(named: "ProjectDetailView")
        let manager = try projectSource(named: "CounterManagerView")
        let save = try #require(sourceSection(
            detail,
            from: "private func saveCounter(",
            to: "private var hasActivePatterns"
        ))

        #expect(save.contains("guard let _ = try store.manageCounter("))
        #expect(save.contains("return false"))
        #expect(manager.contains("if onSave(savedCounter) { dismiss() }"))
    }

    @Test func reminderAccessibilityKeepsLocalizedSemanticsActionsAndAdaptiveHeight() throws {
        let manager = try projectSource(named: "CounterManagerView")
        let card = try source("KnitNote/Patterns/CounterReminderCard.swift")
        let watch = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(manager.contains(".accessibilityLabel(Text(\"counter.value.edit\"))"))
        #expect(!manager.contains(".accessibilityLabel(Text(\"counter.value\"))"))
        #expect(manager.contains("counter.reminder.nextTarget"))
        #expect(manager.contains(".accessibilityValue(Text(reminderSummary))"))

        #expect(card.contains("return \"\\(reachedCopy) · \\(crossedCountCopy)\""))
        #expect(card.contains(".accessibilityHint(Text(\"counter.reminder.complete.hint\"))"))
        #expect(card.contains(".accessibilityHint(Text(\"counter.reminder.stop.hint\"))"))
        #expect(card.components(separatedBy: ".frame(minHeight: 44)").count - 1 == 2)
        #expect(card.contains("ViewThatFits(in: .horizontal)"))
        #expect(!card.contains(".frame(height:"))
        #expect(card.contains("Text(verbatim: message)"))

        let watchReminder = try #require(sourceSection(
            watch,
            from: "private func reminderConfirmation(",
            to: "private func activeCounterRow"
        ))
        #expect(watchReminder.contains(".accessibilityHint(Text(\"counter.reminder.complete.hint\"))"))
        #expect(watchReminder.contains(".accessibilityHint(Text(\"counter.reminder.stop.hint\"))"))
        #expect(watchReminder.components(separatedBy: ".frame(minHeight: 44)").count - 1 == 2)
        #expect(!watchReminder.contains(".frame(height:"))
        #expect(!watchReminder.contains(".lineLimit("))
        #expect(watchReminder.contains("Text(verbatim: message)"))
    }

    @Test func completionUIShowsStatusAndLocksProjectCounters() throws {
        let edit = try projectSource(named: "EditProjectView")
        let detail = try projectSource(named: "ProjectDetailView")
        let card = try projectSource(named: "ProjectCard")
        let selector = try projectSource(named: "CounterSelectorGrid")

        #expect(edit.contains("store.markCompleted(projectID: projectID)"))
        #expect(edit.contains("store.resumeProject(projectID: projectID)"))
        #expect(detail.contains("isEnabled: !project.isCompleted"))
        #expect(detail.contains("project.status.completed"))
        #expect(card.contains("project.isCompleted"))
        #expect(card.contains("project.status.completed"))
        #expect(selector.contains("let isEnabled: Bool"))
        #expect(selector.contains("guard isEnabled else { return }"))
    }

    @Test func projectEditorAndDetailSupportOptionalToolDetails() throws {
        let edit = try projectSource(named: "EditProjectView")
        let detail = try projectSource(named: "ProjectDetailView")

        #expect(edit.contains("Section(\"project.tool.section\")"))
        #expect(edit.contains("Picker(\"project.tool.type\""))
        #expect(edit.contains("TextField(\"project.tool.size\""))
        #expect(edit.contains("TextField(\"project.tool.notes\""))
        #expect(edit.contains("toolType: toolType"))
        #expect(edit.contains("toolSize: toolSize"))
        #expect(edit.contains("toolNotes: toolNotes"))
        #expect(detail.contains("hasToolDetails(project)"))
        #expect(detail.contains("Text(\"project.tool.section\")"))
        #expect(detail.contains("if let toolType = project.toolType"))
        #expect(detail.contains("if let toolSize = project.toolSize"))
        #expect(detail.contains("if let toolNotes = project.toolNotes"))
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func projectSource(named name: String) throws -> String {
        try source("KnitNote/Projects/\(name).swift")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }

    private func sourceSection(_ source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func normalized(_ source: String) -> String {
        String(source.filter { !$0.isWhitespace })
    }
}
