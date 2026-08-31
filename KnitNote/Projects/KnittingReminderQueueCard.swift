import SwiftUI

struct KnittingReminderQueueCard: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var store: JSONProjectStore
    let projectID: UUID
    let project: StoredProject

    @State private var coordinator = KnittingReminderPresentationCoordinator()
    @State private var hapticOccurrenceID: UUID?
    @State private var showingStopConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let current = coordinator.current {
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
                            Button("knittingReminder.card.stop", role: .destructive) {
                                showingStopConfirmation = true
                            }
                            .accessibilityHint(Text("knittingReminder.card.stop.hint"))
                        } label: {
                            Label("knittingReminder.card.more", systemImage: "ellipsis.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(Text("knittingReminder.card.more"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
                .accessibilityValue(Text(accessibilityValue(for: current)))
                .sensoryFeedback(.impact(weight: .light), trigger: hapticOccurrenceID)
                .confirmationDialog(
                    "knittingReminder.card.stop.confirm",
                    isPresented: $showingStopConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("knittingReminder.card.stop", role: .destructive) {
                        apply(.stop, current: current)
                    }
                    Button("common.cancel", role: .cancel) {}
                }
                .alert("error.saveFailed", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("common.ok") {}
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
        Button("knittingReminder.card.complete") {
            apply(.complete, current: current)
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text("knittingReminder.card.complete"))
        .accessibilityHint(Text("knittingReminder.card.complete.hint"))

        if current.phase == .initial {
            Button("knittingReminder.card.defer") {
                apply(.deferOnce, current: current)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("knittingReminder.card.defer"))
            .accessibilityHint(Text("knittingReminder.card.defer.hint"))
        } else {
            Button("knittingReminder.card.skip") {
                apply(.skip, current: current)
            }
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("knittingReminder.card.skip"))
            .accessibilityHint(Text("knittingReminder.card.skip.hint"))
        }
    }

    private func refresh(_ project: StoredProject) {
        coordinator.update(project: project)
        guard let current = coordinator.current,
              coordinator.shouldPlayHaptic(for: current.occurrence) else { return }
        coordinator.markHapticPresented(occurrenceID: current.occurrence.id)
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
}
