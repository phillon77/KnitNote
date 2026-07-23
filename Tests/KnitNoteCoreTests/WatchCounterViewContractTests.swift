import Foundation
import Testing

@Suite struct WatchCounterViewContractTests {
    @Test func rootReplacesTheSampleWithTwoLevelProjectNavigationAndVisibleErrors() throws {
        let root = try source("KnitNoteWatch/WatchCounterView.swift")

        #expect(root.contains("NavigationStack"))
        #expect(root.contains("ProjectListView("))
        #expect(root.contains("coordinator: coordinator"))
        #expect(root.contains(".navigationDestination(for: UUID.self)"))
        #expect(root.contains("ProjectCountersView("))
        #expect(root.contains("projectID: projectID"))
        #expect(root.contains("coordinator.localizedErrorReason"))
        #expect(root.contains("Text(verbatim: errorReason)"))
        #expect(root.contains("onStoreScreenshotReady: onStoreScreenshotReady"))
        #expect(!root.contains("if path.isEmpty"))
        #expect(!root.contains(".lineLimit("))

        let list = try source("KnitNoteWatch/ProjectListView.swift")
        #expect(list.contains("let onStoreScreenshotReady: @MainActor @Sendable () -> Void"))
        #expect(list.contains("onStoreScreenshotReady()"))

        let counters = try source("KnitNoteWatch/ProjectCountersView.swift")
        let counterListStart = try #require(counters.range(of: "private func counterList"))
        let counterListSource = counters[counterListStart.lowerBound...]
        #expect(counterListSource.contains("onStoreScreenshotReady()"))
        #expect(!counters.contains("coordinator.selectProject(projectID)\n            onStoreScreenshotReady()"))
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
        #expect(!source.contains(".lineLimit("))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains("Image(systemName: \"lock.fill\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(source.contains("minHeight: 44"))
    }

    @Test func counterRowsKeepFullNamesAndVisibleNonColorStatus() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains("ForEach(project.counters)"))
        #expect(source.contains(".onTapGesture"))
        #expect(source.contains(".onLongPressGesture"))
        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains(".disabled(project.isCompleted)"))
        #expect(source.contains("coordinator.hasPending(projectID: project.id, counterID: counter.id)"))
        #expect(source.contains("Image(systemName: \"arrow.triangle.2.circlepath\")"))
        #expect(source.contains("Text(\"watch.sync.pending\")"))
        #expect(source.contains("Image(systemName: \"lock.fill\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(!source.contains(".lineLimit("))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains("minHeight: 64"))
    }

    @Test func dialogDismissesAndRevalidatesWhenItsSnapshotTargetChanges() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains("private var actionableCounterID: UUID?"))
        #expect(source.components(separatedBy: "!project.isCompleted").count - 1 >= 2)
        #expect(source.contains("project.counters.contains(where: { $0.id == actionCounterID })"))
        #expect(source.contains("if let counterID = actionableCounterID"))
        #expect(source.contains(".onChange(of: coordinator.snapshot)"))
        #expect(source.contains("dismissInvalidActionIfNeeded()"))
        #expect(source.contains("private func currentActiveProject(containing counterID: UUID)"))
        #expect(source.contains("guard let project = currentActiveProject(containing: counterID)"))
    }

    @Test func accessibilitySpeaksStatusAndOnlyActiveRowsExposeMutationActions() throws {
        let source = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(source.contains(".accessibilityLabel(Text(verbatim:"))
        #expect(source.contains(".accessibilityValue(counterAccessibilityValue("))
        #expect(source.contains("Text(\"watch.sync.pending\")"))
        #expect(source.contains("Text(\"watch.project.completed\")"))
        #expect(source.contains("Text(\"watch.sync.error.projectCompleted\")"))
        #expect(source.contains("if project.isCompleted {"))
        #expect(source.contains("private func activeCounterRow"))
        #expect(source.components(separatedBy: ".accessibilityAction(named:").count - 1 == 3)
        #expect(source.contains("perform(.increment, counterID: counter.id)"))
        #expect(source.contains("perform(.decrement, counterID: counter.id)"))
        #expect(source.contains("perform(.reset, counterID: counter.id)"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
