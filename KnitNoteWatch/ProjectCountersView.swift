import SwiftUI

struct ProjectCountersView: View {
    let projectID: UUID
    @ObservedObject var coordinator: WatchSyncCoordinator
    let onStoreScreenshotReady: @MainActor @Sendable () -> Void
    @State private var actionCounterID: UUID?

    private var project: WatchProjectSnapshot? {
        coordinator.snapshot?.projects.first { $0.id == projectID }
    }

    private var actionableCounterID: UUID? {
        guard let actionCounterID,
              let project,
              !project.isCompleted,
              project.counters.contains(where: { $0.id == actionCounterID })
        else { return nil }
        return actionCounterID
    }

    var body: some View {
        ZStack {
            WatchWatercolorBackground()

            if let project {
                counterList(for: project)
            } else {
                Text("watch.sync.error.projectMissing")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(WatchWatercolorTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
            }
        }
        .confirmationDialog(
            "watch.counter.actions",
            isPresented: actionDialogIsPresented,
            titleVisibility: .visible
        ) {
            if let counterID = actionableCounterID {
                Button("watch.counter.decrement") {
                    perform(.decrement, counterID: counterID)
                }
                Button("watch.counter.reset", role: .destructive) {
                    perform(.reset, counterID: counterID)
                }
            }
            Button("watch.counter.cancel", role: .cancel) {
                actionCounterID = nil
            }
        }
        .navigationTitle(project?.name ?? "")
        .onAppear {
            coordinator.selectProject(projectID)
        }
        .onChange(of: coordinator.snapshot) { _, _ in
            dismissInvalidActionIfNeeded()
        }
    }

    private func counterList(for project: WatchProjectSnapshot) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(project.counters) { counter in
                    counterRow(counter, in: project)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .onAppear {
            onStoreScreenshotReady()
        }
    }

    @ViewBuilder
    private func counterRow(
        _ counter: WatchCounterSnapshot,
        in project: WatchProjectSnapshot
    ) -> some View {
        let isPending = coordinator.hasPending(projectID: project.id, counterID: counter.id)
        let row = counterRowContent(counter, in: project, isPending: isPending)
            .disabled(project.isCompleted)
            .opacity(project.isCompleted ? 0.72 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(project.name), \(counter.name), \(counter.value)"))
            .accessibilityValue(counterAccessibilityValue(
                counter: counter,
                project: project,
                isPending: isPending
            ))

        if project.isCompleted {
            row.accessibilityHint(Text("watch.sync.error.projectCompleted"))
        } else {
            activeCounterRow(row, counter: counter)
        }
    }

    private func counterRowContent(
        _ counter: WatchCounterSnapshot,
        in project: WatchProjectSnapshot,
        isPending: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(counter.name)
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(counter.value, format: .number)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            if isPending || project.isCompleted {
                HStack(spacing: 8) {
                    if isPending {
                        Label {
                            Text("watch.sync.pending")
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    if project.isCompleted {
                        Label {
                            Text("watch.project.completed")
                        } icon: {
                            Image(systemName: "lock.fill")
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(WatchWatercolorTheme.berry)
            }
        }
        .foregroundStyle(WatchWatercolorTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            WatchWatercolorTheme.softWhite.opacity(0.92),
            in: .rect(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(WatchWatercolorTheme.lavender.opacity(0.5), lineWidth: 1)
        }
    }

    private func activeCounterRow<Row: View>(
        _ row: Row,
        counter: WatchCounterSnapshot
    ) -> some View {
        row
            .contentShape(Rectangle())
            .onTapGesture {
                perform(.increment, counterID: counter.id)
            }
            .onLongPressGesture(minimumDuration: 0.55) {
                presentActionsIfAvailable(counterID: counter.id)
            }
            .accessibilityHint(Text("watch.counter.incrementHint"))
            .accessibilityAction(named: Text("watch.counter.incrementHint")) {
                perform(.increment, counterID: counter.id)
            }
            .accessibilityAction(named: Text("watch.counter.decrement")) {
                perform(.decrement, counterID: counter.id)
            }
            .accessibilityAction(named: Text("watch.counter.reset")) {
                perform(.reset, counterID: counter.id)
            }
    }

    private func counterAccessibilityValue(
        counter: WatchCounterSnapshot,
        project: WatchProjectSnapshot,
        isPending: Bool
    ) -> Text {
        var value = Text(counter.value, format: .number)
        if isPending {
            value = value + Text(verbatim: ", ") + Text("watch.sync.pending")
        }
        if project.isCompleted {
            value = value + Text(verbatim: ", ") + Text("watch.project.completed")
        }
        return value
    }

    private func currentActiveProject(containing counterID: UUID) -> WatchProjectSnapshot? {
        guard let project,
              !project.isCompleted,
              project.counters.contains(where: { $0.id == counterID })
        else { return nil }
        return project
    }

    private func presentActionsIfAvailable(counterID: UUID) {
        guard let project = currentActiveProject(containing: counterID) else { return }
        coordinator.selectProject(project.id)
        coordinator.selectCounter(counterID)
        actionCounterID = counterID
    }

    private func perform(_ operation: WatchCounterOperation, counterID: UUID) {
        guard let project = currentActiveProject(containing: counterID) else {
            actionCounterID = nil
            return
        }

        coordinator.selectProject(project.id)
        coordinator.selectCounter(counterID)
        switch operation {
        case .increment:
            coordinator.increment(projectID: project.id, counterID: counterID)
        case .decrement:
            coordinator.decrement(projectID: project.id, counterID: counterID)
        case .reset:
            coordinator.reset(projectID: project.id, counterID: counterID)
        }
        actionCounterID = nil
    }

    private func dismissInvalidActionIfNeeded() {
        guard actionCounterID != nil, actionableCounterID == nil else { return }
        actionCounterID = nil
    }

    private var actionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { actionableCounterID != nil },
            set: { if !$0 { actionCounterID = nil } }
        )
    }
}
