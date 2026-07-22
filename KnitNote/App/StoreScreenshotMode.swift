import Foundation

struct StoreScreenshotMode: Equatable {
    let scene: StoreScreenshotScene
    let language: StoreScreenshotLanguage
    let baseDirectory: URL
    let readinessToken: String

    var locale: Locale {
        Locale(identifier: language == .zhHant ? "zh-Hant" : "en")
    }

    static func resolve(processInfo: ProcessInfo = .processInfo) -> StoreScreenshotResolution {
#if DEBUG
        let arguments = processInfo.arguments
        guard argumentValue(after: "-storeScreenshotMode", in: arguments) == "YES" else {
            return .notRequested
        }
        guard let sceneValue = argumentValue(after: "-storeScreenshotScene", in: arguments),
              let scene = StoreScreenshotScene(rawValue: sceneValue),
              let languageValue = argumentValue(after: "-storeScreenshotLanguage", in: arguments),
              let language = StoreScreenshotLanguage(rawValue: languageValue),
              let readinessToken = argumentValue(after: "-storeScreenshotToken", in: arguments),
              !readinessToken.isEmpty else {
            return .invalid
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "KnitNoteStoreScreenshots", directoryHint: .isDirectory)
            .appending(path: language.rawValue, directoryHint: .isDirectory)
        do {
            if FileManager.default.fileExists(atPath: baseDirectory.path) {
                try FileManager.default.removeItem(at: baseDirectory)
            }
            try StoreScreenshotFixtures.make(language: language).install(in: baseDirectory)
            return .ready(StoreScreenshotMode(
                scene: scene,
                language: language,
                baseDirectory: baseDirectory,
                readinessToken: readinessToken
            ))
        } catch {
            return .invalid
        }
#else
        return .notRequested
#endif
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum StoreScreenshotResolution: Equatable {
    case notRequested
    case ready(StoreScreenshotMode)
    case invalid
}
