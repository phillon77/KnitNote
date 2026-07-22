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
