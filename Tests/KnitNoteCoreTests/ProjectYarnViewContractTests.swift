import Foundation
import Testing

@Suite("Project yarn view contracts")
struct ProjectYarnViewContractTests {
    @Test func projectPlacesUsedYarnBetweenCountersAndJournal() throws {
        let source = try sourceText("KnitNote/Projects/ProjectDetailView.swift")
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let yarn = try #require(source.range(of: "ProjectYarnSection("))
        let journal = try #require(source.range(of: "ProjectJournalSection("))

        #expect(counters.lowerBound < yarn.lowerBound)
        #expect(yarn.lowerBound < journal.lowerBound)
        #expect(source.contains("isEditable: !project.isCompleted"))
    }

    @Test func projectSectionReadsInverseLinksAndKeepsCompletedProjectsReadOnly() throws {
        let source = try sourceText("KnitNote/Projects/ProjectYarnSection.swift")

        #expect(source.contains("store.yarns(linkedTo: projectID)"))
        #expect(source.contains("ChooseProjectYarnsView("))
        #expect(source.contains("if isEditable"))
        #expect(source.contains("YarnDetailView(yarnID: yarn.id)"))
    }

    @Test func projectPickerStagesChangesUntilDoneAndExplainsUnlinking() throws {
        let source = try sourceText("KnitNote/Projects/ChooseProjectYarnsView.swift")

        #expect(source.contains("@State private var selectedYarnIDs"))
        #expect(source.contains("store.setProjectYarns("))
        #expect(source.contains("YarnLinkSelectionMerge.merged("))
        #expect(source.contains("Button(\"common.done\")"))
        #expect(source.contains("Button(\"common.cancel\")"))
        #expect(source.contains("confirmationDialog"))
        #expect(source.contains("project.yarn.unlink.message"))
    }

    @Test func yarnSidePickerCannotChangeCompletedProjectLinks() throws {
        let source = try sourceText("KnitNote/Yarn/ChooseYarnProjectsView.swift")

        #expect(source.contains(".disabled(project.isCompleted)"))
        #expect(source.contains("project.yarn.completed.readOnly"))
    }

    @Test func yarnLibraryCannotDeleteCompletedProjectHistory() throws {
        let source = try sourceText("KnitNote/Yarn/YarnLibraryView.swift")

        #expect(source.contains(".disabled(hasCompletedProjectLink(yarn))"))
        #expect(source.contains("yarn.error.completedProjectLink"))
    }

    @Test func yarnEditorMergesItsLinkDeltaWithTheLatestStoreValue() throws {
        let source = try sourceText("KnitNote/Yarn/EditYarnView.swift")

        #expect(source.contains("initialLinkedProjectIDs"))
        #expect(source.contains("YarnLinkSelectionMerge.merged("))
    }

    private func sourceText(_ relativePath: String) throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }
}
