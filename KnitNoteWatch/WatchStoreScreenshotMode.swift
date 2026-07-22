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

    static func current(processInfo: ProcessInfo = .processInfo) -> WatchStoreScreenshotMode? {
#if DEBUG
        let arguments = processInfo.arguments
        guard value(after: "-storeScreenshotMode", in: arguments) == "YES",
              let sceneValue = value(after: "-storeScreenshotScene", in: arguments),
              let scene = WatchStoreScreenshotScene(rawValue: sceneValue),
              let language = value(after: "-storeScreenshotLanguage", in: arguments),
              ["zh-Hant", "en"].contains(language) else {
            return nil
        }
        return WatchStoreScreenshotMode(
            scene: scene,
            locale: Locale(identifier: language == "zh-Hant" ? "zh-Hant" : "en")
        )
#else
        return nil
#endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

struct WatchStoreScreenshotRootView: View {
    let scene: WatchStoreScreenshotScene

    private let counters = [
        ("排數", "Rows", 48),
        ("花樣重複", "Pattern Repeat", 6),
        ("袖窿", "Armhole", 12),
        ("領口", "Neckline", 4),
        ("左袖", "Left Sleeve", 18),
        ("右袖", "Right Sleeve", 18),
    ]

    @Environment(\.locale) private var locale

    private var isChinese: Bool { locale.identifier.hasPrefix("zh") }

    var body: some View {
        ZStack {
            WatchWatercolorBackground()
            switch scene {
            case .watchProjects:
                projectList
            case .watchCounters:
                counterList
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("storeScreenshot.ready")
        }
        .onAppear {
            Logger(subsystem: "com.phillon.KnitNote.watch", category: "StoreScreenshots")
                .notice("storeScreenshot.ready")
        }
        .tint(WatchWatercolorTheme.berry)
    }

    private var projectList: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    projectRow(isChinese ? "雲朵披肩" : "Cloud Shawl", detail: isChinese ? "編織中" : "In progress")
                    projectRow(isChinese ? "莓果帽" : "Berry Hat", detail: isChinese ? "編織中" : "In progress")
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle(isChinese ? "作品" : "Projects")
        }
    }

    private func projectRow(_ name: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(detail).font(.caption2).foregroundStyle(WatchWatercolorTheme.berry)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.caption.bold())
        }
        .foregroundStyle(WatchWatercolorTheme.ink)
        .padding(10)
        .background(WatchWatercolorTheme.softWhite.opacity(0.92), in: .rect(cornerRadius: 14))
    }

    private var counterList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(counters.enumerated()), id: \.offset) { _, counter in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(isChinese ? counter.0 : counter.1)
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(counter.2, format: .number)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(WatchWatercolorTheme.ink)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 58)
                    .background(WatchWatercolorTheme.softWhite.opacity(0.92), in: .rect(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
