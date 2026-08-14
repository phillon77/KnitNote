import Testing

@Suite struct PatternLibraryViewContractTests {
    @Test func patternLibraryUsesFolderFirstAdaptiveNavigationAndLongPressMovement() throws {
        let root = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")
        let sidebar = try readRepositoryFile("KnitNote/Patterns/PatternFolderSidebarView.swift")
        let collection = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )

        #expect(root.contains("NavigationSplitView"))
        #expect(root.contains("PatternFolderSidebarView"))
        #expect(root.contains("PatternLibraryCollectionView"))
        #expect(root.contains("preferredCompactColumn"))
        #expect(root.contains("NavigationSplitViewColumn.sidebar"))
        #expect(root.contains(".navigationSplitViewStyle(.balanced)"))
        #expect(!root.contains("HStack"))
        #expect(sidebar.contains("PatternFolderPresentation.rows("))
        #expect(sidebar.contains("contextMenu"))
        #expect(collection.contains("contextMenu"))
        #expect(collection.contains("MovePatternFolderView"))
        #expect(collection.contains("PatternLibraryIndex(rows: rows, locale: locale)"))
        #expect(collection.contains(".search(query, in: scope, sortedBy: sort)"))
    }

    @Test func folderManagementPreservesSelectionUntilDurableDeleteSuccess() throws {
        let root = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")

        #expect(root.contains("try store.deletePatternFolder(id: folder.id)"))
        #expect(root.contains("selection = PatternFolderPresentation.selectionAfterDeleting"))
        #expect(root.contains("pendingDeletion = folder"))
        #expect(root.contains("deletionErrorKey = PatternFolderFailurePresentation.key(for: error)"))
        #expect(root.contains("pendingDeletion = nil"))
        #expect(root.contains("confirmationDialog"))
    }

    @Test func folderActionsAreAccessibleAndImportsCaptureTheSelectedDestination() throws {
        let sidebar = try readRepositoryFile("KnitNote/Patterns/PatternFolderSidebarView.swift")
        let editor = try readRepositoryFile("KnitNote/Patterns/PatternFolderEditorView.swift")
        let mover = try readRepositoryFile("KnitNote/Patterns/MovePatternFolderView.swift")
        let collection = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )

        let sidebarRow = try sourceSlice(
            sidebar,
            from: "NavigationLink(value: row.scope)",
            to: ".contextMenu {"
        )
        #expect(sidebarRow.contains(".frame(minHeight: 44)"))
        #expect(sidebarRow.contains(".accessibilityLabel("))
        #expect(sidebarRow.contains("Text(\"\\(title(for: row.title)), \\(countDescription(row.count))\")"))
        #expect(sidebarRow.contains(".accessibilityAddTraits(selection == row.scope ? .isSelected : [])"))

        let renameAction = try sourceSlice(
            sidebar,
            from: "Button(\"patterns.folder.rename\"",
            to: "Button(\"common.delete\""
        )
        #expect(renameAction.contains(".accessibilityLabel(Text(\"patterns.folder.rename\"))"))
        #expect(renameAction.contains(".accessibilityHint(Text(\"patterns.folder.rename\"))"))

        let deleteAction = try sourceSlice(
            sidebar,
            from: "Button(\"common.delete\"",
            to: ".navigationTitle("
        )
        #expect(deleteAction.contains(".accessibilityLabel(Text(\"patterns.folder.delete.title\"))"))
        #expect(deleteAction.contains(".accessibilityHint(Text(deleteDescription(row.count)))"))

        let newAction = try sourceSlice(
            sidebar,
            from: "Button(\"patterns.folder.new\"",
            to: "private var rows"
        )
        #expect(newAction.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(newAction.contains(".accessibilityLabel(Text(\"patterns.folder.new\"))"))
        #expect(newAction.contains(".accessibilityHint(Text(\"patterns.folder.name\"))"))

        let nameField = try sourceSlice(
            editor,
            from: "TextField(\"patterns.folder.name\"",
            to: "if let errorKey"
        )
        #expect(nameField.contains(".frame(minHeight: 44)"))
        #expect(nameField.contains(".accessibilityLabel(Text(\"patterns.folder.name\"))"))
        #expect(nameField.contains(".accessibilityHint(Text(titleKey))"))

        let cancelAction = try sourceSlice(
            editor,
            from: "Button(\"common.cancel\")",
            to: "ToolbarItem(placement: .confirmationAction)"
        )
        #expect(cancelAction.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(cancelAction.contains(".accessibilityLabel(Text(\"common.cancel\"))"))

        let doneAction = try sourceSlice(
            editor,
            from: "Button(\"common.done\")",
            to: ".tint("
        )
        #expect(doneAction.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(doneAction.contains(".accessibilityLabel(Text(\"common.done\"))"))
        #expect(doneAction.contains(".accessibilityHint(Text(titleKey))"))

        let destinationAction = try sourceSlice(
            mover,
            from: "private func destinationButton",
            to: "private func move"
        )
        #expect(destinationAction.contains(".frame(minHeight: 44)"))
        #expect(destinationAction.contains(".accessibilityLabel("))
        #expect(destinationAction.contains("Text(\"\\(title), \\(LocaleAwareText.string(\"patterns.folder.move\", locale: locale))\")"))
        #expect(destinationAction.contains(".accessibilityHint(Text(\"patterns.folder.move\"))"))
        #expect(destinationAction.contains(".accessibilityAddTraits(currentFolderID == folderID ? .isSelected : [])"))

        let moveAction = try sourceSlice(
            collection,
            from: "Button(\"patterns.folder.move\"",
            to: ".listStyle(.plain)"
        )
        #expect(moveAction.contains(".accessibilityLabel(Text(\"patterns.folder.move\"))"))
        #expect(moveAction.contains(".accessibilityHint(Text(\"patterns.folder.move\"))"))
        #expect(collection.contains("folderID: destinationFolderID"))
        #expect(collection.contains("AddYouTubePatternView("))
        #expect(collection.contains("targetFolderID: destinationFolderID"))
        #expect(collection.contains("case .all, .uncategorized:"))
        #expect(collection.contains("case let .folder(folderID):"))
    }

    @Test func libraryIsOneSearchableListWithoutProjectSectionsOrSwipeDelete() throws {
        let source = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )

        #expect(source.contains(".searchable"))
        #expect(source.contains("PatternLibraryRow("))
        #expect(!source.contains("Section(group.projectName)"))
        #expect(!source.contains(".swipeActions"))
    }

    @Test func libraryOffersRecentAndNameSortsPlusAnUnrestrictedImporter() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryCollectionView.swift")
        let store = try readRepositoryFile("Sources/KnitNoteCore/Projects/JSONProjectStore.swift")

        #expect(source.contains("PatternLibrarySort.recentlyAdded"))
        #expect(source.contains("PatternLibrarySort.name"))
        #expect(source.contains("store.importPatternFromLibrary"))
        #expect(store.contains("origin: .library"))
        #expect(store.contains("targetProjectID: nil"))
        #expect(!source.contains(".disabled(store.projects.isEmpty)"))
    }

    @Test func existingImportShowsFeedbackAndCanNavigateToTheSavedDetail() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryCollectionView.swift")

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
        #expect(source.contains("patternRowAccessibilityLabel("))
        #expect(source.contains("patterns.library.row.accessibility.format"))
        #expect(source.contains("name: model.name"))
        #expect(source.contains("fileDescription: patternAssetDescription"))
        #expect(source.contains("usageDescription: usageDescription"))
    }

    @Test func rowStatusIsVisibleTextAndStaysOnOneReadableLine() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("Text(usageDescription)"))
        #expect(source.contains("LocaleAwareText.interpolated"))
        #expect(source.contains("defaultValue: \"\\(model.activeLinkCount) linked projects\""))
        #expect(source.contains(".lineLimit(1)"))
        #expect(source.contains(".minimumScaleFactor(0.8)"))
        #expect(!source.contains("foregroundStyle(model.activeLinkCount == 0 ? .clear"))
    }

    @Test func thumbnailLoadsTheOwnedLocalFileInsteadOfUsingANetworkImageLoader() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("Data(contentsOf:"))
        #expect(!source.contains("AsyncImage("))
    }

    @Test func youtubeRowsDelegateLazyArtworkToTheCancellationAwareLoader() throws {
        let source = try readRepositoryFile("KnitNote/Patterns/PatternLibraryRow.swift")

        #expect(source.contains("YouTubePatternThumbnailLoader("))
        #expect(source.contains("await loader.thumbnailURL(patternID: patternID, assetID: asset.id)"))
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
        let library = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(library.contains("LemonEmptyState("))
        #expect(library.contains("patterns.library.empty.title"))
        #expect(detail.contains("ViewThatFits"))
        #expect(detail.contains("ScrollView"))
    }

    @Test func youtubeDetailUsesACompactPhoneHeaderAndSixteenByNineArtwork() throws {
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(detail.contains("@Environment(\\.horizontalSizeClass)"))
        #expect(detail.contains("horizontalSizeClass == .compact"))
        #expect(detail.contains("compactHeader(pattern: pattern, asset: asset)"))
        #expect(detail.contains("asset.kind == .youtube ? 101 : 220"))
    }

    @Test func detailUsesAPlatformSafeNavigationTitleStyle() throws {
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")

        #expect(detail.contains(".patternDetailNavigationTitleStyle()"))
        #expect(detail.contains("#if os(iOS)"))
    }

    @Test func phoneImportRemainsReachableAndMacToolbarKeepsTextLabels() throws {
        let library = try readRepositoryFile(
            "KnitNote/Patterns/PatternLibraryCollectionView.swift"
        )
        let detail = try readRepositoryFile("KnitNote/Patterns/PatternDetailView.swift")
        let root = try readRepositoryFile("KnitNote/Patterns/PatternLibraryView.swift")

        #expect(library.contains("ToolbarItemGroup(placement: .primaryAction)"))
        #expect(library.contains("Label(\"patterns.add\", systemImage: \"plus\")"))
        #expect(library.contains(".accessibilityLabel(Text(\"patterns.add\"))"))
        #expect(library.contains(".fileImporter("))
        #expect(library.contains(".patternToolbarTextLabelStyle()"))
        #expect(detail.contains(".patternToolbarTextLabelStyle()"))
        #expect(root.contains("#if os(macOS)"))
        #expect(root.contains(".labelStyle(.titleAndIcon)"))
    }
}

private func sourceSlice(
    _ source: String,
    from startMarker: String,
    to endMarker: String
) throws -> Substring {
    let start = try #require(source.range(of: startMarker))
    let remainder = start.upperBound..<source.endIndex
    let end = try #require(source.range(of: endMarker, range: remainder))
    return source[start.lowerBound..<end.lowerBound]
}
