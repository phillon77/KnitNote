import Foundation
import Testing

@Suite struct ProjectPatternsViewContractTests {
    @Test func projectPatternAddMenuOffersLinkImportAndYouTube() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("Menu"))
        #expect(source.contains("ForEach(ProjectPatternAddAction.allCases)"))
        #expect(source.contains("performAddAction(action)"))
        #expect(source.contains("ChooseLibraryPatternView("))
        #expect(source.contains("PatternImportResultView("))
        #expect(source.contains("AddYouTubePatternView(targetProjectID: projectID)"))
    }

    @Test func projectPatternAddMenuLocalizesDynamicActionKeys() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("LocalizedStringKey(action.localizationKey)"))
        #expect(!source.contains("Button(action.localizationKey, systemImage:"))
    }

    @Test func projectSwipeConfirmsUnlinkWithoutDeletingTheLibraryPattern() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("patterns.unlink.confirm.title"))
        #expect(source.contains("patterns.unlink.confirm.message"))
        #expect(source.contains("store.unlinkPattern(patternID:"))
        #expect(!source.contains("store.deletePattern(projectID:"))
        #expect(!source.contains("store.deletePatternPermanently"))
    }

    @Test func libraryChooserUsesRealLinkStateAndOffersRelinking() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ChooseLibraryPatternView.swift")

        #expect(source.contains("ProjectPatternLinkChoiceIndex("))
        #expect(source.contains("patterns.relink"))
        #expect(source.contains("store.linkPattern(patternID:"))
        #expect(source.contains(".accessibilityLabel"))
    }

    @Test func projectImportUsesDurableOutcomesForFilesAndAvailableCamera() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternImportResultView.swift")

        #expect(source.contains("store.importPatternFromProject("))
        #expect(source.contains(".fileImporter("))
        #expect(source.contains("case .created"))
        #expect(source.contains("case .existing"))
        #expect(source.contains("case let .needsSelection"))
        #expect(source.contains("store.processPatternInboxItem("))
        #expect(source.contains("#if os(iOS)"))
        #expect(source.contains("UIImagePickerController.isSourceTypeAvailable(.camera)"))
        #expect(source.contains("CameraCaptureView"))
        #expect(source.contains("Task.detached"))
        #expect(source.contains("data.write(to:"))
    }

    @Test func projectImportOwnsOneCancellableIdentityCheckedTask() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternImportResultView.swift")

        #expect(source.contains("@State private var importTask: Task<Void, Never>?"))
        #expect(source.contains("ProjectPatternImportOperationCoordinator"))
        #expect(source.contains("operationCoordinator.finishIfCurrent(operationID)"))
        #expect(source.contains("importTask?.cancel()"))
        #expect(source.contains(".onDisappear"))
        #expect(source.contains("cancelCurrentOperation()"))
    }

    @Test func projectImportSurfacesPickerAndOperationFailuresWithoutRawDescriptions() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternImportResultView.swift")

        #expect(source.contains("case let .failure(error)"))
        #expect(source.contains("ProjectPatternImportErrorMapper.message("))
        #expect(source.contains("context: .filePicker"))
        #expect(source.contains("@State private var errorMessage: LocalizedStringKey?"))
        #expect(!source.contains("error.localizedDescription"))
    }

    @Test func completedProjectReaderUsesItsReadOnlyProjectContext() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains("projectIsCompleted: projectIsCompleted"))
        #expect(source.contains("PatternReaderView(context: .project("))
    }

    @Test func projectDetailKeepsPhotoPatternNotesCountersJournalPriority() throws {
        let source = try readRepositoryFile("KnitNote/Projects/ProjectDetailView.swift")
        let photo = try #require(source.range(of: "ProjectCoverView("))
        let pattern = try #require(source.range(of: "projectActionCard(\"patterns.open\""))
        let notes = try #require(source.range(of: "projectActionCard(\"notes.edit\""))
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let journal = try #require(source.range(of: "ProjectJournalSection("))

        #expect(photo.lowerBound < pattern.lowerBound)
        #expect(pattern.lowerBound < notes.lowerBound)
        #expect(notes.lowerBound < counters.lowerBound)
        #expect(counters.lowerBound < journal.lowerBound)
        #expect(source.contains("hasActivePatterns"))
    }

    @Test func projectRowsKeepLongNamesAndVoiceOverMetadataReadable() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/ProjectPatternsView.swift")

        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(source.contains(".accessibilityLabel"))
        #expect(source.contains("PatternThumbnailView("))
    }
}
