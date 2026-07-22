import Foundation
import Testing

@Suite struct ProjectDetailLayoutContractTests {
    @Test func projectFeaturesFollowTheApprovedKnittingOrder() throws {
        let source = try projectSource()
        let photo = try #require(source.range(of: "ProjectPhotoView("))
        let pattern = try #require(source.range(of: "projectActionCard(\"patterns.open\""))
        let note = try #require(source.range(of: "projectActionCard(\"notes.edit\""))
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let tools = try #require(source.range(of: "if hasToolDetails(project)"))
        let calculator = try #require(source.range(of: "KnittingCalculatorsView()"))
        let journal = try #require(source.range(of: "ProjectJournalSection("))

        #expect(photo.lowerBound < pattern.lowerBound)
        #expect(pattern.lowerBound < note.lowerBound)
        #expect(note.lowerBound < counters.lowerBound)
        #expect(counters.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < calculator.lowerBound)
        #expect(calculator.lowerBound < journal.lowerBound)
    }

    private func projectSource() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appending(path: "KnitNote/Projects/ProjectDetailView.swift"),
            encoding: .utf8
        )
    }
}
