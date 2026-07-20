import Foundation
import Testing

@Suite("Yarn view contracts")
struct YarnViewContractTests {
    @Test func yarnEditorKeepsOnlyNameRequiredAndUsesProjectPicker() throws {
        let source = try sourceText("KnitNote/Yarn/YarnEditorFields.swift")

        #expect(source.contains("yarn.name"))
        #expect(source.contains("remainingBalls"))
        #expect(source.contains("remainingGrams"))
        #expect(source.contains("ChooseYarnProjectsView"))
    }

    @Test func yarnEditorsUseDecimalValidationAndOneCompletionAction() throws {
        let fields = try sourceText("KnitNote/Yarn/YarnEditorFields.swift")
        let create = try sourceText("KnitNote/Yarn/CreateYarnView.swift")
        let edit = try sourceText("KnitNote/Yarn/EditYarnView.swift")

        #expect(fields.contains("YarnInventoryEditValue"))
        #expect(create.contains("YarnPhotoPicker"))
        #expect(edit.contains("YarnPhotoPicker"))
        #expect(create.contains("placement: .confirmationAction"))
        #expect(edit.contains("placement: .confirmationAction"))
        #expect(create.contains("Button(\"common.done\")"))
        #expect(edit.contains("Button(\"common.done\")"))
        #expect(!fields.contains("Button(\"common.done\")"))
    }

    @Test func yarnPhotoPickerSupportsReplacementRemovalAndStaleLoadCancellation() throws {
        let source = try sourceText("KnitNote/Yarn/YarnPhotoPicker.swift")

        #expect(source.contains("PhotosPicker"))
        #expect(source.contains("selectionRevision"))
        #expect(source.contains("removesExistingPhoto"))
        #expect(source.contains("CameraCaptureView"))
        #expect(source.contains("yarn.photo.loadFailed"))
        #expect(source.contains("invalidatePendingLoad()\n        loadFailed = true"))
        #expect(source.contains("pickerItem = nil\n        isLoading = false"))
        #expect(!source.contains("hasPhoto ?"))
    }

    @Test func yarnPhotoViewRejectsResultsFromCancelledOrChangedLoads() throws {
        let source = try sourceText("KnitNote/Yarn/YarnPhotoView.swift")

        #expect(source.contains("requestedURL"))
        #expect(source.contains("Task.isCancelled"))
    }

    @Test func yarnDecimalParsingRejectsPartiallyValidLocalizedInput() throws {
        let source = try sourceText("Sources/KnitNoteCore/Yarn/StoredYarn.swift")

        #expect(source.contains("NumberFormatter"))
        #expect(source.contains("isLenient = false"))
        #expect(source.contains("Decimal(string: exactText, locale: locale)"))
        #expect(source.contains("isFinite"))
    }

    @Test func yarnTabUsesAdaptivePhotoGridAndNoPlaceholder() throws {
        let root = try sourceText("KnitNote/App/RootView.swift")
        let library = try sourceText("KnitNote/Yarn/YarnLibraryView.swift")

        #expect(root.contains("YarnLibraryView()"))
        #expect(!root.contains("PlaceholderView(title: \"nav.yarn\""))
        #expect(root.contains("Label(\"nav.yarn\", systemImage: \"shippingbox\")"))
        #expect(library.contains("GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 16)"))
        #expect(library.contains("LazyVGrid"))
        #expect(library.contains("contextMenu"))
        #expect(library.contains("LemonEmptyState"))
        #expect(library.contains("confirmationDialog"))
    }

    @Test func yarnCardsKeepFullNamesAndPrioritizeBallsThenGrams() throws {
        let card = try sourceText("KnitNote/Yarn/YarnCard.swift")
        let inventory = try sourceText("KnitNote/Yarn/YarnInventoryText.swift")

        #expect(card.contains("YarnPhotoView"))
        #expect(card.contains(".aspectRatio(1, contentMode: .fit)"))
        #expect(card.contains(".clipped()"))
        #expect(card.contains("Text(yarn.name)"))
        #expect(!card.contains("lineLimit"))
        #expect(card.contains("YarnInventoryText"))
        #expect(inventory.contains("if let balls = yarn.remainingBalls"))
        #expect(inventory.contains("else if let grams = yarn.remainingGrams"))
    }

    @Test func yarnInventoryUsesLocaleAwareDecimalFormatting() throws {
        let inventory = try sourceText("KnitNote/Yarn/YarnInventoryText.swift")

        #expect(inventory.contains("Decimal.FormatStyle.number.locale(locale)"))
        #expect(inventory.contains("String(localized: \"yarn.inventory.balls\", locale: locale)"))
        #expect(inventory.contains("String(localized: \"yarn.inventory.grams\", locale: locale)"))
        #expect(inventory.contains("String(format: format, locale: locale, quantity)"))
    }

