import Foundation
import Testing

@Suite("Project journal view contracts")
struct ProjectJournalViewContractTests {
    @Test func projectPlacesJournalAfterSupportingActionCardsAndBeforeRecentNotes() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let patterns = try #require(source.range(of: "projectActionCard(\"patterns.open\""))
        let journal = try #require(source.range(of: "ProjectJournalSection("))
        let recentNotes = try #require(source.range(of: "let sortedNotes"))

        #expect(patterns.lowerBound < journal.lowerBound)
        #expect(journal.lowerBound < recentNotes.lowerBound)
        #expect(source.contains("WatercolorCard"))
    }

    @Test func journalUsesLazyNewestFirstHorizontalThumbnailCards() throws {
        let source = try projectSource(named: "ProjectJournalSection")

        #expect(source.contains("ScrollView(.horizontal"))
        #expect(source.contains("LazyHStack"))
        #expect(source.contains("project.journalEntries"))
        #expect(source.contains("id: \\.id"))
        #expect(source.contains("thumbnailURL"))
        #expect(!source.contains("journalPhotoURL"))
        #expect(source.contains("lineLimit(2)"))
    }

    @Test func activeAndCompletedEmptyStatesDifferAndOnlyActiveProjectsCanAdd() throws {
        let source = try projectSource(named: "ProjectJournalSection")

        #expect(source.contains("journal.empty.active"))
        #expect(source.contains("journal.empty.completed"))
        #expect(source.contains("if !project.isCompleted"))
        #expect(source.contains("Button(\"journal.add\""))
        #expect(source.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(source.contains(".accessibilityLabel(Text(\"journal.accessibility.add\"))"))
    }

    @Test func pickerUsesPhotosPickerEverywhereAndCameraOnlyWhenAvailableOnIOS() throws {
        let source = try projectSource(named: "JournalPhotoPicker")

        #expect(source.contains("import PhotosUI"))
        #expect(source.contains("PhotosPicker"))
        #expect(source.contains("#if os(iOS)"))
        #expect(source.contains("UIImagePickerController.isSourceTypeAvailable(.camera)"))
        #expect(source.contains("CameraCaptureView"))
        #expect(source.contains("journal.photo.library"))
        #expect(source.contains("journal.photo.camera"))
    }

    @Test func cameraUsesOwnedCancellableOffMainEncodingAndShowsProcessingState() throws {
        let source = try projectSource(named: "CameraCaptureView")

        #expect(!source.contains(".jpegData("))
        #expect(source.contains("CameraCapturePhoto("))
        #expect(source.contains("CameraCapturePhotoEncoder.encode"))
        #expect(source.contains("var encodingTask: Task<Void, Never>?"))
        #expect(source.contains("encodingTask?.cancel()"))
        #expect(source.contains("dismantleUIViewController"))
        #expect(source.contains("UIActivityIndicatorView"))
        #expect(source.contains("isUserInteractionEnabled = false"))
    }

    @Test func journalPreviewDecodingNeverRunsInSwiftUIBody() throws {
        let source = try projectSource(named: "ProjectJournalSection")

        #expect(source.contains("ProjectJournalPreviewLoader.load"))
        #expect(source.contains("@State private var preview: ProjectJournalPreview?"))
        #expect(!source.contains("UIImage(data:"))
        #expect(!source.contains("NSImage(data:"))
        #expect(!source.contains("data.flatMap(decodedImage)"))
        #expect(!source.contains("private func decodedImage"))
    }

    @Test func pickerShowsProgressAndCancelsItsTransferWhenRemoved() throws {
        let source = try projectSource(named: "JournalPhotoPicker")

        #expect(source.contains("@State private var loadTask: Task<Void, Never>?"))
        #expect(source.contains("loadTask?.cancel()"))
        #expect(source.contains(".onDisappear"))
        #expect(source.contains("ProgressView"))
        #expect(source.contains(".disabled(isLoading)"))
        #expect(source.contains("previewRevision"))
    }

    @Test func pickerAndEditorGateLateAsyncPublicationWithTheTestedCoordinator() throws {
        let picker = try projectSource(named: "JournalPhotoPicker")
        let editor = try projectSource(named: "EditProjectJournalEntryView")

        for source in [picker, editor] {
            #expect(source.contains("ProjectJournalAsyncPublicationGate"))
            #expect(source.contains("publicationGate.begin()"))
            #expect(source.contains("publicationGate.finish("))
            #expect(source.contains("publicationGate.cancel()"))
        }
    }

    @Test func editorRequiresPhotoKeepsVerticalLayoutAndPreventsDuplicateSaves() throws {
        let source = try projectSource(named: "EditProjectJournalEntryView")

        #expect(source.contains("VStack(alignment: .leading"))
        #expect(source.contains("JournalPhotoPicker"))
        #expect(source.contains("TextField(\"journal.caption.placeholder\""))
        #expect(source.contains("selectedPhotoData == nil"))
        #expect(source.contains("isSaving = true"))
        #expect(source.contains("ProgressView"))
        #expect(source.contains("guard !isSaving else { return }"))
        #expect(source.contains(".disabled(!canSave)"))
        #expect(source.contains(".interactiveDismissDisabled(isSaving)"))
        #expect(source.contains("try await store.addJournalEntry"))
        #expect(source.contains("store.updateJournalCaption"))
        #expect(source.contains("@State private var saveTask: Task<Void, Never>?"))
        #expect(source.contains("saveTask?.cancel()"))
        #expect(source.contains(".onDisappear"))
        #expect(source.contains(".task(id: availabilityStateID)"))
        #expect(!source.contains("localizedDescription"))
    }

    @Test func detailLoadsFullPhotoAndLocksCompletedProjects() throws {
        let source = try projectSource(named: "ProjectJournalEntryDetailView")

        #expect(source.contains("journalPhotoURL"))
        #expect(!source.contains("journalThumbnailURL"))
        #expect(source.contains("if !project.isCompleted"))
        #expect(source.contains("journal.edit"))
        #expect(source.contains("journal.delete"))
        #expect(source.contains("role: .destructive"))
        #expect(source.contains("confirmationDialog"))
        #expect(source.contains("store.deleteJournalEntry"))
    }

    @Test func editorClearsItsSaveHandleBeforeSuccessfulDismissal() throws {
        let source = try projectSource(named: "EditProjectJournalEntryView")

        #expect(source.contains("finishSaving()\n                dismiss()"))
        #expect(source.contains("private func finishSaving() {\n        isSaving = false\n        saveTask = nil"))
    }

    @Test func cardsAndDetailExposeAccessibleStableEntryRoutes() throws {
        let section = try projectSource(named: "ProjectJournalSection")
        let detail = try projectSource(named: "ProjectJournalEntryDetailView")
        let project = try projectSource(named: "ProjectDetailView")

        #expect(section.contains(".accessibilityElement(children: .ignore)"))
        #expect(section.contains(".accessibilityLabel(accessibilityLabel)"))
        #expect(detail.contains("let entryID: UUID"))
        #expect(detail.contains("store.project(id: projectID)"))
        #expect(project.contains("JournalEntryRoute(id: entry.id)"))
        #expect(project.contains("ProjectJournalEntryDetailView(projectID: projectID, entryID: route.id)"))
    }

    @Test func cardsUseNamedLocalizedAccessibilityFormatsAndTheAppLocaleForDates() throws {
        let source = try projectSource(named: "ProjectJournalSection")

        #expect(source.contains("@Environment(\\.locale) private var locale"))
        #expect(source.contains("journal.card.accessibility.withCaption.format"))
        #expect(source.contains("journal.card.accessibility.withoutCaption.format"))
        #expect(source.contains("String(format: format, locale: locale"))
        #expect(source.contains("caption, date"))
        #expect(source.contains(".dateTime.year().month().day().locale(locale)"))
        #expect(!source.contains("Text(caption) + Text(\", \""))
    }

    @Test func unavailableJournalPhotosHaveTheirOwnLocalizedAccessibilityLabel() throws {
        let source = try projectSource(named: "ProjectJournalSection")
        let detail = try projectSource(named: "ProjectJournalEntryDetailView")

        #expect(source.contains("journal.photo.unavailable"))
        #expect(source.contains("enum ProjectJournalPhotoLoadState"))
        #expect(source.contains("case idle"))
        #expect(source.contains("case loading"))
        #expect(source.contains("case loaded"))
        #expect(source.contains("case unavailable"))
        #expect(source.contains("updateLoadState(.loading)"))
        #expect(source.contains("updateLoadState(loadedPreview == nil ? .unavailable : .loaded)"))
        #expect(source.contains("url == nil && data == nil ? .idle : .loading"))
        #expect(source.contains("journal.photo.select"))
        #expect(source.contains("private var accessibilityLabelKey: LocalizedStringKey"))
        #expect(detail.contains("loadedAccessibilityLabelKey: \"journal.accessibility.fullPhoto\""))
        #expect(!detail.contains(".accessibilityLabel(Text(\"journal.accessibility.fullPhoto\"))"))
    }

    @Test func cardAccessibilityIncludesThePhotoLoadStateWithoutExposingChildren() throws {
        let source = try projectSource(named: "ProjectJournalSection")

        #expect(source.contains("@State private var photoLoadState: ProjectJournalPhotoLoadState"))
        #expect(source.contains("onLoadStateChange: { photoLoadState = $0 }"))
        #expect(source.contains("journal.card.accessibility.withCaption.unavailable.format"))
        #expect(source.contains("journal.card.accessibility.withoutCaption.unavailable.format"))
        #expect(source.contains("journal.card.accessibility.withCaption.loading.format"))
        #expect(source.contains("journal.card.accessibility.withoutCaption.loading.format"))
        #expect(source.contains(".accessibilityElement(children: .ignore)"))
    }

    @Test func editorExplainsExternalJournalLockOrDeletionBeforeDismissing() throws {
        let source = try projectSource(named: "EditProjectJournalEntryView")

        #expect(source.contains("@State private var availabilityErrorKey: String?"))
        #expect(source.contains("availabilityAlertIsPresented"))
        #expect(source.contains("journal.error.projectCompleted"))
        #expect(source.contains("journal.error.notFound"))
        #expect(source.contains("updateAvailability"))
        #expect(source.contains("Button(\"common.ok\") { dismiss() }"))
        #expect(!source.contains("if project == nil {\n                dismiss()"))
        #expect(!source.contains("if entryID != nil && entry == nil {\n                dismiss()"))
    }

    @Test func journalActionsAndCompletedLockAreExplicitWithoutColorOnlyCues() throws {
        let section = try projectSource(named: "ProjectJournalSection")
        let editor = try projectSource(named: "EditProjectJournalEntryView")
        let detail = try projectSource(named: "ProjectJournalEntryDetailView")

        #expect(section.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(editor.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(detail.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(detail.contains("Label(\"journal.readOnly.completed\", systemImage: \"lock.fill\")"))
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func projectSource(named name: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: "KnitNote/Projects/\(name).swift"),
            encoding: .utf8
        )
    }
}
