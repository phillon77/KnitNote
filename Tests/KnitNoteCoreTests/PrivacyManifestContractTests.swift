import Foundation
import Testing

@Suite struct PrivacyManifestContractTests {
    @Test func projectPackagesBothPrivacyManifestsAsResources() throws {
        let project = try String(
            contentsOf: privacyManifestRepositoryRoot.appending(path: "project.yml"),
            encoding: .utf8
        )

        #expect(project.contains("- path: KnitNote/PrivacyInfo.xcprivacy\n        buildPhase: resources"))
        #expect(project.contains("- path: KnitNoteWatch/PrivacyInfo.xcprivacy\n        buildPhase: resources"))
    }

    @Test func mainAppDeclaresOnlyItsAuditedLocalPrivacyBehavior() throws {
        let manifest = try privacyManifest(at: "KnitNote/PrivacyInfo.xcprivacy")

        try requireNoCollectionOrTracking(manifest)
        #expect(
            try reasonsByCategory(in: manifest) == [
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
                "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            ]
        )
    }

    @Test func watchDeclaresOnlyItsAuditedContainerFileBehavior() throws {
        let manifest = try privacyManifest(at: "KnitNoteWatch/PrivacyInfo.xcprivacy")

        try requireNoCollectionOrTracking(manifest)
        #expect(
            try reasonsByCategory(in: manifest) == [
                "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            ]
        )
    }

    private func privacyManifest(at relativePath: String) throws -> [String: Any] {
        let data = try Data(
            contentsOf: privacyManifestRepositoryRoot.appending(path: relativePath)
        )
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(value as? [String: Any])
    }

    private func requireNoCollectionOrTracking(_ manifest: [String: Any]) throws {
        #expect(Set(manifest.keys) == [
            "NSPrivacyTracking",
            "NSPrivacyTrackingDomains",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyAccessedAPITypes",
        ])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect(try #require(manifest["NSPrivacyTrackingDomains"] as? [Any]).isEmpty)
        #expect(try #require(manifest["NSPrivacyCollectedDataTypes"] as? [Any]).isEmpty)
    }

    private func reasonsByCategory(
        in manifest: [String: Any]
    ) throws -> [String: Set<String>] {
        let entries = try #require(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        return try Dictionary(uniqueKeysWithValues: entries.map { entry in
            let category = try #require(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            return (category, Set(reasons))
        })
    }
}

private let privacyManifestRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
