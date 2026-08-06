import Foundation
import OSLog
import SwiftUI

enum WatchStoreScreenshotScene: String {
    case watchProjects
    case watchCounters
}

struct WatchStoreScreenshotMode {
    let scene: WatchStoreScreenshotScene
    let locale: Locale
    let baseDirectory: URL
    let projectID: UUID
    let readinessToken: String

    static func resolve(processInfo: ProcessInfo = .processInfo) -> WatchStoreScreenshotResolution {
        let arguments = processInfo.arguments
        guard arguments.contains("-storeScreenshotMode") else {
            return .notRequested
        }
        guard value(after: "-storeScreenshotMode", in: arguments) == "YES" else {
            return .invalid
        }
#if DEBUG
        guard let sceneValue = value(after: "-storeScreenshotScene", in: arguments),
              let scene = WatchStoreScreenshotScene(rawValue: sceneValue),
              let languageValue = value(after: "-storeScreenshotLanguage", in: arguments),
              let language = StoreScreenshotLanguage(rawValue: languageValue),
              let readinessToken = value(after: "-storeScreenshotToken", in: arguments),
              !readinessToken.isEmpty else {
            return .invalid
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "KnitNoteWatchStoreScreenshots", directoryHint: .isDirectory)
            .appending(path: language.rawValue, directoryHint: .isDirectory)
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            let fixture = try StoreScreenshotFixtures.makeWatchFixture(language: language)
            try AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: root))
                .save(fixture.cache)
            return .ready(WatchStoreScreenshotMode(
                scene: scene,
                locale: Locale(identifier: language.rawValue),
                baseDirectory: root,
                projectID: fixture.projectID,
                readinessToken: readinessToken
            ))
        } catch {
            return .invalid
        }
#else
        return .invalid
#endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum WatchStoreScreenshotResolution {
    case notRequested
    case ready(WatchStoreScreenshotMode)
    case invalid
}

struct WatchStoreScreenshotHost: View {
    let mode: WatchStoreScreenshotMode
    @ObservedObject var coordinator: WatchSyncCoordinator
    @State private var contentReady = false

    var body: some View {
        WatchCounterView(
            coordinator: coordinator,
            initialProjectID: mode.scene == .watchCounters ? mode.projectID : nil,
            onStoreScreenshotReady: { contentReady = true }
        )
        .environment(\.locale, mode.locale)
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("storeScreenshot.ready")
        }
        .task(id: contentReady) {
            guard contentReady else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            Logger(subsystem: "com.phillon.KnitNote.watch", category: "StoreScreenshots")
                .notice("storeScreenshot.ready.\(mode.readinessToken, privacy: .public)")
        }
    }
}
