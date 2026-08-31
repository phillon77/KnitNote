import SwiftUI

struct KnittingReminderEditorView: View {
    private enum Mode: Hashable { case oneTime, repeating }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let reminderID: UUID?

    @State private var kind: KnittingReminderKind = .increase
    @State private var mode: Mode = .oneTime
    @State private var customText = ""
    @State private var firstTargetText = ""
    @State private var intervalText = "1"
    @State private var hasFiniteLimit = false
    @State private var limitText = "1"
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    init(projectID: UUID, reminderID: UUID?) {
        self.projectID = projectID
        self.reminderID = reminderID
    }

    var body: some View {
        Form {
            Section {
                Picker("Reminder kind", selection: $kind) {
                    ForEach(KnittingReminderKind.allCases, id: \.self) { kind in
                        Text(KnittingReminderSummary.kind(kind, locale: locale)).tag(kind)
                    }
                }

                TextField("Optional note", text: $customText, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Picker("Reminder schedule", selection: $mode) {
                    Text("One time").tag(Mode.oneTime)
                    Text("Repeating").tag(Mode.repeating)
                }
                .pickerStyle(.segmented)

                TextField("First row", text: $firstTargetText)
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                    .monospacedDigit()

                if mode == .repeating {
                    TextField("Interval", text: $intervalText)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .monospacedDigit()
                    Toggle("Limited repetitions", isOn: $hasFiniteLimit)
                    if hasFiniteLimit {
                        TextField("Number of times", text: $limitText)
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .monospacedDigit()
                    }
                }
            }

            if let draft = validDraft {
                Section("Summary") {
                    Text(KnittingReminderSummary.rule(rule(for: draft), locale: locale))
                    if !customText.isEmpty {
                        Text(verbatim: customText)
                    }
                }
            } else {
                Text("Enter whole-number row values greater than or equal to zero.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(reminderID == nil ? "New reminder" : "Edit reminder")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { save() }
                    .disabled(validDraft == nil || project?.isCompleted != false)
            }
        }
        .alert("error.saveFailed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok") {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
        .onAppear(perform: loadReminder)
    }

    private var project: StoredProject? { store.project(id: projectID) }

    private var reminder: KnittingReminder? {
        guard let reminderID else { return nil }
        return project?.knittingReminders.first { $0.id == reminderID }
    }

    private var validDraft: KnittingReminderDraft? {
        guard let firstTarget = try? CounterValueInput.parse(firstTargetText) else { return nil }
        let text = customText.isEmpty ? nil : customText
        switch mode {
        case .oneTime:
            return .oneTime(kind: kind, target: firstTarget, text: text)
        case .repeating:
            guard let interval = try? CounterValueInput.parse(intervalText), interval > 0 else { return nil }
            let limit: Int?
            if hasFiniteLimit {
                guard let finiteLimit = try? CounterValueInput.parse(limitText), finiteLimit > 0 else { return nil }
                limit = finiteLimit
            } else {
                limit = nil
            }
            return .repeating(
                kind: kind,
                firstTarget: firstTarget,
                interval: interval,
                limit: limit,
                text: text
            )
        }
    }

    private func rule(for draft: KnittingReminderDraft) -> KnittingReminderRule {
        switch draft {
        case let .oneTime(_, target, _): .oneTime(target: target)
        case let .repeating(_, firstTarget, interval, limit, _):
            .repeating(firstTarget: firstTarget, interval: interval, limit: limit)
        }
    }

    private func loadReminder() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let reminder else {
            firstTargetText = "0"
            return
        }
        kind = reminder.kind
        customText = reminder.text ?? ""
        switch reminder.rule {
        case let .oneTime(target):
            mode = .oneTime
            firstTargetText = String(target)
        case let .repeating(firstTarget, interval, limit):
            mode = .repeating
            firstTargetText = String(firstTarget)
            intervalText = String(interval)
            hasFiniteLimit = limit != nil
            limitText = String(limit ?? 1)
        }
    }

    private func save() {
        guard let draft = validDraft else { return }
        do {
            if let reminder {
                try store.updateKnittingReminder(
                    projectID: projectID,
                    reminderID: reminder.id,
                    observedRevision: reminder.mutationRevision,
                    draft: draft
                )
            } else {
                guard project?.mainCounterID != nil else { return }
                try store.addKnittingReminder(projectID: projectID, draft: draft)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
