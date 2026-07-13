import SwiftUI

struct CreateProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JSONProjectStore
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form { TextField("project.name", text: $name) }
                .navigationTitle("project.create")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("project.create") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .alert("error.saveFailed", isPresented: Binding(
                    get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
                )) { Button("common.ok") {} } message: { Text(errorMessage ?? "") }
        }
        .frame(minWidth: 320, minHeight: 180)
    }

    private func create() {
        do {
            try store.add(name: name)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