    @Test func yarnEditorsUseTheRegionPreservingAppLocaleForParsingAndFormatting() throws {
        let app = try sourceText("KnitNote/App/KnitNoteApp.swift")
        let fields = try sourceText("KnitNote/Yarn/YarnEditorFields.swift")
        let create = try sourceText("KnitNote/Yarn/CreateYarnView.swift")
        let edit = try sourceText("KnitNote/Yarn/EditYarnView.swift")

        #expect(app.contains("resolvedLocale"))
        #expect(fields.contains("@Environment(\\.locale) private var locale"))
        #expect(create.contains("@Environment(\\.locale) private var locale"))
        #expect(edit.contains("@Environment(\\.locale) private var locale"))
        #expect(!fields.contains("Locale = .current"))
    }

    @Test func yarnEditorsReconcileProjectLinksImmediatelyBeforeBothSaveFlows() throws {
        let create = try sourceText("KnitNote/Yarn/CreateYarnView.swift")
        let edit = try sourceText("KnitNote/Yarn/EditYarnView.swift")

        #expect(create.contains("draft.linkedProjectIDs.formIntersection(currentProjectIDs)"))
        #expect(edit.contains("draft.linkedProjectIDs.formIntersection(currentProjectIDs)"))
        #expect(create.contains("Set(store.projects.map(\\.id))"))
        #expect(edit.contains("Set(store.projects.map(\\.id))"))
    }

    @Test func yarnFailuresUseCatalogKeysAndRetainRetryableEditorDrafts() throws {
        let fields = try sourceText("KnitNote/Yarn/YarnEditorFields.swift")
        let create = try sourceText("KnitNote/Yarn/CreateYarnView.swift")
        let edit = try sourceText("KnitNote/Yarn/EditYarnView.swift")

        #expect(fields.contains("enum YarnOperationFailure"))
        #expect(fields.contains("YarnPhotoFileError"))
        #expect(fields.contains("ProjectStoreError"))
        #expect(create.contains("Button(\"common.retry\") { save() }"))
        #expect(edit.contains("Button(\"common.retry\") { save() }"))
        #expect(!create.contains("localizedDescription"))
        #expect(!edit.contains("localizedDescription"))
    }

    @Test func yarnDeleteFailureKeepsContextAndOffersRetry() throws {
        let library = try sourceText("KnitNote/Yarn/YarnLibraryView.swift")

        #expect(library.contains("showingDeleteConfirmation"))
        #expect(library.contains("deleteFailure"))
        #expect(library.contains("Button(\"common.retry\") { deletePendingYarn() }"))
        #expect(library.contains("do {"))
        #expect(library.contains("catch {"))
        #expect(!library.contains("try? store.deleteYarn"))
    }

    @Test func unreadableArchiveReplacesNormalEmptyDatabasePresentation() throws {
        let root = try sourceText("KnitNote/App/RootView.swift")

        #expect(root.contains("store.loadError"))
        #expect(root.contains("ContentUnavailableView"))
        #expect(root.contains("store.retryLoad()"))
        #expect(root.contains("yarn.error.loadFailed.title"))
    }

    @Test func yarnCardsExposeOneAccessibleSummaryWithTheRecordedDetails() throws {
        let card = try sourceText("KnitNote/Yarn/YarnCard.swift")

        #expect(card.contains("@Environment(\\.locale) private var locale"))
        #expect(card.contains(".accessibilityElement(children: .ignore)"))
        #expect(card.contains(".accessibilityLabel(accessibilityLabel)"))
        #expect(card.contains("YarnInventoryText.description(for: yarn, locale: locale)"))
    }

    @Test func yarnIconOnlyPhotoRemovalHasAnExplicitLabelAnd44PointHitArea() throws {
        let picker = try sourceText("KnitNote/Yarn/YarnPhotoPicker.swift")

        #expect(picker.contains(".labelStyle(.iconOnly)"))
        #expect(picker.contains(".accessibilityLabel(Text(\"yarn.photo.remove\"))"))
        #expect(picker.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(picker.contains(".contentShape(.rect)"))
    }

    @Test func yarnDetailOnlyBuildsPopulatedRowsAndLinksProjects() throws {
        let detail = try sourceText("KnitNote/Yarn/YarnDetailView.swift")

        #expect(detail.contains("if let brand = yarn.brand"))
        #expect(detail.contains("if let series = yarn.series"))
        #expect(detail.contains("if let color = yarn.color"))
        #expect(detail.contains("if let colorCode = yarn.colorCode"))
        #expect(detail.contains("if let dyeLot = yarn.dyeLot"))
        #expect(detail.contains("if let storageLocation = yarn.storageLocation"))
        #expect(detail.contains("if let notes = yarn.notes"))
        #expect(detail.contains("linkedProjectIDs"))
        #expect(detail.contains("NavigationLink"))
        #expect(detail.contains("ProjectDetailView(projectID: project.id)"))
        #expect(detail.contains("project.isCompleted"))
        #expect(detail.contains(".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)"))
        #expect(detail.contains(".contentShape(.rect)"))
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceText(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: relativePath), encoding: .utf8)
    }
}
