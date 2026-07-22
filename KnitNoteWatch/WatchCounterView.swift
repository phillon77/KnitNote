import SwiftUI

private extension Color {
    init(watchTheme value: ThemeRGB) {
        let red = Double((value.hex >> 16) & 0xFF) / 255
        let green = Double((value.hex >> 8) & 0xFF) / 255
        let blue = Double(value.hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue)
    }
}

enum WatchWatercolorTheme {
    static let sky = Color(watchTheme: WatercolorPalette.sky)
    static let lavender = Color(watchTheme: WatercolorPalette.lavender)
    static let berry = Color(watchTheme: WatercolorPalette.actionBerry)
    static let softWhite = Color(watchTheme: WatercolorPalette.softWhite)
    static let ink = Color(watchTheme: WatercolorPalette.ink)
    static let background = Color(watchTheme: WatercolorPalette.background)
}

struct WatchCounterView: View {
    @ObservedObject var coordinator: WatchSyncCoordinator
    @State private var path: [UUID]

    init(coordinator: WatchSyncCoordinator, initialProjectID: UUID? = nil) {
        self.coordinator = coordinator
        _path = State(initialValue: initialProjectID.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ProjectListView(coordinator: coordinator)
                .navigationDestination(for: UUID.self) { projectID in
                    ProjectCountersView(projectID: projectID, coordinator: coordinator)
                }
        }
        .safeAreaInset(edge: .top, spacing: 3) {
            if let errorReason = coordinator.localizedErrorReason {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(verbatim: errorReason)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(WatchWatercolorTheme.berry, in: .rect(cornerRadius: 9))
                .accessibilityElement(children: .combine)
            }
        }
        .tint(WatchWatercolorTheme.berry)
    }
}

struct WatchWatercolorBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                WatchWatercolorTheme.sky.opacity(0.35),
                WatchWatercolorTheme.background,
                WatchWatercolorTheme.lavender.opacity(0.24),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
