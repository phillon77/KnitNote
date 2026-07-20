import Foundation
import Testing

@Suite struct PatternReaderCounterContractTests {
    @Test func controlsShowColoredNumberOnlyCountersWithTapAndLongPressActions() throws {
        let source = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")

        #expect(source.contains("let counters: [ProjectCounter]"))
        #expect(source.contains("let onIncrement: (UUID) -> Void"))
        #expect(source.contains("let onManage: (UUID) -> Void"))
        #expect(source.contains("Text(counter.value, format: .number)"))
        #expect(!source.contains("Text(projectCounterDisplayName(counter"))
        #expect(source.contains("onLongPressGesture"))
    }

    @Test func readerRoutesCounterTapAndManagementByID() throws {
        let readerSource = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(readerSource.contains("counters: project.counters"))
        #expect(readerSource.contains("store.incrementCounter(projectID: projectID, counterID: counterID)"))
        #expect(readerSource.contains("managingCounter = project.counters.first"))
    }

    @Test func coloredCountersKeepPracticalTouchTargets() throws {
        let source = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")

        #expect(source.contains(".counterActionTouchTarget()"))
        #expect(source.contains(".accessibilityAction(named: Text(\"counter.increment\")"))
    }

    @Test func readerReservesATrailingSafeAreaForTheCounterRail() throws {
        let source = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(source.contains("private let counterRailSafeAreaWidth: CGFloat = 64"))
        #expect(source.contains(".padding(.trailing, counterRailSafeAreaWidth)"))
    }

    @Test func completedProjectLocksPatternReaderCounters() throws {
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(controls.contains("let isEnabled: Bool"))
        #expect(controls.contains("guard isEnabled else { return }"))
        #expect(reader.contains("isEnabled: !project.isCompleted"))
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
