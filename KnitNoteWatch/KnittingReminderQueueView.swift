import SwiftUI

struct KnittingReminderQueueView: View {
    let project: WatchProjectSnapshot
    @ObservedObject var coordinator: WatchSyncCoordinator

    private var queue: [WatchKnittingReminderOccurrenceSnapshot] { project.reminderQueue }

    var body: some View {
        if let occurrence = queue.first,
           let reminder = project.knittingReminders.first(where: { $0.id == occurrence.reminderID }),
           let currentIndex = queue.firstIndex(where: { $0.id == occurrence.id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: kindName(for: occurrence.kind))
                    .font(.headline)
                if let text = occurrence.text, !text.isEmpty {
                    Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "Row \(occurrence.originalTarget)")
                    .font(.caption)
                Text(verbatim: queuePosition(currentIndex: currentIndex + 1, totalCount: queue.count, phase: occurrence.phase))
                    .font(.caption2)
                actions(occurrence: occurrence, reminder: reminder)
            }
            .foregroundStyle(WatchWatercolorTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WatchWatercolorTheme.softWhite.opacity(0.96), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WatchWatercolorTheme.berry.opacity(0.65), lineWidth: 1) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: "\(kindName(for: occurrence.kind)), \(occurrence.text ?? ""), row \(occurrence.originalTarget), \(queuePosition(currentIndex: currentIndex + 1, totalCount: queue.count, phase: occurrence.phase))"))
        }
    }

    @ViewBuilder private func actions(occurrence: WatchKnittingReminderOccurrenceSnapshot, reminder: WatchKnittingReminderSnapshot) -> some View {
        let isPending = coordinator.hasPending(projectID: project.id, counterID: reminder.counterID)
        Button("Complete") { coordinator.completeReminder(projectID: project.id, counterID: reminder.counterID, reminderID: occurrence.reminderID, occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision) }
            .frame(minHeight: 44).disabled(isPending || project.isCompleted || !coordinator.canMutate())
            .accessibilityHint(Text(verbatim: "Completes this reminder."))
        switch occurrence.phase {
        case .initial:
            Button("Remind Next Row") { coordinator.deferReminderOnce(projectID: project.id, counterID: reminder.counterID, reminderID: occurrence.reminderID, occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision) }
                .frame(minHeight: 44).disabled(isPending || project.isCompleted || !coordinator.canMutate())
                .accessibilityHint(Text(verbatim: "Shows this reminder on the next row."))
        case .deferredOnce:
            Button("Skip This Time", role: .destructive) { coordinator.skipReminder(projectID: project.id, counterID: reminder.counterID, reminderID: occurrence.reminderID, occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision) }
                .frame(minHeight: 44).disabled(isPending || project.isCompleted || !coordinator.canMutate())
                .accessibilityHint(Text(verbatim: "Skips only this occurrence."))
        }
    }

    private func queuePosition(currentIndex: Int, totalCount: Int, phase: KnittingReminderOccurrencePhase) -> String {
        "\(phase == .initial ? "Initial" : "Deferred"), \(currentIndex) of \(totalCount)"
    }

    private func kindName(for kind: KnittingReminderKind) -> String {
        switch kind { case .increase: "Increase"; case .decrease: "Decrease"; case .changeYarn: "Change Yarn"; case .cable: "Cable"; case .buttonhole: "Buttonhole"; case .measure: "Measure"; case .custom: "Custom Reminder" }
    }
}
