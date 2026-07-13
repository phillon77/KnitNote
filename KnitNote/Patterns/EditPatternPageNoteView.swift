import SwiftUI

struct EditPatternPageNoteView: View {
    @Environment(\.dismiss) private var dismiss
    let pageNumber: Int
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(String(format: String(localized: "patterns.pageNote.page"), pageNumber))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") {
                            onCancel()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.save") {
                            onSave()
                            dismiss()
                        }
                    }
                }
        }
    }
}
