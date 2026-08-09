import SwiftUI

struct CounterReminderCard: View {
    @Environment(\.locale) private var locale
    let pending: CounterReminderPending
    let message: String?
    let onComplete: () -> Void
    let onStop: () -> Void

    var body: some View {
        WatercolorCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("counter.reminder.reached", systemImage: "bell.fill")
                    .font(.headline)

                if let message, !message.isEmpty {
                    Text(verbatim: message)
                }

                Text(pendingCopy)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { reminderActions }
                    VStack(spacing: 8) { reminderActions }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var reminderActions: some View {
        Button("counter.reminder.complete", action: onComplete)
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        Button("counter.reminder.stop", role: .destructive, action: onStop)
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
    }

    private var pendingCopy: String {
        if pending.occurrenceCount == 1 {
            return localizedCopy(key: "counter.reminder.reached", value: pending.lastTarget)
        }
        let reachedCopy = localizedCopy(key: "counter.reminder.reached", value: pending.lastTarget)
        let crossedCountCopy = localizedCopy(
            key: "counter.reminder.crossedCount",
            value: pending.occurrenceCount
        )
        return "\(reachedCopy) · \(crossedCountCopy)"
    }

    private func localizedCopy(key: String, value: Int) -> String {
        let format = LocaleAwareText.string(key, locale: locale)
        guard format.contains("%") else {
            return "\(format) \(value.formatted(.number.locale(locale)))"
        }
        return String(format: format, locale: locale, value)
    }
}
