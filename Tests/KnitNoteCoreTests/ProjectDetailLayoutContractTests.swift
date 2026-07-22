import Foundation
import Testing

@Suite struct ProjectDetailLayoutContractTests {
    @Test func projectFeaturesFollowTheApprovedKnittingOrder() throws {
        let source = try projectSource()
        let photo = try #require(source.range(of: "ProjectPhotoView("))
        let completion = try #require(source.range(of: "if project.isCompleted"))
        let pattern = try #require(source.range(of: "projectActionCard(\"patterns.open\""))
        let note = try #require(source.range(of: "projectActionCard(\"notes.edit\""))
        let recentNotes = try #require(source.range(of: "let sortedNotes"))
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let tools = try #require(source.range(of: "if hasToolDetails(project)"))
        let calculator = try #require(source.range(of: "KnittingCalculatorsView()"))
        let journal = try #require(source.range(of: "ProjectJournalSection("))

        #expect(photo.lowerBound < pattern.lowerBound)
        #expect(photo.lowerBound < completion.lowerBound)
        #expect(completion.lowerBound < pattern.lowerBound)
        #expect(pattern.lowerBound < note.lowerBound)
        #expect(note.lowerBound < recentNotes.lowerBound)
        #expect(recentNotes.lowerBound < counters.lowerBound)
        #expect(counters.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < calculator.lowerBound)
        #expect(calculator.lowerBound < journal.lowerBound)
    }

    @Test func populatedProjectContentUsesBerryLabels() throws {
        let detail = try projectSource()
        let journal = try source(at: "KnitNote/Projects/ProjectJournalSection.swift")

        #expect(detail.contains("isPopulated: !project.patterns.isEmpty"))
        #expect(detail.contains("project.counters.contains { !$0.rowNotes.isEmpty }"))
        #expect(detail.contains("isPopulated: Bool"))
        #expect(detail.contains("isPopulated ? WatercolorTheme.actionBerry : Color.primary"))
        #expect(journal.contains("project.journalEntries.isEmpty ? Color.primary : WatercolorTheme.actionBerry"))
    }

    private func projectSource() throws -> String {
        try source(at: "KnitNote/Projects/ProjectDetailView.swift")
    }

    private func source(at relativePath: String) throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: relativePath),
            encoding: .utf8
        )
    }
}
