import SwiftUI

struct ChoosePatternProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    let onChoose: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List(store.projects) { project in
                Button(project.name) {
                    onChoose(project.id)
                    dismiss()
                }
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
}
