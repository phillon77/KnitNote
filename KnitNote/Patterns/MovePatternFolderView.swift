import SwiftUI

struct MovePatternFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let patternID: UUID
    let currentFolderID: UUID?
    @State private var errorKey: String?

    var body: some View {
        NavigationStack {
            List {
                destinationButton(
                    title: LocaleAwareText.string(
                        "patterns.folder.uncategorized",
                        locale: locale
                    ),
                    folderID: nil
                )
                ForEach(sortedFolders) { folder in
                    destinationButton(title: folder.displayName, folderID: folder.id)
                }
            }
            .navigationTitle("patterns.folder.move")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(Text("common.cancel"))
                }
            }
            .alert(
                "patterns.error",
                isPresented: Binding(
                    get: { errorKey != nil },
                    set: { if !$0 { errorKey = nil } }
                )
            ) {
                Button("common.ok") {}
            } message: {
                Text(LocalizedStringKey(errorKey ?? "patterns.folder.error.saveFailed"))
            }
        }
        .tint(WatercolorTheme.actionBerry)
    }

    private var sortedFolders: [PatternFolder] {
        let identifiers = PatternFolderPresentation.rows(
            folders: store.patternFolders,
            patterns: [],
            locale: locale
        ).compactMap { row -> UUID? in
            guard case let .folder(folderID) = row.scope else { return nil }
            return folderID
        }
        return identifiers.compactMap { id in
            store.patternFolders.first { $0.id == id }
        }
    }

    private func destinationButton(title: String, folderID: UUID?) -> some View {
        Button {
            move(to: folderID)
        } label: {
            HStack {
                Text(verbatim: title)
                    .lineLimit(2)
                Spacer()
                if currentFolderID == folderID {
                    Image(systemName: "checkmark")
                }
            }
            .frame(minHeight: 44)
        }
        .accessibilityLabel(Text("\(title), \(LocaleAwareText.string("patterns.folder.move", locale: locale))"))
        .accessibilityHint(Text("patterns.folder.move"))
        .accessibilityAddTraits(currentFolderID == folderID ? .isSelected : [])
    }

    private func move(to folderID: UUID?) {
        do {
            try store.movePattern(id: patternID, toFolderID: folderID)
            errorKey = nil
            dismiss()
        } catch {
            errorKey = PatternFolderFailurePresentation.key(for: error)
        }
    }
}
