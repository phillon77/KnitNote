import Testing

@Suite struct PatternLibraryViewContractTests {
    @Test func libraryIsOneSearchableListWithoutProjectSectionsOrSwipeDelete() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")

        #expect(source.contains(".searchable"))
        #expect(source.contains("PatternLibraryRow("))
        #expect(!source.contains("Section(group.projectName)"))
        #expect(!source.contains(".swipeActions"))
    }

    @Test func libraryOffersRecentAndNameSortsPlusAnUnrestrictedImporter() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")
        let store = try readRepositoryFile("Sources/KnitNoteCore/Projects/JSONProjectStore.swift")

        #expect(source.contains("PatternLibrarySort.recentlyAdded"))
        #expect(source.contains("PatternLibrarySort.name"))
        #expect(source.contains("store.importPatternFromLibrary"))
        #expect(store.contains("origin: .library"))
        #expect(store.contains("targetProjectID: nil"))
        #expect(!source.contains(".disabled(store.projects.isEmpty)"))
    }

    @Test func existingImportShowsFeedbackAndCanNavigateToTheSavedDetail() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")

        #expect(source.contains("PatternLibraryImportPresentation(outcome: outcome)"))
        #expect(source.contains("patterns.library.alreadySaved.title"))
        #expect(source.contains("patterns.library.alreadySaved.view"))
        #expect(source.contains("navigationPath.append(patternID)"))
    }

    @Test func rowHasThumbnailMetadataUsageSummaryAndOneVoiceOverElement() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("PatternThumbnailView("))
        #expect(source.contains("asset.pageCount"))
        #expect(source.contains("patterns.library.unused"))
        #expect(source.contains(".accessibilityElement(children: .combine)"))
        #expect(source.contains(".accessibilityLabel"))
    }

    @Test func thumbnailLoadsTheOwnedLocalFileInsteadOfUsingANetworkImageLoader() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("Data(contentsOf:"))
        #expect(!source.contains("AsyncImage("))
    }

    @Test func detailShowsMetadataLinksAndGuardedDestructiveAction() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(source.contains("PatternThumbnailView("))
        #expect(source.contains("pattern.displayName"))
        #expect(source.contains("asset.byteCount"))
        #expect(source.contains("pattern.createdAt"))
        #expect(source.contains("activeProjects"))
        #expect(source.contains("store.renamePattern"))
        #expect(source.contains("store.setPatternNote"))
        #expect(source.contains("store.linkPattern"))
        #expect(source.contains("store.deletePatternPermanently"))
        #expect(source.contains(".disabled(!activeProjects.isEmpty)"))
    }

    @Test func openingUsesReadOnlySingleUsageOrExplicitContextChoice() throws {
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")
        let chooser = try readRepositoryFile("KnitNote/Patterns/ChoosePatternReadingContextView.swift")

        #expect(detail.contains("activeUsages.isEmpty"))
        #expect(detail.contains("activeUsages.count == 1"))
        #expect(detail.contains("ChoosePatternReadingContextView("))
        #expect(chooser.contains("PatternReaderContext.readOnly"))
        #expect(chooser.contains("PatternReaderContext.project"))
    }

    @Test func emptyStateAndAdaptiveDetailLayoutStayAvailableOnPhoneAndPad() throws {
        let library = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(library.contains("LemonEmptyState("))
        #expect(library.contains("patterns.library.empty.title"))
        #expect(detail.contains("ViewThatFits"))
        #expect(detail.contains("ScrollView"))
    }

    @Test func detailUsesAPlatformSafeNavigationTitleStyle() throws {
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(detail.contains(".patternDetailNavigationTitleStyle()"))
        #expect(detail.contains("#if os(iOS)"))
    }
}
