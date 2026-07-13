import SwiftUI

struct EditPatternPageNoteView: View {
    @Environment(\.dismiss) private var dismiss
    let pageNumber: Int
    let onSave: (String) -> Void
    @State private var text: String

    init(pageNumber: Int, initialText: String, onSave: @escaping (String) -> Void) {
        self.pageNumber = pageNumber
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(String(format: String(localized: "patterns.pageNote.page"), pageNumber))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.save") {
                            onSave(text)
                            dismiss()
                        }
                    }
                }
        }
    }
}
