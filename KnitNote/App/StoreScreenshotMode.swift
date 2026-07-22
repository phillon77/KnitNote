import Foundation

struct StoreScreenshotMode: Equatable {
    let scene: StoreScreenshotScene
    let language: StoreScreenshotLanguage
    let baseDirectory: URL

    var locale: Locale {
        Locale(identifier: language == .zhHant ? "zh-Hant" : "en")
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> StoreScreenshotMode? {
#if DEBUG
        let arguments = processInfo.arguments
        guard argumentValue(after: "-storeScreenshotMode", in: arguments) == "YES",
              let sceneValue = argumentValue(after: "-storeScreenshotScene", in: arguments),
              let scene = StoreScreenshotScene(rawValue: sceneValue),
              let languageValue = argumentValue(after: "-storeScreenshotLanguage", in: arguments),
              let language = StoreScreenshotLanguage(rawValue: languageValue) else {
            return nil
        }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "KnitNoteStoreScreenshots", directoryHint: .isDirectory)
            .appending(path: language.rawValue, directoryHint: .isDirectory)
        do {
            try? FileManager.default.removeItem(at: baseDirectory)
            try StoreScreenshotFixtures.make(language: language).install(in: baseDirectory)
            return StoreScreenshotMode(
                scene: scene,
                language: language,
                baseDirectory: baseDirectory
            )
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    private static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
