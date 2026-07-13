import Testing
@testable import KnitNoteCore

@Suite struct ProjectCounterTests {
    @Test func completingRowAdvancesCount() {
        var project = KnittingProject(name: "米色圍巾")
        project.completeRow()
        #expect(project.currentRow == 1)
    }

    @Test func undoNeverProducesNegativeCount() {
        var project = KnittingProject(name: "Scarf")
        project.undoRow()
        #expect(project.currentRow == 0)
    }

    @Test func userNameSurvivesLanguageIndependentChanges() {
        var project = KnittingProject(name: "My 圍巾")
        project.completeRow()
        #expect(project.name == "My 圍巾")
    }
}
