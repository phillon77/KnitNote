import SwiftUI

struct ProjectCountersView: View {
    let projectID: UUID
    @ObservedObject var coordinator: WatchSyncCoordinator
    @State private var actionCounterID: UUID?

    private var project: WatchProjectSnapshot? {
        coordinator.snapshot?.projects.first { $0.id == projectID }
    }

    var body: some View {
        ZStack {
            WatchWatercolorBackground()

            if let project {
                counterList(for: project)
                    .confirmationDialog(
                        "watch.counter.actions",
                        isPresented: actionDialogIsPresented,
                        titleVisibility: .visible
                    ) {
                        if let counterID = actionCounterID {
                            Button("watch.counter.decrement") {
                                coordinator.decrement(projectID: project.id, counterID: counterID)
                                actionCounterID = nil
                            }
                            Button("watch.counter.reset", role: .destructive) {
                                coordinator.reset(projectID: project.id, counterID: counterID)
                                actionCounterID = nil
                            }
                        }
                        Button("watch.counter.cancel", role: .cancel) {
                            actionCounterID = nil
                        }
                    }
            } else {
                Text("watch.sync.error.projectMissing")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(WatchWatercolorTheme.ink)
                    .padding()
            }
        }
        .navigationTitle(project?.name ?? "")
        .onAppear {
            coordinator.selectProject(projectID)
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
    }

    private func counterRow(
        _ counter: WatchCounterSnapshot,
        in project: WatchProjectSnapshot
    ) -> some View {
        let isPending = coordinator.hasPending(projectID: project.id, counterID: counter.id)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(counter.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard !project.isCompleted else { return }
            coordinator.selectCounter(counter.id)
            coordinator.increment(projectID: project.id, counterID: counter.id)
        }
        .onLongPressGesture(minimumDuration: 0.55) {
            guard !project.isCompleted else { return }
            coordinator.selectCounter(counter.id)
            actionCounterID = counter.id
        }
        .disabled(project.isCompleted)
        .opacity(project.isCompleted ? 0.72 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(project.name), \(counter.name), \(counter.value)"))
        .accessibilityHint(
            project.isCompleted
                ? Text("watch.sync.error.projectCompleted")
                : Text("watch.counter.incrementHint")
        )
        .accessibilityAction(named: Text("watch.counter.incrementHint")) {
            guard !project.isCompleted else { return }
            coordinator.selectCounter(counter.id)
            coordinator.increment(projectID: project.id, counterID: counter.id)
        }
        .accessibilityAction(named: Text("watch.counter.decrement")) {
            guard !project.isCompleted else { return }
            coordinator.selectCounter(counter.id)
            coordinator.decrement(projectID: project.id, counterID: counter.id)
        }
        .accessibilityAction(named: Text("watch.counter.reset")) {
            guard !project.isCompleted else { return }
            coordinator.selectCounter(counter.id)
            coordinator.reset(projectID: project.id, counterID: counter.id)
        }
    }

    private var actionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { actionCounterID != nil },
            set: { if !$0 { actionCounterID = nil } }
        )
    }
}
