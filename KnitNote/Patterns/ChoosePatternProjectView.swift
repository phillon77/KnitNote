import SwiftUI

struct ChoosePatternProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let onChoose: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List(projects) { project in
                Button {
                    onChoose(project.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .fixedSize(horizontal: false, vertical: true)
                        if project.isCompleted {
                            Text("project.status.completed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("patterns.chooseProject")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
        .tint(WatercolorTheme.actionBerry)
    }

    private var projects: [StoredProject] {
        store.projects.sorted {
            if $0.isCompleted != $1.isCompleted {
                return !$0.isCompleted
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
