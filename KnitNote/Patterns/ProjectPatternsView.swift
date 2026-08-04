import SwiftUI

private struct ProjectPatternReaderSelection: Identifiable {
    let usage: PatternProjectUsage
    let pattern: StoredPattern
    let asset: PatternAsset

    var id: UUID { usage.id }
}

struct ProjectPatternsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID

    @State private var showingLibraryChooser = false
    @State private var showingImporter = false
    @State private var showingYouTubeImporter = false
    @State private var selectedPattern: ProjectPatternReaderSelection?
    @State private var pendingUnlink: ProjectPatternReaderSelection?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(projectPatterns) { selection in
                Button {
                    open(selection)
                } label: {
                    projectPatternRow(selection)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("patterns.unlink", role: .destructive) {
                        pendingUnlink = selection
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("patterns.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(ProjectPatternAddAction.allCases) { action in
                            Button(LocalizedStringKey(action.localizationKey), systemImage: action.systemImageName) {
                                performAddAction(action)
                            }
                        }
                    } label: {
                        Label("patterns.add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingLibraryChooser) {
                ChooseLibraryPatternView(projectID: projectID)
#if os(macOS)
                    .frame(
                        minWidth: CGFloat(KnitNoteMacWindowSizingPolicy.minimumWidth),
                        minHeight: CGFloat(KnitNoteMacWindowSizingPolicy.minimumHeight)
                    )
#endif
            }
            .sheet(isPresented: $showingImporter) {
                PatternImportResultView(projectID: projectID)
            }
            .sheet(isPresented: $showingYouTubeImporter) {
                AddYouTubePatternView(targetProjectID: projectID)
                    .environment(\.locale, locale)
            }
            .patternReaderPresentation(item: $selectedPattern) { selection in
                PatternReaderView(context: .project(
                    patternID: selection.pattern.id,
                    usageID: selection.usage.id,
                    projectID: projectID,
                    projectIsCompleted: projectIsCompleted
                ))
            }
            .confirmationDialog(
                "patterns.unlink.confirm.title",
                isPresented: Binding(
                    get: { pendingUnlink != nil },
                    set: { if !$0 { pendingUnlink = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("patterns.unlink", role: .destructive) {
                    unlinkPending()
                }
                Button("common.cancel", role: .cancel) {
                    pendingUnlink = nil
                }
            } message: {
                Text("patterns.unlink.confirm.message")
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

    private func projectPatternRow(
        _ selection: ProjectPatternReaderSelection
    ) -> some View {
        let thumbnailLayout = PatternListThumbnailLayout.resolve(for: selection.asset.kind)

        return HStack(alignment: .top, spacing: 14) {
            PatternThumbnailView(patternID: selection.pattern.id)
                .frame(
                    width: CGFloat(thumbnailLayout.width),
                    height: CGFloat(thumbnailLayout.height)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(selection.pattern.displayName)
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(patternAssetDescription(selection.asset, locale: locale))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: CGFloat(thumbnailLayout.minimumRowHeight),
            alignment: .leading
        )
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(selection.pattern.displayName)
                + Text(", ")
                + Text(patternAssetDescription(selection.asset, locale: locale))
        )
    }

    private var projectPatterns: [ProjectPatternReaderSelection] {
        store.patternUsages.compactMap { usage in
            guard usage.projectID == projectID,
                  usage.isActive,
                  let pattern = store.patterns.first(where: { $0.id == usage.patternID }),
                  let asset = store.patternAssets.first(where: { $0.id == pattern.assetID })
            else { return nil }
            return .init(usage: usage, pattern: pattern, asset: asset)
        }.sorted {
            if $0.usage.sortOrder != $1.usage.sortOrder {
                return $0.usage.sortOrder < $1.usage.sortOrder
            }
            return $0.usage.id.uuidString < $1.usage.id.uuidString
        }
    }

    private var projectIsCompleted: Bool {
        store.project(id: projectID)?.isCompleted ?? true
    }

    private func open(_ selection: ProjectPatternReaderSelection) {
        switch projectPatternOpenRoute(for: selection.asset) {
        case .externalYouTube:
            openYouTube(selection)
        case .reader:
            selectedPattern = selection
        }
    }

    private func performAddAction(_ action: ProjectPatternAddAction) {
        switch action {
        case .linkExisting:
            showingLibraryChooser = true
        case .importFile:
            showingImporter = true
        case .addYouTube:
            showingYouTubeImporter = true
        }
    }

    private func openYouTube(_ selection: ProjectPatternReaderSelection) {
        guard let link = try? store.youtubeLink(patternID: selection.pattern.id) else {
            errorMessage = String(localized: "patterns.youtube.error.open")
            return
        }
        openURL(link.canonicalURL) { accepted in
            if accepted {
                try? store.markPatternOpened(id: selection.pattern.id)
            } else {
                errorMessage = String(localized: "patterns.youtube.error.open")
            }
        }
    }

    private func unlinkPending() {
        guard let selection = pendingUnlink else { return }
        do {
            try store.unlinkPattern(patternID: selection.pattern.id, from: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingUnlink = nil
    }
}
