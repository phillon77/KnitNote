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

        #expect(payload["schemaVersion"] as? Int == 1)
        #expect(frames.count == 18)
        #expect(frames.filter { $0["locale"] as? String == "zh-Hant" }.count == 9)
        #expect(frames.filter { $0["locale"] as? String == "en" }.count == 9)
        #expect(frames.filter { $0["platform"] as? String == "iphone" }.count == 10)
        #expect(frames.filter { $0["platform"] as? String == "ipad" }.count == 8)
        #expect(frames.allSatisfy { $0["width"] as? Int == 1284 || $0["width"] as? Int == 2064 })
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
