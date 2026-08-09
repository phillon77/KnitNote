import SwiftUI

struct CounterManagerSave {
    let name: String
    let value: Int
    let reminderEdit: CounterReminderEdit
}

struct CounterManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let counter: ProjectCounter
    let onSave: (CounterManagerSave) -> Bool
    @State private var name = ""
    @State private var valueText = ""
    @State private var defaultName = ""
    @State private var hasLoaded = false
    @State private var hasEditedName = false
    @State private var hasInvalidValue = false

    var body: some View {
        NavigationStack {
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        nameEditor
                        valueEditor
                    }
                    VStack(spacing: 20) {
                        nameEditor
                        valueEditor
                    }
                }
                .padding()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(WatercolorBackground())
            .navigationTitle("counter.manage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { save() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
#else
        .frame(minWidth: 340, minHeight: 420)
#endif
        .tint(WatercolorTheme.actionBerry)
        .onAppear(perform: loadDraft)
    }

    private var nameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("counter.name")
                .font(.headline)
            TextField("counter.rename", text: Binding(
                get: { name },
                set: {
                    name = $0
                    hasEditedName = true
                }
            ))
            .textFieldStyle(.roundedBorder)
        }
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
    }

    private var valueEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("counter.value")
                .font(.headline)
            TextField("counter.value", text: $valueText)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("counter.value"))
                .onChange(of: valueText) { _, _ in hasInvalidValue = false }

            if hasInvalidValue {
                Text("counter.value")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityHint(Text("counter.value"))
            }

            valueControls

            Label {
                Text(reminderSummary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: counter.reminder?.isActive == true ? "bell" : "bell.slash")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("counter.manage"))
        }
        .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
    }

    private var valueControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                decrementButton
                incrementButton
                resetButton
            }
            VStack(alignment: .leading, spacing: 8) {
                decrementButton
                incrementButton
                resetButton
            }
        }
    }

    private var decrementButton: some View {
        Button("counter.minusOne", systemImage: "minus") {
            adjustValue(by: -1)
        }
        .buttonStyle(.borderless)
        .disabled(currentValue == 0)
        .accessibilityLabel(Text("counter.minusOne"))
    }

    private var incrementButton: some View {
        Button("counter.increment", systemImage: "plus") {
            adjustValue(by: 1)
        }
        .buttonStyle(.borderless)
        .disabled(currentValue == .max)
        .accessibilityLabel(Text("counter.increment"))
    }

    private var resetButton: some View {
        Button("counter.reset", systemImage: "arrow.counterclockwise", role: .destructive) {
            valueText = "0"
        }
        .buttonStyle(.borderless)
        .disabled(currentValue == 0)
        .accessibilityLabel(Text("counter.reset"))
    }

    private var currentValue: Int? {
        try? CounterValueInput.parse(valueText)
    }

    private var reminderSummary: String {
        guard let reminder = counter.reminder else { return "—" }
        let target = reminder.nextTarget.map { String($0) } ?? "—"
        let message = reminder.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? "\(message!) · \(target)" : target
    }

    private func loadDraft() {
        guard !hasLoaded else { return }
        defaultName = projectCounterDisplayName(counter, locale: locale)
        name = defaultName
        valueText = String(counter.value)
        hasLoaded = true
    }

    private func adjustValue(by delta: Int) {
        guard let value = currentValue else {
            hasInvalidValue = true
            return
        }
        let nextValue: Int
        if delta < 0 {
            nextValue = max(0, value - 1)
        } else {
            nextValue = value < .max ? value + 1 : value
        }
        valueText = String(nextValue)
    }

    private func save() {
        guard let value = currentValue else {
            hasInvalidValue = true
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = counter.customName == nil && !hasEditedName && trimmedName == defaultName
            ? ""
            : trimmedName
        let savedCounter = CounterManagerSave(
            name: savedName,
            value: value,
            reminderEdit: .unchanged
        )
        if onSave(savedCounter) { dismiss() }
    }
}
