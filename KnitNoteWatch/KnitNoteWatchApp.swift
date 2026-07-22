import SwiftUI

@main
struct KnitNoteWatchApp: App {
    @StateObject private var watchSyncCoordinator: WatchSyncCoordinator
    private let screenshotMode: WatchStoreScreenshotMode?

    init() {
        let screenshotMode = WatchStoreScreenshotMode.current()
        self.screenshotMode = screenshotMode
        let watchSyncCoordinator = WatchSyncCoordinator()
        _watchSyncCoordinator = StateObject(wrappedValue: watchSyncCoordinator)
        if screenshotMode == nil {
            watchSyncCoordinator.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            if let screenshotMode {
                WatchStoreScreenshotRootView(scene: screenshotMode.scene)
                    .environment(\.locale, screenshotMode.locale)
            } else {
                WatchCounterView(coordinator: watchSyncCoordinator)
            }
        }
    }
}
