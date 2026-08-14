import SwiftUI

struct PatternFolderSidebarView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @Binding var selection: PatternLibraryScope?
    let onCreate: () -> Void
    let onRename: (PatternFolder) -> Void
    let onDelete: (PatternFolder) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                NavigationLink(value: row.scope) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title(for: row.title))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(countDescription(row.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text("\(title(for: row.title)), \(countDescription(row.count))")
                    )
                    .accessibilityAddTraits(selection == row.scope ? .isSelected : [])
                }
                .tag(row.scope)
                .contextMenu {
                    if let folder = folder(for: row.scope) {
                        Button("patterns.folder.rename", systemImage: "pencil") {
                            onRename(folder)
                        }
                        .accessibilityLabel(Text("patterns.folder.rename"))
                        .accessibilityHint(Text("patterns.folder.rename"))

                        Button("common.delete", systemImage: "trash", role: .destructive) {
                            onDelete(folder)
                        }
                        .accessibilityLabel(Text("patterns.folder.delete.title"))
                        .accessibilityHint(Text(deleteDescription(row.count)))
                    }
                }
            }
        }
        .navigationTitle(LocaleAwareText.string("nav.patterns", locale: locale))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("patterns.folder.new", systemImage: "plus", action: onCreate)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(Text("patterns.folder.new"))
                    .accessibilityHint(Text("patterns.folder.name"))
            }
        }
    }

    private var rows: [PatternFolderSidebarRow] {
        PatternFolderPresentation.rows(
            folders: store.patternFolders,
            patterns: store.patterns,
            locale: locale
        )
    }

    private func title(for title: PatternFolderSidebarTitle) -> String {
        switch title {
        case let .localizedKey(key):
            LocaleAwareText.string(key, locale: locale)
        case let .userContent(value):
            value
        }
    }

    private func countDescription(_ count: Int) -> String {
        LocaleAwareText.interpolated(
            "patterns.folder.count",
            defaultValue: "\(count) patterns",
            locale: locale
        )
    }

    private func deleteDescription(_ count: Int) -> String {
        LocaleAwareText.interpolated(
            "patterns.folder.delete.message",
            defaultValue: "The folder will be deleted and \(count) patterns will move to Uncategorized.",
            locale: locale
        )
    }

    private func folder(for scope: PatternLibraryScope) -> PatternFolder? {
        guard case let .folder(folderID) = scope else { return nil }
        return store.patternFolders.first { $0.id == folderID }
    }
}
