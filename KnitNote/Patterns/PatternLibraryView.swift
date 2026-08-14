import SwiftUI

struct PatternLibraryView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @State private var selection: PatternLibraryScope? = .all
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var folderEditor: PatternFolderEditorMode?
    @State private var pendingDeletion: PatternFolder?
    @State private var showingDeleteConfirmation = false
    @State private var deletionErrorKey: String?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            PatternFolderSidebarView(
                selection: $selection,
                onCreate: { folderEditor = .create },
                onRename: { folderEditor = .rename($0) },
                onDelete: { folder in
                    pendingDeletion = folder
                    showingDeleteConfirmation = true
                }
            )
        } detail: {
            PatternLibraryCollectionView(scope: selection ?? .all)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $folderEditor) { mode in
            PatternFolderEditorView(mode: mode)
                .environment(\.locale, locale)
        }
        .confirmationDialog(
            "patterns.folder.delete.title",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("common.delete", role: .destructive) {
                deletePendingFolder()
            }
            .accessibilityLabel(Text("patterns.folder.delete.title"))
            .accessibilityHint(Text(deleteMessage))
            Button("common.cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            "patterns.error",
            isPresented: Binding(
                get: { deletionErrorKey != nil },
                set: { if !$0 { deletionErrorKey = nil } }
            )
        ) {
            Button("common.retry") {
                showingDeleteConfirmation = pendingDeletion != nil
            }
            Button("common.cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(LocalizedStringKey(
                deletionErrorKey ?? "patterns.folder.error.saveFailed"
            ))
        }
        .tint(WatercolorTheme.actionBerry)
    }

    private var deleteMessage: String {
        let count = pendingDeletion.map { folder in
            store.patterns.count(where: { $0.folderID == folder.id })
        } ?? 0
        return LocaleAwareText.interpolated(
            "patterns.folder.delete.message",
            defaultValue: "The folder will be deleted and \(count) patterns will move to Uncategorized.",
            locale: locale
        )
    }

    private func deletePendingFolder() {
        guard let folder = pendingDeletion else { return }
        do {
            try store.deletePatternFolder(id: folder.id)
            if let selection {
                self.selection = PatternFolderPresentation.selectionAfterDeleting(
                    selection,
                    deletedFolderID: folder.id
                )
            }
            deletionErrorKey = nil
            pendingDeletion = nil
        } catch {
            deletionErrorKey = PatternFolderFailurePresentation.key(for: error)
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
