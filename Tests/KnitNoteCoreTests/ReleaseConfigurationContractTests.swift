import Foundation
import Testing

@Suite struct ReleaseConfigurationContractTests {
    @Test func projectUsesProductionIdentifiersVersionAndTeam() throws {
        let yaml = try sourceText("project.yml")

        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(yaml.contains("MARKETING_VERSION: 1.0.0"))
        #expect(yaml.contains("CURRENT_PROJECT_VERSION: 2"))
        #expect(yaml.contains("DEVELOPMENT_TEAM: 9CFPAUL5N5"))
    }

    @Test func macAppStoreBuildUsesSandboxWithUserSelectedFileAccess() throws {
        let yaml = try sourceText("project.yml")
        let generatedProject = try sourceText("KnitNote.xcodeproj/project.pbxproj")
        let entitlementData = try? Data(
            contentsOf: releaseConfigurationRepositoryRoot.appending(path: "KnitNote/KnitNote-macOS.entitlements")
        )
        let entitlements = try entitlementData.map {
            try PropertyListSerialization.propertyList(from: $0, options: [], format: nil)
        } as? [String: Any]

        #expect(yaml.contains("\"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]\": KnitNote/KnitNote-macOS.entitlements"))
        let generatedSetting = "\"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]\" = \"KnitNote/KnitNote-macOS.entitlements\";"
        #expect(generatedProject.components(separatedBy: generatedSetting).count - 1 == 2)
        #expect(entitlementData != nil)
        #expect(entitlements?["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements?["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(entitlements?.count == 2)
    }

    @Test func submissionSourceHasEveryRequiredSection() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")

        for heading in [
            "Commercial configuration",
            "Builds",
            "Localizations",
            "Privacy",
            "Screenshots",
            "Review information",
            "Manual release",
            "Final approval boundary",
        ] {
            #expect(text.contains(heading))
        }
    }
}

private func sourceText(_ relativePath: String) throws -> String {
    try String(
        contentsOf: releaseConfigurationRepositoryRoot.appending(path: relativePath),
        encoding: .utf8
    )
}

private let releaseConfigurationRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
