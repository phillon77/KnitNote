import SwiftUI

extension StoredProject {
    var activeKnittingReminderCount: Int {
        knittingReminders.filter { $0.state == .active }.count
    }
}

struct KnittingReminderListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID

    @State private var showingNewReminder = false
    @State private var reminderPendingStop: KnittingReminder?
    @State private var reminderPendingReset: KnittingReminder?
    @State private var reminderPendingDeletion: KnittingReminder?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let project {
                List {
                    Section("knittingReminder.section.active") {
                        ForEach(activeReminders) { reminder in
                            reminderRow(reminder, project: project)
                        }
                    }
                    Section("knittingReminder.section.ended") {
                        ForEach(endedReminders) { reminder in
                            reminderRow(reminder, project: project)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    LocaleAwareText.string("knittingReminder.list.unavailable", locale: locale),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .navigationTitle(LocaleAwareText.string("knittingReminder.list.title", locale: locale))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewReminder = true
                } label: {
                    Label(
                        LocaleAwareText.string("knittingReminder.list.add", locale: locale),
                        systemImage: "plus"
                    )
                }
#if os(macOS)
                .keyboardShortcut(.defaultAction)
#endif
                .disabled(project?.isCompleted != false)
            }
#if os(macOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
#endif
        }
        .sheet(isPresented: $showingNewReminder) {
            NavigationStack {
                KnittingReminderEditorView(projectID: projectID, reminderID: nil)
            }
        }
        .confirmationDialog("knittingReminder.confirm.stop", isPresented: Binding(
            get: { reminderPendingStop != nil },
            set: { if !$0 { reminderPendingStop = nil } }
        ), titleVisibility: .visible) {
            Button("knittingReminder.action.stop", role: .destructive) {
                if let reminder = reminderPendingStop { apply(.stop, to: reminder) }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog("knittingReminder.confirm.reset", isPresented: Binding(
            get: { reminderPendingReset != nil },
            set: { if !$0 { reminderPendingReset = nil } }
        ), titleVisibility: .visible) {
            Button("knittingReminder.action.reset") {
                if let reminder = reminderPendingReset { apply(.resetLatest, to: reminder) }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog("knittingReminder.confirm.delete", isPresented: Binding(
            get: { reminderPendingDeletion != nil },
            set: { if !$0 { reminderPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("knittingReminder.action.delete", role: .destructive) {
                if let reminder = reminderPendingDeletion { delete(reminder) }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .alert("error.saveFailed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok") {}
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private var project: StoredProject? { store.project(id: projectID) }

    private var activeReminders: [KnittingReminder] {
        guard let project else { return [] }
        return ordered(project.knittingReminders.filter { $0.state == .active })
    }

    private var endedReminders: [KnittingReminder] {
        guard let project else { return [] }
        return ordered(project.knittingReminders.filter { $0.state != .active })
    }

    private func ordered(_ reminders: [KnittingReminder]) -> [KnittingReminder] {
        reminders.sorted { lhs, rhs in
            let leftTarget = lhs.progress.nextTarget ?? Int.max
            let rightTarget = rhs.progress.nextTarget ?? Int.max
            if leftTarget != rightTarget { return leftTarget < rightTarget }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    @ViewBuilder
    private func reminderRow(_ reminder: KnittingReminder, project: StoredProject) -> some View {
        if project.isCompleted {
            reminderContent(reminder, project: project)
        } else {
            NavigationLink {
                KnittingReminderEditorView(projectID: projectID, reminderID: reminder.id)
            } label: {
                reminderContent(reminder, project: project)
            }
            .contextMenu { reminderActions(reminder) }
        }
    }

    @ViewBuilder
    private func reminderContent(_ reminder: KnittingReminder, project: StoredProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(KnittingReminderSummary.kind(reminder.kind, locale: locale))
                .font(.headline)
            if let text = reminder.text, !text.isEmpty {
                Text(verbatim: text)
                    .lineLimit(2)
            }
            Text(KnittingReminderSummary.nextTarget(reminder.progress.nextTarget, locale: locale))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(KnittingReminderSummary.rule(reminder.rule, locale: locale))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(KnittingReminderSummary.state(reminder.state, locale: locale))
                .font(.footnote.weight(.semibold))
            if reminder.counterID != project.mainCounterID,
               let counter = project.counters.first(where: { $0.id == reminder.counterID }) {
                Text(KnittingReminderSummary.secondaryCounter(
                    projectCounterDisplayName(counter, locale: locale),
                    locale: locale
                ))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(WatercolorTheme.actionBerry)
            }
        }
    }

    @ViewBuilder
    private func reminderActions(_ reminder: KnittingReminder) -> some View {
        if reminder.state == .active {
            Button("knittingReminder.action.stop", role: .destructive) {
                reminderPendingStop = reminder
            }
        }
        if reminder.progress.latestHandled != nil {
            Button("knittingReminder.action.reset") { reminderPendingReset = reminder }
        }
        Button("knittingReminder.action.delete", role: .destructive) {
            reminderPendingDeletion = reminder
        }
    }

    private func apply(_ action: KnittingReminderAction, to reminder: KnittingReminder) {
        do {
            try store.applyKnittingReminderAction(
                projectID: projectID,
                reminderID: reminder.id,
                occurrenceID: nil,
                observedRevision: reminder.mutationRevision,
                action: action
            )
        } catch {
            errorMessage = KnittingReminderSummary.error(error, locale: locale)
        }
    }

    private func delete(_ reminder: KnittingReminder) {
        do {
            try store.deleteKnittingReminder(
                projectID: projectID,
                reminderID: reminder.id,
                observedRevision: reminder.mutationRevision
            )
        } catch {
            errorMessage = KnittingReminderSummary.error(error, locale: locale)
        }
    }
}
