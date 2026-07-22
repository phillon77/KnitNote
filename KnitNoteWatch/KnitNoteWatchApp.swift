import SwiftUI

@main
struct KnitNoteWatchApp: App {
    @StateObject private var watchSyncCoordinator: WatchSyncCoordinator
    private let screenshotMode: WatchStoreScreenshotMode?

    init() {
        let screenshotMode: WatchStoreScreenshotMode?
        switch WatchStoreScreenshotMode.resolve() {
        case .notRequested:
            screenshotMode = nil
        case let .ready(mode):
            screenshotMode = mode
        case .invalid:
            preconditionFailure("Invalid Watch screenshot request; refusing to open the live cache")
        }
        self.screenshotMode = screenshotMode
        let watchSyncCoordinator = WatchSyncCoordinator(
            applicationSupportRoot: screenshotMode?.baseDirectory
        )
        _watchSyncCoordinator = StateObject(wrappedValue: watchSyncCoordinator)
        if screenshotMode == nil {
            watchSyncCoordinator.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            if let screenshotMode {
                WatchStoreScreenshotHost(
                    mode: screenshotMode,
                    coordinator: watchSyncCoordinator
                )
            } else {
                WatchCounterView(coordinator: watchSyncCoordinator)
            }
        }
    }
}
