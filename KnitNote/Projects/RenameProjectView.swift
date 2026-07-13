import SwiftUI
struct RenameProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    @State private var name = ""
    var body: some View { NavigationStack { Form { TextField("project.name", text: $name) }.scrollContentBackground(.hidden).background(WatercolorBackground()).navigationTitle("project.rename").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("common.save") { try? store.rename(id: projectID, to: name); dismiss() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }}.frame(minWidth: 320, minHeight: 180).tint(WatercolorTheme.actionBerry).onAppear { name = store.project(id: projectID)?.name ?? "" } }
}
