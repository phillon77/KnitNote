import SwiftUI

struct KnittingReminderEditorView: View {
    private enum Mode: Hashable { case oneTime, repeating }
    private struct PendingProgressResetUpdate {
        let reminderID: UUID
        let observedRevision: UInt64
        let draft: KnittingReminderDraft
        let proposedSummary: String
    }

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
    @State private var capturedReminderRevision: UInt64?
    @State private var requiresProgressResetConfirmation = false
    @State private var pendingProgressResetUpdate: PendingProgressResetUpdate?
    @State private var isExistingReminderUnavailable = false
    @State private var errorMessage: String?

    init(projectID: UUID, reminderID: UUID?) {
        self.projectID = projectID
        self.reminderID = reminderID
    }

    var body: some View {
        Form {
            Section {
                Picker(
                    LocaleAwareText.string("knittingReminder.editor.kind", locale: locale),
                    selection: $kind
                ) {
                    ForEach(KnittingReminderKind.allCases, id: \.self) { kind in
                        Text(KnittingReminderSummary.kind(kind, locale: locale)).tag(kind)
                    }
                }

                TextField(
                    LocaleAwareText.string("knittingReminder.editor.note", locale: locale),
                    text: $customText,
                    axis: .vertical
                )
                    .lineLimit(2...4)
            }

            Section {
                Picker(
                    LocaleAwareText.string("knittingReminder.editor.schedule", locale: locale),
                    selection: $mode
                ) {
                    Text(verbatim: LocaleAwareText.string(
                        "knittingReminder.editor.schedule.oneTime",
                        locale: locale
                    )).tag(Mode.oneTime)
                    Text(verbatim: LocaleAwareText.string(
                        "knittingReminder.editor.schedule.repeating",
                        locale: locale
                    )).tag(Mode.repeating)
                }
                .pickerStyle(.segmented)

                TextField(
                    LocaleAwareText.string("knittingReminder.editor.firstRow", locale: locale),
                    text: $firstTargetText
                )
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
                    .monospacedDigit()
                if validationIssue == .firstTarget {
                    validationError
                }

                if mode == .repeating {
                    TextField(
                        LocaleAwareText.string("knittingReminder.editor.interval", locale: locale),
                        text: $intervalText
                    )
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .monospacedDigit()
                    if validationIssue == .interval {
                        validationError
                    }
                    Toggle(
                        LocaleAwareText.string("knittingReminder.editor.limited", locale: locale),
                        isOn: $hasFiniteLimit
                    )
                    if hasFiniteLimit {
                        TextField(
                            LocaleAwareText.string("knittingReminder.editor.limit", locale: locale),
                            text: $limitText
                        )
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .monospacedDigit()
                        if validationIssue == .limit {
                            validationError
                        }
                    }
                }
            }

            if let draft = validDraft {
                Section(LocaleAwareText.string(
                    "knittingReminder.editor.summary",
                    locale: locale
                )) {
                    Text(KnittingReminderSummary.rule(rule(for: draft), locale: locale))
                    if !customText.isEmpty {
                        Text(verbatim: customText)
                    }
                }
            }
        }
        .navigationTitle(LocaleAwareText.string(
            reminderID == nil
                ? "knittingReminder.editor.title.new"
                : "knittingReminder.editor.title.edit",
            locale: locale
        ))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
#if os(macOS)
                    .keyboardShortcut(.cancelAction)
#endif
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { save() }
#if os(macOS)
                    .keyboardShortcut(.defaultAction)
#endif
                    .disabled(
                        validDraft == nil ||
                        project?.isCompleted != false ||
                        isExistingReminderUnavailable
                    )
            }
        }
        .alert("error.saveFailed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok") {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
        .alert("knittingReminder.confirm.replaceProgress", isPresented: Binding(
            get: { pendingProgressResetUpdate != nil },
            set: { if !$0 { pendingProgressResetUpdate = nil } }
        )) {
            Button("common.save") { confirmProgressResetUpdate() }
            Button("common.cancel", role: .cancel) {
                pendingProgressResetUpdate = nil
            }
        } message: {
            Text(verbatim: pendingProgressResetUpdate?.proposedSummary ?? "")
        }
        .onAppear(perform: loadReminder)
    }

    private var project: StoredProject? { store.project(id: projectID) }

    private var reminder: KnittingReminder? {
        guard let reminderID else { return nil }
        return project?.knittingReminders.first { $0.id == reminderID }
    }

    private var firstTarget: Int? {
        try? CounterValueInput.parse(firstTargetText)
    }

    private var interval: Int? {
        try? CounterValueInput.parse(intervalText)
    }

    private var finiteLimit: Int? {
        try? CounterValueInput.parse(limitText)
    }

    private var validationIssue: KnittingReminderDraftValidationIssue? {
        KnittingReminderDraftValidation.issue(
            firstTarget: firstTarget,
            isRepeating: mode == .repeating,
            interval: interval,
            hasFiniteLimit: hasFiniteLimit,
            limit: finiteLimit
        )
    }

    private var validationError: some View {
        Text(verbatim: LocaleAwareText.string(
            "knittingReminder.editor.validation",
            locale: locale
        ))
            .font(.footnote)
            .foregroundStyle(.red)
    }

    private var validDraft: KnittingReminderDraft? {
        guard validationIssue == nil, let firstTarget else { return nil }
        let text = customText.isEmpty ? nil : customText
        switch mode {
        case .oneTime:
            return .oneTime(kind: kind, target: firstTarget, text: text)
        case .repeating:
            guard let interval else { return nil }
            let limit: Int?
            if hasFiniteLimit {
                guard let finiteLimit else { return nil }
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
        guard reminderID != nil else {
            firstTargetText = "0"
            return
        }
        guard let reminder else {
            markExistingReminderUnavailable()
            return
        }
        capturedReminderRevision = reminder.mutationRevision
        requiresProgressResetConfirmation =
            KnittingReminderEditPolicy.requiresProgressResetConfirmation(reminder)
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

    private func performUpdate(
        reminderID: UUID,
        observedRevision: UInt64,
        draft: KnittingReminderDraft
    ) throws {
        try store.updateKnittingReminder(
            projectID: projectID,
            reminderID: reminderID,
            observedRevision: observedRevision,
            draft: draft
        )
    }

    private func save() {
        guard let draft = validDraft else { return }
        do {
            if let reminderID {
                guard let capturedReminderRevision else {
                    markExistingReminderUnavailable()
                    return
                }
                if requiresProgressResetConfirmation {
                    var summary = KnittingReminderSummary.rule(rule(for: draft), locale: locale)
                    if !customText.isEmpty { summary += "\n\(customText)" }
                    pendingProgressResetUpdate = PendingProgressResetUpdate(
                        reminderID: reminderID,
                        observedRevision: capturedReminderRevision,
                        draft: draft,
                        proposedSummary: summary
                    )
                    return
                }
                try performUpdate(
                    reminderID: reminderID,
                    observedRevision: capturedReminderRevision,
                    draft: draft
                )
            } else {
                guard project?.mainCounterID != nil else { return }
                try store.addKnittingReminder(projectID: projectID, draft: draft)
            }
            dismiss()
        } catch {
            if let error = error as? KnittingReminderMutationError,
               error == .occurrenceNotFound {
                markExistingReminderUnavailable()
            } else {
                errorMessage = KnittingReminderSummary.error(error, locale: locale)
            }
        }
    }

    private func confirmProgressResetUpdate() {
        guard let pending = pendingProgressResetUpdate else { return }
        pendingProgressResetUpdate = nil
        do {
            try performUpdate(
                reminderID: pending.reminderID,
                observedRevision: pending.observedRevision,
                draft: pending.draft
            )
            dismiss()
        } catch {
            handleSaveError(error)
        }
    }

    private func handleSaveError(_ error: Error) {
        if let error = error as? KnittingReminderMutationError,
           error == .occurrenceNotFound {
            markExistingReminderUnavailable()
        } else {
            errorMessage = KnittingReminderSummary.error(error, locale: locale)
        }
    }

    private func markExistingReminderUnavailable() {
        isExistingReminderUnavailable = true
        errorMessage = LocaleAwareText.string(
            "knittingReminder.error.unavailable",
            locale: locale
        )
    }
}
