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
        #expect(readerSource.contains("store.mutatePatternReaderCounter("))
        #expect(readerSource.contains("mutation: .increment"))
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

    @Test func pdfReaderFrameFeedsTheHighlightWithoutChangingImageBehavior() throws {
        let source = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
        #expect(source.contains("@State private var pdfPageFrame: CGRect?"))
        #expect(source.contains("pageFrame: $pdfPageFrame"))
        #expect(source.contains("content.kind == .pdf ? pdfPageFrame : nil"))
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
        #expect(reader.contains("store.mutatePatternReaderCounter("))
        #expect(reader.contains("expectedDataGeneration = nextGeneration"))
        #expect(!reader.contains("store.incrementCounter(projectID:"))
        #expect(!reader.contains("store.updateCounter(projectID:"))
    }

    @Test func readerIdentityReloadsWhenItsUsageBecomesInactive() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(reader.contains("usageIsActive = store.patternUsages.contains"))
        #expect(reader.contains("&& $0.isActive"))
        #expect(reader.contains("usageIsActive: usageIsActive"))
    }

    @Test func readerObservesExternalStoreGenerationsAndProtectsDirtyMarkupOnPageChange() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(reader.contains("@State private var revisionCoordinator"))
        #expect(reader.contains(".onChange(of: store.dataGeneration)"))
        #expect(reader.contains("revisionCoordinator.canChangePage"))
        #expect(reader.contains("!saveMarkup(page: transition.rollbackPageIndex)"))
        #expect(reader.contains("guard saveMarkup(page: state.pageIndex) else { return }"))
    }

    @Test func readerOffersDiscardAndReloadForAnExternalMarkupConflict() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
        let strings = try sourceFile("KnitNote/Localization/Localizable.xcstrings")

        #expect(reader.contains(".alert(\"patterns.reader.conflict\""))
        #expect(reader.contains("discardMarkupAndReload()"))
        #expect(reader.contains("revisionCoordinator.requiresConflictResolution"))
        #expect(reader.contains("discardConflictAndPrepareReload"))
        #expect(strings.contains("\"patterns.reader.discardAndReload\""))
        #expect(strings.contains("\"patterns.reader.conflict.message\""))
    }

    @Test func contextBasedScreenshotReaderPreservesItsRequestedPresentation() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(reader.contains("_markupMode = State(initialValue: storePresentation == .markup)"))
        #expect(reader.contains("showingPageNote = storePresentation == .notes"))
    }

    @Test func productionReaderCallsitesUseOnlyContextInitializers() throws {
        let projectPatterns = try sourceFile("KnitNote/Patterns/ProjectPatternsView.swift")
        let detail = try sourceFile("KnitNote/Patterns/PatternDetailView.swift")
        let chooser = try sourceFile("KnitNote/Patterns/ChoosePatternReadingContextView.swift")
        let screenshotRoot = try sourceFile("KnitNote/App/StoreScreenshotRootView.swift")

        #expect(projectPatterns.contains("PatternReaderView(context: .project("))
        #expect(projectPatterns.contains("usageID: selection.usage.id"))
        #expect(detail.contains("context: .readOnly(patternID: patternID)"))
        #expect(detail.contains("context: .project("))
        #expect(chooser.contains("PatternReaderContext.readOnly"))
        #expect(chooser.contains("PatternReaderContext.project"))
        #expect(screenshotRoot.contains("PatternReaderView(\n                context: .project("))
        #expect(screenshotRoot.contains("usageID: usage.id"))
        #expect(!projectPatterns.contains("PatternReaderView(projectID:"))
        #expect(!detail.contains("PatternReaderView(projectID:"))
        #expect(!chooser.contains("PatternReaderView(projectID:"))
        #expect(!screenshotRoot.contains("PatternReaderView(projectID:"))
    }

    @Test func readerEditorsDismissOnlyAfterTheirMutationSucceeds() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
        let noteEditor = try sourceFile("KnitNote/Patterns/EditPatternPageNoteView.swift")
        let counterEditor = try sourceFile("KnitNote/Projects/EditCounterNameView.swift")

        #expect(noteEditor.contains("let onSave: () -> Bool"))
        #expect(noteEditor.contains("if onSave() { dismiss() }"))
        #expect(counterEditor.contains("let onDone: (String, Int) -> Bool"))
        #expect(counterEditor.contains("if onDone(savedName, value) { dismiss() }"))
        #expect(reader.contains("private func savePageNoteDirectly() -> Bool"))
        #expect(reader.contains("private func updateCounter(_ counter: ProjectCounter, name: String, value: Int) -> Bool"))
    }

    @Test func readerDisablesEveryWriteControlWhenItsContextIsReadOnly() throws {
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")

        #expect(reader.contains(".disabled(!context.canWrite)"))
        #expect(reader.contains("isEnabled: context.canWrite"))
        #expect(reader.contains("guard context.canWrite else { return }"))
        #expect(controls.contains("PatternReaderCounterAccessibilityPolicy.accessibilityHintKey(isEnabled: isEnabled)"))
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
        #expect(reader.contains(".task(id: readerContextIdentity)"))
        #expect(reader.contains("readerSession.beginLoading"))
        #expect(reader.contains(".id(readerSession.generation)"))
        #expect(reader.contains("readerSession.canPersist, readerSession.identity == readerContextIdentity"))
    }

    @Test func disabledCountersDoNotRegisterCustomVoiceOverActions() throws {
        let controls = try sourceFile("KnitNote/Patterns/PatternReaderControls.swift")

        let activeBranch = try #require(controls.range(of: "if isEnabled,"))
        let inactiveBranch = try #require(controls.range(of: "} else {\n            button\n        }"))
        let incrementAction = try #require(controls.range(of: ".accessibilityAction(named: Text(\"counter.increment\")"))
        let manageAction = try #require(controls.range(of: ".accessibilityAction(named: Text(\"counter.manage\")"))

        #expect(controls.contains("PatternReaderCounterAccessibilityPolicy.canExposeIncrementAction"))
        #expect(controls.contains("PatternReaderCounterAccessibilityPolicy.canExposeManageAction"))
        #expect(activeBranch.lowerBound < incrementAction.lowerBound)
        #expect(manageAction.lowerBound < inactiveBranch.lowerBound)
    }

    @Test func everyPatternManagedFileWriteRoutesThroughTheStoreCoordinator() throws {
        let projectPatterns = try sourceFile("KnitNote/Patterns/ProjectPatternsView.swift")
        let projectImporter = try sourceFile("KnitNote/Patterns/PatternImportResultView.swift")
        let library = try sourceFile("KnitNote/Patterns/PatternLibraryView.swift")
        let reader = try sourceFile("KnitNote/Patterns/PatternReaderView.swift")

        #expect(projectImporter.contains("store.importPatternFromProject("))
        #expect(library.contains("store.importPatternFromLibrary("))
        #expect(projectPatterns.contains("store.unlinkPattern(patternID:"))
        #expect(reader.contains("store.savePatternMarkup("))
        #expect(reader.contains("expectedDataGeneration:"))
        #expect(reader.contains("store.loadPatternMarkup("))
        #expect(!projectImporter.contains("PatternFileService.live()"))
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
