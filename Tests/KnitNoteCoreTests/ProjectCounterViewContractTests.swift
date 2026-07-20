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

    @Test func projectDetailPlacesCountersBeforeNotesAndPatterns() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let notes = try #require(source.range(of: "projectActionCard(\"notes.edit\""))

        #expect(counters.lowerBound < notes.lowerBound)
    }

    @Test func projectDetailShowsPhotoOrDefaultIconBeforeCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let photo = try #require(source.range(of: "ProjectPhotoView(url: store.photoURL(for: project))"))
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

    @Test func counterManagementButtonsHaveIndependentFormRowActions() throws {
        let source = try projectSource(named: "EditCounterNameView")
        let independentStyles = source.components(separatedBy: ".buttonStyle(.borderless)").count - 1

        #expect(independentStyles == 2)
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
        try String(
            contentsOf: repositoryRoot.appending(path: "KnitNote/Projects/\(name).swift"),
            encoding: .utf8
        )
    }
}
