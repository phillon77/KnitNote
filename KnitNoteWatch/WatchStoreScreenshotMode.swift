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
#if DEBUG
        let arguments = processInfo.arguments
        guard value(after: "-storeScreenshotMode", in: arguments) == "YES" else {
            return .notRequested
        }
        guard let sceneValue = value(after: "-storeScreenshotScene", in: arguments),
              let scene = WatchStoreScreenshotScene(rawValue: sceneValue),
              let language = value(after: "-storeScreenshotLanguage", in: arguments),
              ["zh-Hant", "en"].contains(language),
              let readinessToken = value(after: "-storeScreenshotToken", in: arguments),
              !readinessToken.isEmpty else {
            return .invalid
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "KnitNoteWatchStoreScreenshots", directoryHint: .isDirectory)
            .appending(path: language, directoryHint: .isDirectory)
        do {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            let fixture = try makeFixture(language: language)
            try AtomicWatchSyncFile<WatchSyncCache>(url: WatchSyncPaths.watchCache(in: root))
                .save(fixture.cache)
            return .ready(WatchStoreScreenshotMode(
                scene: scene,
                locale: Locale(identifier: language == "zh-Hant" ? "zh-Hant" : "en"),
                baseDirectory: root,
                projectID: fixture.projectID,
                readinessToken: readinessToken
            ))
        } catch {
            return .invalid
        }
#else
        return .notRequested
#endif
    }

    private static func makeFixture(language: String) throws -> (cache: WatchSyncCache, projectID: UUID) {
        let projectID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let counterNames = language == "zh-Hant"
            ? ["排數", "花樣重複", "袖窿", "領口", "左袖", "右袖"]
            : ["Rows", "Pattern Repeat", "Armhole", "Neckline", "Left Sleeve", "Right Sleeve"]
        let counters = zip(counterNames, [48, 6, 12, 4, 18, 18]).enumerated().map { index, item in
            WatchCounterSnapshot(
                id: UUID(uuidString: String(format: "30000000-0000-4000-8000-%012d", index + 1))!,
                name: item.0,
                value: item.1
            )
        }
        let project = try WatchProjectSnapshot(
            id: projectID,
            name: language == "zh-Hant" ? "雲朵披肩" : "Cloud Shawl",
            isCompleted: false,
            updatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            counters: counters,
            selectedCounterID: counters[0].id
        )
        let snapshot = WatchSyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_767_225_600),
            projects: [project]
        )
        return (
            WatchSyncCache(
                snapshot: snapshot,
                pendingCommands: [],
                selectedProjectID: projectID,
                selectedCounterID: counters[0].id
            ),
            projectID
        )
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

    var body: some View {
        WatchCounterView(
            coordinator: coordinator,
            initialProjectID: mode.scene == .watchCounters ? mode.projectID : nil
        )
        .environment(\.locale, mode.locale)
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("storeScreenshot.ready")
        }
        .task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            Logger(subsystem: "com.phillon.KnitNote.watch", category: "StoreScreenshots")
                .notice("storeScreenshot.ready.\(mode.readinessToken, privacy: .public)")
        }
    }
}
