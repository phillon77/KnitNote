import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor
struct ProjectYarnLinkTests {
    @Test func selectionMergePreservesConcurrentChangesOutsideTheUserDelta() {
        let first = UUID()
        let concurrent = UUID()

        #expect(YarnLinkSelectionMerge.merged(
            initial: [first],
            edited: [],
            current: [first, concurrent]
        ) == [concurrent])
        #expect(YarnLinkSelectionMerge.merged(
            initial: [first],
            edited: [first],
            current: [first, concurrent]
        ) == [first, concurrent])
    }

    @Test func projectReturnsEveryLinkedYarnInLibraryOrder() throws {
        let store = makeStore()
        try store.add(name: "Cardigan")
        let project = try #require(store.projects.first)
        let first = try StoredYarn(name: "Merino")
        let second = try StoredYarn(name: "Cotton")
        let third = try StoredYarn(name: "Silk")
        try store.addYarn(first)
        try store.addYarn(second)
        try store.addYarn(third)
        let expectedOrder = store.yarns
            .filter { [first.id, third.id].contains($0.id) }
            .map(\.id)

        try store.setProjectYarns(projectID: project.id, yarnIDs: [third.id, first.id])

        #expect(store.yarns(linkedTo: project.id).map(\.id) == expectedOrder)
        #expect(store.yarn(id: second.id)?.linkedProjectIDs.isEmpty == true)
    }

    @Test func unlinkPersistsWithoutDeletingYarn() throws {
        let url = temporaryArchiveURL()
        let store = JSONProjectStore(url: url)
        try store.add(name: "Hat")
        let project = try #require(store.projects.first)
        let yarn = try StoredYarn(name: "Wool")
        try store.addYarn(yarn)
        try store.setProjectYarns(projectID: project.id, yarnIDs: [yarn.id])

        try store.setProjectYarns(projectID: project.id, yarnIDs: [])

        let reloaded = JSONProjectStore(url: url)
        #expect(reloaded.yarn(id: yarn.id) != nil)
        #expect(reloaded.yarn(id: yarn.id)?.linkedProjectIDs.isEmpty == true)
        #expect(reloaded.yarns(linkedTo: project.id).isEmpty)
    }

    @Test func missingProjectOrYarnRejectsWithoutPartialMutation() throws {
        let url = temporaryArchiveURL()
        let store = JSONProjectStore(url: url)
        try store.add(name: "Scarf")
        let project = try #require(store.projects.first)
        let yarn = try StoredYarn(name: "Alpaca")
        try store.addYarn(yarn)
        let committed = try Data(contentsOf: url)

        #expect(throws: ProjectYarnLinkError.projectNotFound) {
            try store.setProjectYarns(projectID: UUID(), yarnIDs: [yarn.id])
        }
        #expect(throws: ProjectYarnLinkError.yarnNotFound) {
            try store.setProjectYarns(projectID: project.id, yarnIDs: [yarn.id, UUID()])
        }

        #expect(store.yarn(id: yarn.id)?.linkedProjectIDs.isEmpty == true)
        #expect(try Data(contentsOf: url) == committed)
    }

    @Test func legacyYarnSideMissingYarnRemainsANoOp() throws {
        let url = temporaryArchiveURL()
        let store = JSONProjectStore(url: url)
        try store.add(name: "Scarf")
        let project = try #require(store.projects.first)
        let committed = try Data(contentsOf: url)

        try store.setYarnProjects(yarnID: UUID(), projectIDs: [project.id])

        #expect(try Data(contentsOf: url) == committed)
    }

    @Test func completedProjectRejectsProjectSideLinkChanges() throws {
        let url = temporaryArchiveURL()
        let store = JSONProjectStore(url: url)
        try store.add(name: "Finished sweater")
        let project = try #require(store.projects.first)
        let yarn = try StoredYarn(name: "Merino")
        try store.addYarn(yarn)
        try store.setProjectYarns(projectID: project.id, yarnIDs: [yarn.id])
        try store.markCompleted(projectID: project.id)
        let committed = try Data(contentsOf: url)

        #expect(throws: ProjectYarnLinkError.projectCompleted) {
            try store.setProjectYarns(projectID: project.id, yarnIDs: [])
        }

        #expect(store.yarn(id: yarn.id)?.linkedProjectIDs == [project.id])
        #expect(try Data(contentsOf: url) == committed)
    }

    @Test func completedProjectRejectsYarnSideLinkChangesButAllowsDetailEdits() throws {
        let store = makeStore()
        try store.add(name: "Finished sweater")
        let project = try #require(store.projects.first)
        let yarn = try StoredYarn(name: "Merino")
        try store.addYarn(yarn)
        try store.setProjectYarns(projectID: project.id, yarnIDs: [yarn.id])
        try store.markCompleted(projectID: project.id)

        #expect(throws: ProjectYarnLinkError.projectCompleted) {
            try store.setYarnProjects(yarnID: yarn.id, projectIDs: [])
        }

        var edited = try #require(store.yarn(id: yarn.id))
        try edited.rename(to: "Fine Merino")
        try store.updateYarn(edited)
        #expect(store.yarn(id: yarn.id)?.name == "Fine Merino")
        #expect(store.yarn(id: yarn.id)?.linkedProjectIDs == [project.id])
    }

    @Test func completedProjectCannotBeLinkedByAddingOrUpdatingAYarn() throws {
        let store = makeStore()
        try store.add(name: "Finished sweater")
        let project = try #require(store.projects.first)
        try store.markCompleted(projectID: project.id)

        var newYarn = try StoredYarn(name: "New wool")
        newYarn.setLinkedProjectIDs([project.id])
        #expect(throws: ProjectYarnLinkError.projectCompleted) {
            try store.addYarn(newYarn)
        }

        var existingYarn = try StoredYarn(name: "Existing wool")
        try store.addYarn(existingYarn)
        existingYarn.setLinkedProjectIDs([project.id])
        #expect(throws: ProjectYarnLinkError.projectCompleted) {
            try store.updateYarn(existingYarn)
        }
        #expect(store.yarn(id: existingYarn.id)?.linkedProjectIDs.isEmpty == true)
    }

    @Test func yarnLinkedToACompletedProjectCannotBeDeleted() throws {
        let url = temporaryArchiveURL()
        let store = JSONProjectStore(url: url)
        try store.add(name: "Finished sweater")
        let project = try #require(store.projects.first)
        let yarn = try StoredYarn(name: "Keepsake wool")
        try store.addYarn(yarn)
        try store.setProjectYarns(projectID: project.id, yarnIDs: [yarn.id])
        try store.markCompleted(projectID: project.id)
        let committed = try Data(contentsOf: url)

        #expect(throws: ProjectYarnLinkError.projectCompleted) {
            try store.deleteYarn(id: yarn.id)
        }

        #expect(store.yarn(id: yarn.id) != nil)
        #expect(try Data(contentsOf: url) == committed)
    }

    private func makeStore() -> JSONProjectStore {
        JSONProjectStore(url: temporaryArchiveURL())
    }

    private func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
