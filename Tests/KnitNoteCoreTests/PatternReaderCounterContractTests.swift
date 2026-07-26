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

    @Test func iPadPortraitCanReservePageControlsOutsideTheReaderOverlay() throws {
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(controls.contains("struct PatternPageControls: View"))
        #expect(reader.contains("pageControlPlacement == .reservedBelow"))
        #expect(reader.contains("PatternPageControls("))
    }

    @Test func readerHasNoVisibleNavigationTitleButKeepsAnAccessibilityName() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(!reader.contains(".navigationTitle(pattern?.displayName"))
        #expect(reader.contains(".accessibilityLabel(Text(content.displayName))"))
    }

    @Test func completedProjectLocksPatternReaderCounters() throws {
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(controls.contains("let isEnabled: Bool"))
        #expect(controls.contains("guard isEnabled else { return }"))
        #expect(reader.contains("projectIsCompleted: store.project"))
        #expect(reader.contains("isEnabled: context.canWrite"))
    }

    @Test func libraryReaderRoutesEveryWritableReaderActionThroughItsUsageContext() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(reader.contains("context: PatternReaderContext"))
        #expect(reader.contains("try store.updatePatternState("))
        #expect(reader.contains("try store.savePatternPageNote("))
        #expect(reader.contains("try store.loadPatternMarkup(usageID:"))
        #expect(reader.contains("try store.savePatternMarkup("))
        #expect(reader.contains("usageID: usageID"))
    }

    @Test func readerDisablesEveryWriteControlWhenItsContextIsReadOnly() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")

        #expect(reader.contains(".disabled(!context.canWrite)"))
        #expect(reader.contains("isEnabled: context.canWrite"))
        #expect(reader.contains("guard context.canWrite else { return }"))
        #expect(controls.contains(".accessibilityAddTraits(isEnabled ? [] : .isDisabled)"))
    }

    @Test func legacyReaderStillOffersItsMissingFileRecoveryAction() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(reader.contains("patterns.removeRecord"))
        #expect(reader.contains("store.deletePattern(projectID: projectID, id: patternID)"))
    }

    @Test func readerOnlyBuildsItsCanvasAfterReaderSessionHydrates() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(reader.contains("@State private var readerSession: PatternReaderSession"))
        #expect(reader.contains("readerSession.phase == .hydrated"))
        #expect(reader.contains("hydrateReaderSessionIfNeeded()"))
        #expect(reader.contains("guard readerSession.canPersist else"))
    }

    @Test func disabledCountersDoNotRegisterCustomVoiceOverActions() throws {
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")

        #expect(controls.contains("PatternReaderCounterAccessibilityPolicy.canExposeIncrementAction"))
        #expect(controls.contains("PatternReaderCounterAccessibilityPolicy.canExposeManageAction"))
        #expect(controls.contains("if isEnabled"))
    }

    @Test func everyPatternManagedFileWriteRoutesThroughTheStoreCoordinator() throws {
        let projectPatterns = try sourceFile("KnitNote/Patterns/ProjectPatternsView.swift")
        let library = try sourceFile("KnitNote/Patterns/PatternLibraryView.swift")
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(projectPatterns.contains("store.importPattern(from:"))
        #expect(library.contains("store.importPattern(from:"))
        #expect(projectPatterns.contains("store.deletePattern(projectID:"))
        #expect(reader.contains("store.savePatternMarkup("))
        #expect(reader.contains("expectedDataGeneration:"))
        #expect(reader.contains("store.loadPatternMarkup("))
        #expect(!projectPatterns.contains("PatternFileService.live()"))
        #expect(!library.contains("PatternFileService.live()"))
        #expect(!reader.contains("PatternMarkupFileService.live()"))
        #expect(!reader.contains("markupFiles.save("))
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
