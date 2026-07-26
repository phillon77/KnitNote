import SwiftUI

struct ChooseLibraryPatternView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if options.isEmpty {
                    ContentUnavailableView(
                        "patterns.link.empty",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    ForEach(options) { option in
                        Button {
                            link(option.pattern.id)
                        } label: {
                            optionRow(option)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("patterns.link.choose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
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

    private var options: [ProjectPatternLinkOption] {
        ProjectPatternLinkIndex(
            patterns: store.patterns,
            usages: store.patternUsages,
            projectID: projectID,
            locale: locale
        ).options
    }

    private func optionRow(_ option: ProjectPatternLinkOption) -> some View {
        HStack(alignment: .top, spacing: 14) {
            PatternThumbnailView(patternID: option.pattern.id)
                .frame(width: 64, height: 80)

            VStack(alignment: .leading, spacing: 5) {
                Text(option.pattern.displayName)
                    .font(.headline)
                    .foregroundStyle(WatercolorTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if option.status == .relink {
                    Text("patterns.relink")
                        .font(.caption.bold())
                        .foregroundStyle(WatercolorTheme.actionBerry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: option))
    }

    private func accessibilityLabel(
        for option: ProjectPatternLinkOption
    ) -> Text {
        guard option.status == .relink else {
            return Text(option.pattern.displayName)
        }
        return Text(option.pattern.displayName)
            + Text(", ")
            + Text("patterns.relink")
    }

    private func link(_ patternID: UUID) {
        do {
            try store.linkPattern(patternID: patternID, to: projectID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
