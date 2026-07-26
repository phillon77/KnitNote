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
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID

    @State private var showingLibraryChooser = false
    @State private var showingImporter = false
    @State private var selectedPattern: ProjectPatternReaderSelection?
    @State private var pendingUnlink: ProjectPatternReaderSelection?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(projectPatterns) { selection in
                Button {
                    selectedPattern = selection
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
                        Button("patterns.linkExisting", systemImage: "link.badge.plus") {
                            showingLibraryChooser = true
                        }
                        Button("patterns.importNew", systemImage: "square.and.arrow.down") {
                            showingImporter = true
                        }
                    } label: {
                        Label("patterns.add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingLibraryChooser) {
                ChooseLibraryPatternView(projectID: projectID)
            }
            .sheet(isPresented: $showingImporter) {
                PatternImportResultView(projectID: projectID)
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
        HStack(alignment: .top, spacing: 14) {
            PatternThumbnailView(patternID: selection.pattern.id)
                .frame(width: 76, height: 96)

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
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
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
