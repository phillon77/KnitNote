import Foundation
import Testing

@Suite struct WatchCounterViewContractTests {
    @Test func rootReplacesTheSampleWithTwoLevelProjectNavigationAndVisibleErrors() throws {
        let root = try source("KnitNoteWatch/WatchCounterView.swift")

        #expect(root.contains("NavigationStack"))
        #expect(root.contains("ProjectListView(coordinator: coordinator)"))
        #expect(root.contains(".navigationDestination(for: UUID.self)"))
        #expect(root.contains("ProjectCountersView(projectID: projectID, coordinator: coordinator)"))
        #expect(root.contains("coordinator.localizedErrorReason"))
        #expect(root.contains("Text(verbatim: errorReason)"))
        #expect(root.contains("Color(watchTheme: WatercolorPalette.sky)"))
        #expect(!root.contains("KnittingProject"))
        #expect(!root.contains("sample.projectName"))
    }

    @Test func projectListUsesSnapshotOrderStableIDsAndReadableRows() throws {
        let source = try source("KnitNoteWatch/ProjectListView.swift")

        #expect(source.contains("coordinator.snapshot?.projects"))
        #expect(source.contains("ForEach(projects)"))
        #expect(source.contains("NavigationLink(value: project.id)"))
        #expect(source.contains("coordinator.selectProject(project.id)"))
        #expect(source.contains(".lineLimit(2)"))
        #expect(source.contains("Image(systemName: \"lock.fill\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(source.contains("minHeight: 44"))
    }

    @Test func counterRowsUseStableActionsAndAccessibleNonColorStatus() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains("ForEach(project.counters)"))
        #expect(source.contains("coordinator.increment(projectID: project.id, counterID: counter.id)"))
        #expect(source.contains("coordinator.decrement(projectID: project.id, counterID: counterID)"))
        #expect(source.contains("coordinator.reset(projectID: project.id, counterID: counterID)"))
        #expect(source.contains(".onTapGesture"))
        #expect(source.contains(".onLongPressGesture"))
        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains(".disabled(project.isCompleted)"))
        #expect(source.components(separatedBy: "guard !project.isCompleted else { return }").count - 1 == 5)
        #expect(source.contains("coordinator.hasPending(projectID: project.id, counterID: counter.id)"))
        #expect(source.contains("Image(systemName: \"arrow.triangle.2.circlepath\")"))
        #expect(source.contains("Text(\"watch.sync.pending\")"))
        #expect(source.contains("Image(systemName: \"lock.fill\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(source.contains(".lineLimit(2)"))
        #expect(source.contains("minHeight: 64"))
        #expect(source.contains(".accessibilityLabel(Text(verbatim:"))
        #expect(source.contains("project.isCompleted\n                ? Text(\"watch.sync.error.projectCompleted\")"))
        #expect(source.components(separatedBy: ".accessibilityAction(named:").count - 1 == 3)
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
