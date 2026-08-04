import Foundation
import Testing

@Suite struct ProjectDetailLayoutContractTests {
    @Test func projectFeaturesFollowTheApprovedKnittingOrder() throws {
        let source = try projectSource()
        let photo = try #require(source.range(of: "ProjectCoverView("))
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
        #expect(counters.lowerBound < journal.lowerBound)
        #expect(journal.lowerBound < tools.lowerBound)
        #expect(tools.lowerBound < calculator.lowerBound)
    }

    @Test func populatedProjectContentUsesBerryLabels() throws {
        let detail = try projectSource()
        let journal = try source(at: "KnitNote/Projects/ProjectJournalSection.swift")

        #expect(detail.contains("isPopulated: hasActivePatterns"))
        #expect(detail.contains("$0.projectID == projectID && $0.isActive"))
        #expect(detail.contains("project.counters.contains { !$0.rowNotes.isEmpty }"))
        #expect(detail.contains("isPopulated: Bool"))
        #expect(detail.contains("isPopulated ? WatercolorTheme.actionBerry : Color.primary"))
        #expect(journal.contains("project.journalEntries.isEmpty ? Color.primary : WatercolorTheme.actionBerry"))
    }

    @Test func patternDetailUsesReadablePadWidthAndKeepsActionsInScrollableContent() throws {
        let source = try source(at: "KnitNote/Patterns/PatternDetailView.swift")
        let scroll = try #require(source.range(of: "ScrollView"))
        let linkCard = try #require(source.range(of: "actionsCard"))
        let deleteCard = try #require(source.range(of: "deletionCard"))

        #expect(source.contains(".frame(maxWidth: 760)"))
        #expect(scroll.lowerBound < linkCard.lowerBound)
        #expect(scroll.lowerBound < deleteCard.lowerBound)
    }

    @Test func dynamicTypeKeepsPatternLinkAndDeleteActionLabelsVisible() throws {
        let source = try source(at: "KnitNote/Patterns/PatternDetailView.swift")

        #expect(source.contains("Label(\"patterns.detail.linkProject\""))
        #expect(source.contains("Label(\"patterns.detail.delete\""))
        #expect(
            source.components(separatedBy: ".patternActionLabelLayout()").count >= 3
        )
    }

    @Test func projectPatternsSheetReceivesTheSelectedAppLocale() throws {
        let source = try projectSource()
        let sheetStart = try #require(
            source.range(of: ".sheet(isPresented: $showingPatterns)")
        )
        let remainingSource = source[sheetStart.lowerBound...]
        let sheetEnd = remainingSource.dropFirst().range(of: ".sheet")?.lowerBound
            ?? remainingSource.endIndex
        let sheetSource = remainingSource[..<sheetEnd]

        #expect(source.contains("@Environment(\\.locale) private var locale"))
        #expect(sheetSource.contains("ProjectPatternsView(projectID: projectID)"))
        #expect(sheetSource.contains(".environment(\\.locale, locale)"))
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
