import SwiftUI

struct KnittingReminderQueueView: View {
    @Environment(\.locale) private var locale
    let project: WatchProjectSnapshot
    @ObservedObject var coordinator: WatchSyncCoordinator

    private var queue: [WatchKnittingReminderOccurrenceSnapshot] { project.reminderQueue }

    var body: some View {
        if let occurrence = queue.first,
           let reminder = project.knittingReminders.first(where: { $0.id == occurrence.reminderID }),
           let currentIndex = queue.firstIndex(where: { $0.id == occurrence.id }) {
            VStack(alignment: .leading, spacing: 8) {
                summary(occurrence: occurrence, currentIndex: currentIndex + 1, totalCount: queue.count)
                actions(occurrence: occurrence, reminder: reminder)
            }
            .foregroundStyle(WatchWatercolorTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WatchWatercolorTheme.softWhite.opacity(0.96), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WatchWatercolorTheme.berry.opacity(0.65), lineWidth: 1) }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func summary(occurrence: WatchKnittingReminderOccurrenceSnapshot, currentIndex: Int, totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: kindName(for: occurrence.kind)).font(.headline)
            if let text = occurrence.text, !text.isEmpty {
                Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: targetCopy(occurrence.originalTarget)).font(.caption)
            Text(verbatim: phaseCopy(occurrence.phase)).font(.caption2)
            Text(verbatim: queuePosition(currentIndex: currentIndex, totalCount: totalCount)).font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilitySummary(occurrence: occurrence, currentIndex: currentIndex, totalCount: totalCount)))
    }

    @ViewBuilder private func actions(occurrence: WatchKnittingReminderOccurrenceSnapshot, reminder: WatchKnittingReminderSnapshot) -> some View {
        let isPending = coordinator.hasPending(projectID: project.id, counterID: reminder.counterID)
        Button {
            coordinator.completeReminder(projectID: project.id, counterID: reminder.counterID, reminderID: occurrence.reminderID, occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision)
        } label: {
            Text(verbatim: copy("watch.reminder.action.complete"))
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isPending || project.isCompleted || !coordinator.canMutate())
        .accessibilityLabel(Text(verbatim: copy("watch.reminder.action.complete")))
        .accessibilityHint(Text(verbatim: copy("watch.reminder.action.complete.hint")))

        switch occurrence.phase {
        case .initial:
            Button {
                coordinator.deferReminderOnce(projectID: project.id, counterID: reminder.counterID, reminderID: occurrence.reminderID, occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision)
            } label: {
                Text(verbatim: copy("watch.reminder.action.defer"))
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(isPending || project.isCompleted || !coordinator.canMutate())
            .accessibilityLabel(Text(verbatim: copy("watch.reminder.action.defer")))
            .accessibilityHint(Text(verbatim: copy("watch.reminder.action.defer.hint")))
        case .deferredOnce:
            Button(role: .destructive) {
                coordinator.skipReminder(projectID: project.id, counterID: reminder.counterID, reminderID: occurrence.reminderID, occurrenceID: occurrence.id, observedRevision: reminder.mutationRevision)
            } label: {
                Text(verbatim: copy("watch.reminder.action.skip"))
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(isPending || project.isCompleted || !coordinator.canMutate())
            .accessibilityLabel(Text(verbatim: copy("watch.reminder.action.skip")))
            .accessibilityHint(Text(verbatim: copy("watch.reminder.action.skip.hint")))
        }
    }

    private func queuePosition(currentIndex: Int, totalCount: Int) -> String {
        LocaleAwareText.format("watch.reminder.queuePosition", locale: locale, currentIndex, totalCount)
    }

    private func targetCopy(_ target: Int) -> String {
        LocaleAwareText.format("watch.reminder.target", locale: locale, target)
    }

    private func phaseCopy(_ phase: KnittingReminderOccurrencePhase) -> String {
        copy(phase == .initial ? "watch.reminder.phase.initial" : "watch.reminder.phase.deferred")
    }

    private func accessibilitySummary(occurrence: WatchKnittingReminderOccurrenceSnapshot, currentIndex: Int, totalCount: Int) -> String {
        LocaleAwareText.format(
            "watch.reminder.accessibility.summary",
            locale: locale,
            kindName(for: occurrence.kind),
            occurrence.text ?? "",
            targetCopy(occurrence.originalTarget),
            phaseCopy(occurrence.phase),
            queuePosition(currentIndex: currentIndex, totalCount: totalCount)
        )
    }

    private func kindName(for kind: KnittingReminderKind) -> String {
        let key: String
        switch kind {
        case .increase: key = "watch.reminder.kind.increase"
        case .decrease: key = "watch.reminder.kind.decrease"
        case .changeYarn: key = "watch.reminder.kind.changeYarn"
        case .cable: key = "watch.reminder.kind.cable"
        case .buttonhole: key = "watch.reminder.kind.buttonhole"
        case .measure: key = "watch.reminder.kind.measure"
        case .custom: key = "watch.reminder.kind.custom"
        }
        return copy(key)
    }

    private func copy(_ key: String) -> String {
        LocaleAwareText.string(key, locale: locale)
    }
}
