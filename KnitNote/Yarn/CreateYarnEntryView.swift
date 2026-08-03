import SwiftUI

struct CreateYarnEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var creationSeed: YarnLabelDraftSeed?
    @State private var labelPhotos: [Data] = []
    @State private var showingEditor = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                YarnLabelScanLauncher { output in
                    creationSeed = output.seed
                    labelPhotos = output.labelPhotos
                    showingEditor = true
                } label: {
                    entryRow(
                        title: "yarn.scan.action",
                        subtitle: "yarn.scan.action.hint",
                        systemImage: "viewfinder"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    creationSeed = nil
                    labelPhotos = []
                    showingEditor = true
                } label: {
                    entryRow(
                        title: "yarn.addManually",
                        subtitle: "yarn.addManually.hint",
                        systemImage: "square.and.pencil"
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(24)
            .background(WatercolorBackground())
            .navigationTitle("yarn.create")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEditor) {
                CreateYarnView(seed: creationSeed, labelPhotos: labelPhotos) {
                    dismiss()
                }
            }
        }
        .frame(minWidth: 360, minHeight: 380)
        .tint(WatercolorTheme.actionBerry)
    }

    private func entryRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 42, height: 42)
                .foregroundStyle(WatercolorTheme.actionBerry)
                .background(.thinMaterial, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .contentShape(.rect)
    }
}
