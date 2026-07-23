import SwiftUI

struct ProjectListView: View {
    @ObservedObject var coordinator: WatchSyncCoordinator
    let onStoreScreenshotReady: @MainActor @Sendable () -> Void

    private var projects: [WatchProjectSnapshot] {
        coordinator.snapshot?.projects ?? []
    }

    var body: some View {
        ZStack {
            WatchWatercolorBackground()

            if projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .font(.title2)
                    Text("watch.projects.empty")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(WatchWatercolorTheme.ink)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(projects) { project in
                            NavigationLink(value: project.id) {
                                projectRow(project)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    coordinator.selectProject(project.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
                .onAppear {
                    onStoreScreenshotReady()
                }
            }
        }
        .navigationTitle("watch.projects.title")
    }

    private func projectRow(_ project: WatchProjectSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if project.isCompleted {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                        Text("watch.project.completed")
                    }
                    .font(.caption2)
                    .foregroundStyle(WatchWatercolorTheme.berry)
                }
            }

            Spacer(minLength: 2)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(WatchWatercolorTheme.berry)
                .accessibilityHidden(true)
        }
        .foregroundStyle(WatchWatercolorTheme.ink)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            WatchWatercolorTheme.softWhite.opacity(0.91),
            in: .rect(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(WatchWatercolorTheme.lavender.opacity(0.48), lineWidth: 1)
        }
    }
}
