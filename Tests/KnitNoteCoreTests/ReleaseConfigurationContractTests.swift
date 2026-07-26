import Foundation
import Testing

@Suite struct ReleaseConfigurationContractTests {
    @Test func projectUsesProductionIdentifiersVersionAndTeam() throws {
        let yaml = try sourceText("project.yml")

        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.share"))
        #expect(
            yaml.components(separatedBy: "MARKETING_VERSION: 1.2.0").count == 4
        )
        #expect(
            yaml.components(separatedBy: "CURRENT_PROJECT_VERSION: 2").count == 4
        )
        #expect(yaml.contains("DEVELOPMENT_TEAM: 9CFPAUL5N5"))
    }

    @Test func releaseCandidateUsesCurrentPatternAndBackupFormats() throws {
        let projectArchive = try sourceText(
            "Sources/KnitNoteCore/Projects/JSONProjectStore.swift"
        )
        let backupManifest = try sourceText(
            "Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift"
        )

        #expect(projectArchive.contains("static let currentVersion = 10"))
        #expect(backupManifest.contains("static let currentFormatVersion = 2"))
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

        #expect(text.contains("1.2.0"))
        #expect(text.contains("schema 10"))
        #expect(text.contains("manifest 2"))
        #expect(text.contains("KnitNoteShare"))
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

    @Test func patternLibraryVerificationSeparatesAutomatedAndManualEvidence() throws {
        let text = try sourceText(
            "AppStore/Verification/PatternLibraryVerification.md"
        )

        for heading in [
            "Automated verification",
            "Build verification",
            "Device and manual matrix",
            "Not executed",
        ] {
            #expect(text.contains(heading))
        }
    }

    @Test func staticReleaseAuditExecutesWithoutRecursingIntoSwiftTests() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [
            "AppStore/Verification/release_audit.sh",
            "--static-only",
        ]
        process.currentDirectoryURL = releaseConfigurationRepositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        #expect(text?.contains("RELEASE AUDIT: PASS") == true)
    }

    @Test func staticReleaseAuditPinsBuildTwoAndChecksEveryStringCatalog() throws {
        let script = try sourceText("AppStore/Verification/release_audit.sh")

        #expect(script.contains("EXPECTED_BUILD=\"2\""))
        #expect(script.contains("def localization_is_complete"))
        for catalog in [
            "KnitNote/Localization/Localizable.xcstrings",
            "KnitNoteWatch/Localizable.xcstrings",
            "KnitNoteShare/Localizable.xcstrings",
        ] {
            #expect(script.contains(catalog))
        }
    }

    @Test func archiveAuditReadsSignedAppGroupEntitlementsFromAppAndShare() throws {
        let script = try sourceText("AppStore/Verification/release_audit.sh")

        #expect(script.contains("codesign -d --entitlements :-"))
        #expect(script.contains("verify_signed_app_group \"$IOS\""))
        #expect(script.contains("verify_signed_app_group \"$SHARE\""))
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
