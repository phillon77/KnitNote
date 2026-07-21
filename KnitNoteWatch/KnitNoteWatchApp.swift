import SwiftUI

@main
struct KnitNoteWatchApp: App {
    @StateObject private var watchSyncCoordinator: WatchSyncCoordinator

    init() {
        let watchSyncCoordinator = WatchSyncCoordinator()
        _watchSyncCoordinator = StateObject(wrappedValue: watchSyncCoordinator)
        watchSyncCoordinator.start()
    }

    var body: some Scene {
        WindowGroup { WatchCounterView(coordinator: watchSyncCoordinator) }
    }
}
