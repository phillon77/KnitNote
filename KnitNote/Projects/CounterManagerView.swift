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
    @State private var confirmingValueReset = false
    @State private var reminderDraft: CounterReminderDraft?
    @State private var showingReminderEditor = false
    @State private var confirmingReminderReplacement = false

    init(counter: ProjectCounter, onSave: @escaping (CounterManagerSave) -> Bool) {
        self.counter = counter
        self.onSave = onSave
        _reminderDraft = State(initialValue: Self.draft(from: counter.reminder))
    }

    var body: some View {
        NavigationStack {
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
                        .disabled(!hasValidReminderEdit)
                }
            }
        }
        .confirmationDialog("counter.reset", isPresented: $confirmingValueReset, titleVisibility: .visible) {
            Button("counter.reset", role: .destructive) {
                valueText = "0"
            }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog("counter.reminder.replace", isPresented: $confirmingReminderReplacement,
            titleVisibility: .visible
        ) {
            Button("counter.reminder.replace", role: .destructive) {
                persistCurrentDraft()
            }
            Button("common.cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingReminderEditor) {
            CounterReminderEditor(draft: $reminderDraft, counterValue: currentValue ?? counter.value)
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

            Label {
                Text(reminderSummary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: counter.reminder?.isActive == true ? "bell" : "bell.slash")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(reminderSummary))
            .accessibilityValue(Text(reminderSummary))

            Button {
                showingReminderEditor = true
            } label: {
                Label("counter.reminder.edit", systemImage: "bell.badge")
            }
            .frame(minHeight: 44)
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
            confirmingValueReset = true
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

    private var reminderSummary: String {
        guard let reminder = counter.reminder, reminder.isActive else {
            return LocaleAwareText.string("counter.reminder.none", locale: locale)
        }
        let target = reminder.nextTarget.map {
                "\(LocaleAwareText.string("counter.reminder.nextTarget", locale: locale)) \($0.formatted(.number.locale(locale)))"
        } ?? LocaleAwareText.string("counter.reminder.none", locale: locale)
        let message = reminder.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? "\(message!) · \(target)" : target
    }

    private var reminderEdit: CounterReminderEdit {
        let originalDraft = Self.draft(from: counter.reminder)
        if originalDraft == reminderDraft { return .unchanged }
        if let reminderDraft { return .replace(reminderDraft) }
        return .remove(expectedReminderID: counter.reminder?.id)
    }

    private var replacementNeedsConfirmation: Bool {
        guard case .replace = reminderEdit,
              counter.reminder?.isActive == true else { return false }
        return (counter.reminder?.acknowledgedCount ?? 0) > 0
            || counter.reminder?.pending != nil
    }

    private var hasValidReminderEdit: Bool {
        guard case let .replace(draft) = reminderEdit else { return true }
        guard let value = currentValue else { return false }
        return CounterReminder(draft: draft, anchorValue: value) != nil
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
        if replacementNeedsConfirmation {
            confirmingReminderReplacement = true
            return
        }
        if onSave(savedCounter) { dismiss() }
    }

    private func persistCurrentDraft() {
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
            value: value,
            reminderEdit: reminderEdit
        )
    }

    private static func draft(from reminder: CounterReminder?) -> CounterReminderDraft? {
        guard let reminder, reminder.isActive else { return nil }
        switch reminder.rule {
        case let .oneTime(target):
            return .oneTime(target: target, message: reminder.message)
        case let .repeating(interval, limit):
            return .repeating(interval: interval, limit: limit, message: reminder.message)
        }
    }
}
