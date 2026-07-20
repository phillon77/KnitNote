import SwiftUI

struct EditCounterNameView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let counter: ProjectCounter
    let onDone: (String, Int) -> Void
    @State private var name = ""
    @State private var value = 0
    @State private var defaultName = ""
    @State private var hasLoaded = false
    @State private var hasEditedName = false

    var body: some View {
        NavigationStack {
            Form {
                Section("counter.name") {
                    TextField("counter.rename", text: Binding(
                        get: { name },
                        set: { name = $0; hasEditedName = true }
                    ))
                }
                Section("counter.value") {
                    Text(value, format: .number)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                    HStack {
                        Button("counter.minusOne", systemImage: "minus") {
                            value = max(0, value - 1)
                        }
                        .buttonStyle(.borderless)
                        .disabled(value == 0)
                        Spacer()
                        Button("counter.reset", systemImage: "arrow.counterclockwise", role: .destructive) {
                            value = 0
                        }
                        .buttonStyle(.borderless)
                        .disabled(value == 0)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(WatercolorBackground())
            .navigationTitle("counter.manage")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { finish() }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 330)
        .presentationDetents([.medium])
        .tint(WatercolorTheme.actionBerry)
        .interactiveDismissDisabled()
        .onAppear {
            guard !hasLoaded else { return }
            defaultName = projectCounterDisplayName(counter, locale: locale)
            name = defaultName
            value = counter.value
            hasLoaded = true
        }
    }

    private func finish() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = counter.customName == nil && !hasEditedName && trimmedName == defaultName ? "" : trimmedName
        onDone(savedName, value)
        dismiss()
    }
}
