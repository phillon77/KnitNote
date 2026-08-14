import SwiftUI

enum PatternFolderEditorMode: Identifiable {
    case create
    case rename(PatternFolder)

    var id: String {
        switch self {
        case .create:
            "create"
        case let .rename(folder):
            "rename-\(folder.id.uuidString)"
        }
    }
}

struct PatternFolderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let mode: PatternFolderEditorMode
    @State private var draft: String
    @State private var errorKey: String?

    init(mode: PatternFolderEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            _draft = State(initialValue: "")
        case let .rename(folder):
            _draft = State(initialValue: folder.displayName)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("patterns.folder.name", text: $draft)
                    .frame(minHeight: 44)
                    .accessibilityLabel(Text("patterns.folder.name"))
                    .accessibilityHint(Text(titleKey))

                if let errorKey {
                    Text(LocalizedStringKey(errorKey))
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text(LocalizedStringKey(errorKey)))
                }
            }
            .navigationTitle(LocalizedStringKey(titleKey))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(Text("common.cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { save() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(Text("common.done"))
                        .accessibilityHint(Text(titleKey))
                }
            }
        }
        .tint(WatercolorTheme.actionBerry)
    }

    private var titleKey: String {
        switch mode {
        case .create: "patterns.folder.new"
        case .rename: "patterns.folder.rename"
        }
    }

    private var nameContext: PatternFolderNameContext {
        PatternFolderPresentation.nameContext(
            locale: locale,
            supportedLocaleIdentifiers: SupportedLocalization.v150Identifiers
        ) { key, candidateLocale in
            LocaleAwareText.string(key, locale: candidateLocale)
        }
    }

    private func save() {
        do {
            switch mode {
            case .create:
                try store.createPatternFolder(name: draft, nameContext: nameContext)
            case let .rename(folder):
                try store.renamePatternFolder(
                    id: folder.id,
                    to: draft,
                    nameContext: nameContext
                )
            }
            errorKey = nil
            dismiss()
        } catch {
            errorKey = PatternFolderFailurePresentation.key(for: error)
        }
    }
}
