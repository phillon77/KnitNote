import SwiftUI
import UniformTypeIdentifiers

private struct PendingPatternSelection: Identifiable {
    let itemID: UUID
    let candidatePatternIDs: [UUID]
    var id: UUID { itemID }
}

struct PatternLibraryView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var backupReminderPresenter: PatternBackupReminderPresenter
    @State private var navigationPath: [UUID] = []
    @State private var query = ""
    @State private var sort = PatternLibrarySort.recentlyAdded
    @State private var importing = false
    @State private var pendingSelection: PendingPatternSelection?
    @State private var existingPatternID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if store.patterns.isEmpty {
                    ZStack {
                        WatercolorBackground()
                        LemonEmptyState(
                            title: "patterns.library.empty.title",
                            message: "patterns.library.empty.message",
                            actionTitle: "patterns.add",
                            action: { importing = true }
                        )
                        .padding()
                        .frame(maxWidth: 520)
                    }
                } else {
                    List {
                        ForEach(visibleRows) { row in
                            if let asset = asset(for: row.patternID) {
                                NavigationLink(value: row.patternID) {
                                    PatternLibraryRow(model: row, asset: asset)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(WatercolorBackground())
                    .overlay {
                        if visibleRows.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                    }
                }
            }
            .navigationTitle("nav.patterns")
            .navigationDestination(for: UUID.self) { patternID in
                PatternDetailView(patternID: patternID)
            }
            .searchable(
                text: $query,
                placement: .automatic,
                prompt: Text("patterns.library.search")
            )
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        sortButton(PatternLibrarySort.recentlyAdded)
                        sortButton(PatternLibrarySort.name)
                    } label: {
                        Label("patterns.library.sort", systemImage: "arrow.up.arrow.down")
                            .patternToolbarTextLabelStyle()
                    }
                    .accessibilityLabel(Text("patterns.library.sort"))

                    Button {
                        importing = true
                    } label: {
                        Label("patterns.add", systemImage: "plus")
                            .patternToolbarTextLabelStyle()
                    }
                    .accessibilityLabel(Text("patterns.add"))
                }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.pdf, .png, .jpeg, .heic]
            ) { result in
                importPattern(result)
            }
            .sheet(item: $pendingSelection) { selection in
                chooseDuplicate(for: selection)
            }
            .alert(
                "patterns.library.alreadySaved.title",
                isPresented: Binding(
                    get: { existingPatternID != nil },
                    set: { if !$0 { existingPatternID = nil } }
                )
            ) {
                Button("patterns.library.alreadySaved.view") {
                    if let patternID = existingPatternID {
                        navigationPath.append(patternID)
                    }
                    existingPatternID = nil
                }
                Button("common.ok", role: .cancel) {
                    existingPatternID = nil
                }
            } message: {
                Text("patterns.library.alreadySaved.message")
            }
            .alert(
                "patterns.error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("common.ok") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .tint(WatercolorTheme.actionBerry)
    }

    private var rows: [PatternLibraryRowModel] {
        store.patterns.map { pattern in
            let projectNames = store.patternUsages.compactMap { usage -> String? in
                guard usage.patternID == pattern.id,
                      usage.isActive,
                      let project = store.projects.first(where: { $0.id == usage.projectID })
                else { return nil }
                return project.name
            }
            return PatternLibraryRowModel(
                patternID: pattern.id,
                name: pattern.displayName,
                note: pattern.note,
                activeProjectNames: projectNames,
                createdAt: pattern.createdAt
            )
        }
    }

    private var visibleRows: [PatternLibraryRowModel] {
        PatternLibraryIndex(rows: rows, locale: locale)
            .search(query, sortedBy: sort)
    }

    private func asset(for patternID: UUID) -> PatternAsset? {
        guard let pattern = store.patterns.first(where: { $0.id == patternID }) else {
            return nil
        }
        return store.patternAssets.first { $0.id == pattern.assetID }
    }

    private func sortButton(_ option: PatternLibrarySort) -> some View {
        Button {
            sort = option
        } label: {
            Label(option.localizationKey, systemImage: option.systemImage)
        }
    }

    private func importPattern(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        Task { @MainActor in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let outcome = try await store.importPatternFromLibrary(url)
                acceptImportOutcome(outcome)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func acceptImportOutcome(_ outcome: PatternImportOutcome) {
        backupReminderPresenter.accept(outcome)

        switch PatternLibraryImportPresentation(outcome: outcome) {
        case .none:
            pendingSelection = nil
            existingPatternID = nil
        case let .alreadySaved(patternID):
            pendingSelection = nil
            existingPatternID = patternID
        case let .chooseDuplicate(itemID, candidatePatternIDs):
            existingPatternID = nil
            pendingSelection = PendingPatternSelection(
                itemID: itemID,
                candidatePatternIDs: candidatePatternIDs
            )
        }
    }

    private func chooseDuplicate(
        for selection: PendingPatternSelection
    ) -> some View {
        NavigationStack {
            List(selection.candidatePatternIDs, id: \.self) { patternID in
                if let pattern = store.patterns.first(where: { $0.id == patternID }) {
                    Button(pattern.displayName) {
                        resolveDuplicate(
                            itemID: selection.itemID,
                            patternID: patternID
                        )
                    }
                    .frame(minHeight: 44)
                }
            }
            .navigationTitle("nav.patterns")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { pendingSelection = nil }
                }
            }
        }
    }

    private func resolveDuplicate(itemID: UUID, patternID: UUID) {
        Task { @MainActor in
            do {
                let outcome = try await store.processPatternInboxItem(
                    id: itemID,
                    selectingPatternID: patternID
                )
                acceptImportOutcome(outcome)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension View {
    @ViewBuilder
    func patternToolbarTextLabelStyle() -> some View {
        #if os(macOS)
        self.labelStyle(.titleAndIcon)
        #else
        self
        #endif
    }
}
