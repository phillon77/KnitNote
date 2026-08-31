import SwiftUI

struct KnittingReminderQueueCard: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var presentationStore: KnittingReminderPresentationStore
    let projectID: UUID
    let project: StoredProject
    let lease: KnittingReminderPresentationLease

    @State private var current: KnittingReminderPresentation?
    @State private var hapticOccurrenceID: UUID?
    @State private var showingStopConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let current {
                WatercolorCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text(verbatim: KnittingReminderSummary.kind(current.occurrence.kind, locale: locale))
                        } icon: {
                            Image(systemName: "bell.fill")
                        }
                        .font(.headline)

                        if let text = current.occurrence.text, !text.isEmpty {
                            Text(verbatim: text)
                        }

                        Text(queueCopy(for: current))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(targetCopy(for: current))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { actionButtons(for: current) }
                            VStack(spacing: 8) { actionButtons(for: current) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Menu {
                            Button(role: .destructive) {
                                showingStopConfirmation = true
                            } label: {
                                Text(verbatim: cardCopy("knittingReminder.card.stop", fallback: "Stop rule"))
                            }
                            .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.stop.hint", fallback: "Stops this reminder rule.")))
                        } label: {
                            Label {
                                Text(verbatim: cardCopy("knittingReminder.card.more", fallback: "More"))
                            } icon: {
                                Image(systemName: "ellipsis.circle")
                            }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.more", fallback: "More")))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityValue(Text(accessibilityValue(for: current)))
                .sensoryFeedback(.impact(weight: .light), trigger: hapticOccurrenceID)
                .confirmationDialog(
                    Text(verbatim: cardCopy("knittingReminder.card.stop.confirm", fallback: "Stop this reminder rule?")),
                    isPresented: $showingStopConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        apply(.stop, current: current)
                    } label: {
                        Text(verbatim: cardCopy("knittingReminder.card.stop", fallback: "Stop rule"))
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                    } label: {
                        Text(verbatim: cardCopy("common.cancel", fallback: "Cancel"))
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .alert(
                    Text(verbatim: cardCopy("error.saveFailed", fallback: "Could not save")),
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button {
                    } label: {
                        Text(verbatim: cardCopy("common.ok", fallback: "OK"))
                    }
                } message: {
                    Text(verbatim: errorMessage ?? "")
                }
            }
        }
        .onAppear { refresh(project) }
        .onChange(of: project) { _, updatedProject in
            refresh(updatedProject)
        }
    }

    @ViewBuilder
    private func actionButtons(for current: KnittingReminderPresentation) -> some View {
        Button {
            apply(.complete, current: current)
        } label: {
            Text(verbatim: cardCopy("knittingReminder.card.complete", fallback: "Complete"))
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.complete", fallback: "Complete")))
        .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.complete.hint", fallback: "Marks this reminder complete.")))

        if current.phase == .initial {
            Button {
                apply(.deferOnce, current: current)
            } label: {
                Text(verbatim: cardCopy("knittingReminder.card.defer", fallback: "Remind next row"))
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.defer", fallback: "Remind next row")))
            .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.defer.hint", fallback: "Shows this reminder after the next row.")))
        } else {
            Button {
                apply(.skip, current: current)
            } label: {
                Text(verbatim: cardCopy("knittingReminder.card.skip", fallback: "Skip this time"))
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.skip", fallback: "Skip this time")))
            .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.skip.hint", fallback: "Skips this occurrence only.")))
        }
    }

    private func refresh(_ project: StoredProject) {
        current = presentationStore.update(project: project)
        guard let current else { return }
        guard presentationStore.claimHaptic(
            for: current.occurrence,
            projectID: projectID,
            lease: lease
        ) else { return }
        hapticOccurrenceID = current.occurrence.id
    }

    private func apply(
        _ action: KnittingReminderAction,
        current: KnittingReminderPresentation
    ) {
        do {
            let occurrenceID: UUID?
            switch action {
            case .stop, .resetLatest:
                occurrenceID = nil
            case .complete, .deferOnce, .skip:
                occurrenceID = current.occurrence.id
            }
            try store.applyKnittingReminderAction(
                projectID: projectID,
                reminderID: current.occurrence.reminderID,
                occurrenceID: occurrenceID,
                observedRevision: current.reminderRevision,
                action: action
            )
            if let updatedProject = store.project(id: projectID) {
                refresh(updatedProject)
            }
        } catch {
            errorMessage = error.localizedDescription
            if let authoritativeProject = store.project(id: projectID) {
                refresh(authoritativeProject)
            }
        }
    }

    private func queueCopy(for current: KnittingReminderPresentation) -> String {
        let position = current.currentIndex.formatted(.number.locale(locale))
        let total = current.totalCount.formatted(.number.locale(locale))
        let prefix = LocaleAwareText.string("knittingReminder.card.queue", locale: locale)
        return prefix == "knittingReminder.card.queue"
            ? "\(position) / \(total)"
            : "\(prefix) \(position) / \(total)"
    }

    private func targetCopy(for current: KnittingReminderPresentation) -> String {
        let target = current.occurrence.originalTarget.formatted(.number.locale(locale))
        let prefix = LocaleAwareText.string("knittingReminder.card.target", locale: locale)
        return prefix == "knittingReminder.card.target"
            ? "Row \(target)"
            : "\(prefix) \(target)"
    }

    private func accessibilityValue(for current: KnittingReminderPresentation) -> String {
        let phase = current.phase == .initial
            ? LocaleAwareText.string("knittingReminder.card.phase.initial", locale: locale)
            : LocaleAwareText.string("knittingReminder.card.phase.deferred", locale: locale)
        return "\(queueCopy(for: current)); \(targetCopy(for: current)); \(phase)"
    }

    private func cardCopy(_ key: String, fallback: String) -> String {
        let copy = LocaleAwareText.string(key, locale: locale)
        return copy == key ? fallback : copy
    }
}
