import SwiftUI

struct KnittingReminderQueueCard: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    @EnvironmentObject private var presentationStore: KnittingReminderPresentationStore
    let projectID: UUID
    let project: StoredProject
    let lease: KnittingReminderPresentationLease
    let isActuallyVisible: Bool

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

                        Text(verbatim: queueCopy(for: current))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(verbatim: targetCopy(for: current))
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
                                Text(verbatim: cardCopy("knittingReminder.card.stop"))
                            }
                            .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.stop.hint")))
                        } label: {
                            Label {
                                Text(verbatim: cardCopy("knittingReminder.card.more"))
                            } icon: {
                                Image(systemName: "ellipsis.circle")
                            }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.more")))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: accessibilitySummary(for: current)))
                .sensoryFeedback(.impact(weight: .light), trigger: hapticOccurrenceID)
                .confirmationDialog(
                    Text(verbatim: cardCopy("knittingReminder.card.stop.confirm")),
                    isPresented: $showingStopConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(role: .destructive) {
                        apply(.stop, current: current)
                    } label: {
                        Text(verbatim: cardCopy("knittingReminder.card.stop"))
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                    } label: {
                        Text(verbatim: cardCopy("common.cancel"))
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .alert(
                    Text(verbatim: cardCopy("error.saveFailed")),
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button {
                    } label: {
                        Text(verbatim: cardCopy("common.ok"))
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
        .onChange(of: isActuallyVisible) { _, visible in
            if visible {
                refresh(project)
            } else {
                current = nil
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for current: KnittingReminderPresentation) -> some View {
        Button {
            apply(.complete, current: current)
        } label: {
            Text(verbatim: cardCopy("knittingReminder.card.complete"))
        }
        .buttonStyle(.borderedProminent)
#if os(macOS)
        .keyboardShortcut(.defaultAction)
#endif
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.complete")))
        .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.complete.hint")))

        if current.phase == .initial {
            Button {
                apply(.deferOnce, current: current)
            } label: {
                Text(verbatim: cardCopy("knittingReminder.card.defer"))
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.defer")))
            .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.defer.hint")))
        } else {
            Button {
                apply(.skip, current: current)
            } label: {
                Text(verbatim: cardCopy("knittingReminder.card.skip"))
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(verbatim: cardCopy("knittingReminder.card.skip")))
            .accessibilityHint(Text(verbatim: cardCopy("knittingReminder.card.skip.hint")))
        }
    }

    private func refresh(_ project: StoredProject) {
        guard isActuallyVisible,
              presentationStore.isCurrent(lease) else {
            current = nil
            return
        }
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
            errorMessage = KnittingReminderSummary.error(error, locale: locale)
            if let authoritativeProject = store.project(id: projectID) {
                refresh(authoritativeProject)
            }
        }
    }

    private func queueCopy(for current: KnittingReminderPresentation) -> String {
        LocaleAwareText.format(
            "knittingReminder.card.queue",
            locale: locale,
            current.currentIndex,
            current.totalCount
        )
    }

    private func targetCopy(for current: KnittingReminderPresentation) -> String {
        LocaleAwareText.format(
            "knittingReminder.card.target",
            locale: locale,
            current.occurrence.originalTarget
        )
    }

    private func accessibilitySummary(for current: KnittingReminderPresentation) -> String {
        let phase = current.phase == .initial
            ? LocaleAwareText.string("knittingReminder.card.phase.initial", locale: locale)
            : LocaleAwareText.string("knittingReminder.card.phase.deferred", locale: locale)
        return LocaleAwareText.format(
            "knittingReminder.card.accessibility.summary",
            locale: locale,
            KnittingReminderSummary.kind(current.occurrence.kind, locale: locale),
            current.occurrence.text ?? "",
            targetCopy(for: current),
            phase,
            queueCopy(for: current)
        )
    }

    private func cardCopy(_ key: String) -> String {
        LocaleAwareText.string(key, locale: locale)
    }
}
