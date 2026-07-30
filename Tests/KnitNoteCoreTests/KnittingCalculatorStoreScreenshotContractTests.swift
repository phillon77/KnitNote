import Foundation
import Testing

@Suite struct KnittingCalculatorStoreScreenshotContractTests {
    @Test func calculatorScreenshotManifestPinsApprovedBilingualScope() throws {
        let data = try Data(contentsOf: repositoryURL(
            "AppStore/KnittingCalculator/Screenshots/manifest.json"
        ))
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let frames = try #require(payload["frames"] as? [[String: Any]])

        #expect(payload["schemaVersion"] as? Int == 2)
        let matrix = frames.map { frame in
            ["locale", "platform", "scene", "filename"]
                .compactMap { frame[$0] as? String }
                .joined(separator: "|")
        }
        #expect(matrix == [
            "zh-Hant|iphone|home|01-home.png",
            "zh-Hant|iphone|gauge|02-gauge.png",
            "zh-Hant|iphone|adjustment|03-adjustment.png",
            "zh-Hant|iphone|privacy|04-privacy.png",
            "zh-Hant|iphone|promotion|05-knitnote.png",
            "zh-Hant|ipad|home|01-home.png",
            "zh-Hant|ipad|gauge|02-gauge.png",
            "zh-Hant|ipad|adjustment|03-adjustment.png",
            "zh-Hant|ipad|privacyPromotion|04-privacy-knitnote.png",
            "en|iphone|home|01-home.png",
            "en|iphone|gauge|02-gauge.png",
            "en|iphone|adjustment|03-adjustment.png",
            "en|iphone|privacy|04-privacy.png",
            "en|iphone|promotion|05-knitnote.png",
            "en|ipad|home|01-home.png",
            "en|ipad|gauge|02-gauge.png",
            "en|ipad|adjustment|03-adjustment.png",
            "en|ipad|privacyPromotion|04-privacy-knitnote.png",
        ])
    }

    @Test func screenshotManifestUsesSemanticNavigationScenes() throws {
        let data = try Data(contentsOf: repositoryURL(
            "AppStore/KnittingCalculator/Screenshots/manifest.json"
        ))
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let frames = try #require(payload["frames"] as? [[String: Any]])

        let scenes = Set(frames.compactMap { $0["scene"] as? String })

        #expect(scenes == [
            "home", "gauge", "adjustment", "privacy", "promotion", "privacyPromotion",
        ])
    }

    private func repositoryURL(_ relativePath: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
    }
}
