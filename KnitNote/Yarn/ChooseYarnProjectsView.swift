import SwiftUI

struct ChooseYarnProjectsView: View {
    @EnvironmentObject private var store: JSONProjectStore
    @Binding var selectedProjectIDs: Set<UUID>

    var body: some View {
        List(store.projects) { project in
            Button {
                toggle(project.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .foregroundStyle(.primary)
                        if project.isCompleted {
                            Text("project.status.completed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if selectedProjectIDs.contains(project.id) {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .accessibilityAddTraits(selectedProjectIDs.contains(project.id) ? .isSelected : [])
        }
        .navigationTitle("yarn.linkedProjects")
        .tint(WatercolorTheme.actionBerry)
    }

    private func toggle(_ id: UUID) {
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        } else {
            selectedProjectIDs.insert(id)
        }
    }
}
