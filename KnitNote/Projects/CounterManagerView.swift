import SwiftUI
#if os(iOS)
import UIKit
#endif

private enum CounterManagerPresentationPolicy {
    static let iPhoneWidth: CGFloat = 340
    static let iPhoneHeight: CGFloat = 420
    static let iPadWidth: CGFloat = 720
    static let iPadHeight: CGFloat = 560
    static let macMinimumWidth: CGFloat = 560
    static let macMinimumHeight: CGFloat = 420
}

struct CounterManagerSave {
    let name: String
    let value: Int
}

struct CounterManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let counter: ProjectCounter
    let projectID: UUID
    let mainCounterID: UUID
    let reminderID: UUID?
    let onSave: (CounterManagerSave) -> Bool
    @State private var name = ""
    @State private var valueText = ""
    @State private var defaultName = ""
    @State private var hasLoaded = false
    @State private var hasEditedName = false
    @State private var hasInvalidValue = false
    @State private var confirmingValueReset = false

    init(
        counter: ProjectCounter,
        projectID: UUID,
        mainCounterID: UUID,
        reminderID: UUID?,
        onSave: @escaping (CounterManagerSave) -> Bool
    ) {
        self.counter = counter
        self.projectID = projectID
        self.mainCounterID = mainCounterID
        self.reminderID = reminderID
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            editorLayout
            .padding()
            .frame(maxWidth: usesLargeIPadPresentation ? CounterManagerPresentationPolicy.iPadWidth : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        .confirmationDialog("counter.reset", isPresented: $confirmingValueReset, titleVisibility: .visible) {
            Button("counter.reset", role: .destructive) {
                valueText = "0"
            }
            Button("common.cancel", role: .cancel) {}
        }
#if os(macOS)
        .frame(
            minWidth: CounterManagerPresentationPolicy.macMinimumWidth,
            minHeight: CounterManagerPresentationPolicy.macMinimumHeight
        )
#elseif os(iOS)
        .frame(
            minWidth: usesLargeIPadPresentation
                ? CounterManagerPresentationPolicy.iPadWidth
                : CounterManagerPresentationPolicy.iPhoneWidth,
            idealWidth: usesLargeIPadPresentation ? CounterManagerPresentationPolicy.iPadWidth : nil,
            minHeight: usesLargeIPadPresentation
                ? CounterManagerPresentationPolicy.iPadHeight
                : CounterManagerPresentationPolicy.iPhoneHeight,
            idealHeight: usesLargeIPadPresentation ? CounterManagerPresentationPolicy.iPadHeight : nil
        )
#else
        .frame(
            minWidth: CounterManagerPresentationPolicy.iPhoneWidth,
            minHeight: CounterManagerPresentationPolicy.iPhoneHeight
        )
#endif
        .tint(WatercolorTheme.actionBerry)
        .onAppear(perform: loadDraft)
    }

    @ViewBuilder
    private var editorLayout: some View {
        if usesLargeIPadPresentation {
            VStack(alignment: .leading, spacing: 20) {
                nameEditor
                valueEditor
            }
        } else {
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
        }
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
                .accessibilityLabel(Text("counter.value.edit"))
                .onChange(of: valueText) { _, _ in hasInvalidValue = false }

            if hasInvalidValue {
                Text("counter.value.invalid")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("counter.value.invalid"))
            }

            valueControls

            if counter.id != mainCounterID, let reminderID {
                NavigationLink {
                    KnittingReminderEditorView(projectID: projectID, reminderID: reminderID)
                } label: {
                    Label("knittingReminder.action.editMigrated", systemImage: "bell.badge")
                }
                .frame(minHeight: 44)
            }
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
        Button {
            adjustValue(by: -1)
        } label: {
            Text("−1")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 52, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(currentValue == 0)
        .accessibilityLabel(Text("counter.minusOne"))
    }

    private var incrementButton: some View {
        Button {
            adjustValue(by: 1)
        } label: {
            Text("+1")
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 52, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(currentValue == .max)
        .accessibilityLabel(Text("counter.increment"))
    }

    private var resetButton: some View {
        Button(role: .destructive) {
            confirmingValueReset = true
        } label: {
            Label {
                Text("0")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "arrow.counterclockwise")
            }
            .font(.headline)
            .frame(minWidth: 52, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(currentValue == 0)
        .accessibilityLabel(Text("counter.reset"))
    }

    private var currentValue: Int? {
        try? CounterValueInput.parse(valueText)
    }

    private var usesLargeIPadPresentation: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
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
        guard let savedCounter = currentSave() else { return }
        if onSave(savedCounter) { dismiss() }
    }

    private func currentSave() -> CounterManagerSave? {
        guard let value = currentValue else {
            hasInvalidValue = true
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedName = counter.customName == nil && !hasEditedName && trimmedName == defaultName
            ? ""
            : trimmedName
        return CounterManagerSave(
            name: savedName,
            value: value
        )
    }
}
