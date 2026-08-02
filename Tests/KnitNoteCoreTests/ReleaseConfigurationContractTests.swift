import Foundation
import Testing

@Suite struct ReleaseConfigurationContractTests {
    @Test func projectUsesProductionIdentifiersVersionAndTeam() throws {
        let yaml = try sourceText("project.yml")

        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.share"))
        #expect(
            yaml.components(separatedBy: "MARKETING_VERSION: 1.2.1").count == 4
        )
        #expect(
            yaml.components(separatedBy: "CURRENT_PROJECT_VERSION: 4").count == 4
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

        #expect(projectArchive.contains("static let currentVersion = 11"))
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

        #expect(text.contains("下一版 release candidate：`1.2.1`"))
        #expect(text.contains("legacy paid owner 依 1.2.0 既定版本界線"))
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

    @Test func releaseAuditUsesRepairVersionAndHistoricalVerificationStaysLabeled() throws {
        let audit = try sourceText("AppStore/Verification/release_audit.sh")
        let verification = try sourceText(
            "AppStore/Verification/PatternLibraryVerification.md"
        )

        #expect(audit.contains(#"EXPECTED_VERSION="1.2.1""#))
        #expect(verification.contains("Candidate: `1.2.0` / Build `3`"))
        #expect(verification.contains("does not verify the pending `1.2.1`"))
    }

    @Test func englishMetadataUsesApprovedWatchFirstPositioning() throws {
        let fields = try metadataFields("AppStore/Metadata/en-US.md")

        #expect(fields["Name"] == "KnitNote: Row Counter & PDF")
        #expect(fields["Subtitle"] == "Knitting with Apple Watch")
        let promotionalText = try #require(fields["Promotional text"])
        for message in ["7 days", "Apple Watch", "one purchase"] {
            #expect(promotionalText.localizedCaseInsensitiveContains(message))
        }
    }

    @Test func englishKeywordsRetainApprovedDiscoveryTermsWithoutRepeatingTitleCopy() throws {
        let fields = try metadataFields("AppStore/Metadata/en-US.md")
        let keywords = try #require(fields["Keywords"])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let required = [
            "crochet", "pattern", "gauge", "yarn", "stitch", "needle",
            "hook", "journal", "tracker", "craft", "sweater",
        ]

        #expect(Set(required).isSubset(of: Set(keywords)))
        #expect(keywords.joined(separator: ",").utf8.count <= 100)
        let reservedWords = Set(
            [
                try #require(fields["Name"]),
                try #require(fields["Subtitle"]),
            ]
            .joined(separator: " ")
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        )
        #expect(Set(keywords).isDisjoint(with: reservedWords))
    }

    @Test func submissionDocumentsLifetimeProductAndCommercialLaunchChecklist() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")

        for requirement in [
            "com.phillon.KnitNote.lifetimeUnlock",
            "non-consumable",
            "review screenshot",
            "first IAP with the new app version",
            "US$2.99",
            "US$4.99",
            "20 free codes",
            "legacy paid",
            "free app price",
        ] {
            #expect(text.localizedCaseInsensitiveContains(requirement))
        }
    }

    @Test func legacyPaidAppPricingRecordCannotBeMistakenForTheVersion12IAPPlan() throws {
        let pricing = try sourceText("AppStore/KnitNotePricing.md")

        #expect(pricing.contains("1.0 HISTORICAL"))
        #expect(pricing.contains("DO NOT USE FOR 1.2"))
        #expect(pricing.contains("AppStoreSubmission.md"))
        #expect(pricing.contains("com.phillon.KnitNote.lifetimeUnlock"))
        #expect(pricing.localizedCaseInsensitiveContains("free app"))
        #expect(pricing.localizedCaseInsensitiveContains("later price US$4.99"))
        #expect(pricing.contains("修復版 binary 與第一個 non-consumable IAP"))
        #expect(pricing.contains("不得把目前付費下載的 App 改為免費"))
    }

    @Test func submissionSeparatesReleasedBuildFromPendingRepairAndAvailabilityHold() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")

        #expect(text.contains("已發佈版本：`1.2.0`／Build `3`"))
        #expect(text.contains("下一版 release candidate：`1.2.1`"))
        #expect(text.contains("`PENDING REPAIR`：1.2.1／Build 3"))
        #expect(text.contains("全部 175 個 storefronts"))
        #expect(text.contains("修復版 binary 與第一個 non-consumable IAP"))
    }

    @Test func submissionLabelsUploadedScreenshotsAsHistoricalVersion10Evidence() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")
        let historicalLines = text.split(separator: "\n").filter {
            $0.contains("28 張") || $0.contains("iPhone 5 張")
        }

        #expect(!historicalLines.isEmpty)
        #expect(historicalLines.allSatisfy { $0.contains("1.0 HISTORICAL") })
        #expect(text.contains("1.2 六張新版成品"))
        #expect(text.contains("`PENDING`"))
    }

    @Test func submissionExplainsEntitlementPrivacyRestoreAndRedemptionBehavior() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")

        for requirement in [
            "one purchase",
            "iPhone",
            "iPad",
            "Mac",
            "Apple Watch",
            "restore",
            "redeem",
            "legacy",
            "no account",
            "no tracking",
        ] {
            #expect(text.localizedCaseInsensitiveContains(requirement))
        }
    }

    @Test func storeKitConfigurationIsDebugOnlyAndReleaseArchivesStayProductionSafe() throws {
        let yaml = try sourceText("project.yml")
        let scheme = try sourceText("KnitNote.xcodeproj/xcshareddata/xcschemes/KnitNote.xcscheme")
        let generatedProject = try sourceText("KnitNote.xcodeproj/project.pbxproj")

        #expect(yaml.contains("run:\n      config: Debug\n      storeKitConfiguration: KnitNote/StoreKit/KnitNote.storekit"))
        #expect(yaml.contains("archive:\n      config: Release"))
        #expect(yaml.contains("- \"Info 2.plist\""))
        #expect(!generatedProject.contains("Info 2.plist"))
        #expect(scheme.contains("<LaunchAction\n      buildConfiguration = \"Debug\""))
        #expect(scheme.contains("<StoreKitConfigurationFileReference"))
        #expect(scheme.contains("<ArchiveAction\n      buildConfiguration = \"Release\""))
        let archiveSection = try #require(
            scheme.components(separatedBy: "<ArchiveAction").last?
                .components(separatedBy: "</ArchiveAction>").first
        )
        #expect(!archiveSection.contains("StoreKitConfigurationFileReference"))
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

    @Test func patternLibraryVerificationRecordsScopedPhysicalShareAcceptance() throws {
        let text = try sourceText(
            "AppStore/Verification/PatternLibraryVerification.md"
        )

        #expect(text.contains("Signed iPhone Share Sheet: `PASS`"))
        #expect(text.contains("iPhone 17 Pro Max"))
        #expect(text.contains("ShareExtensionActivationVerification.md"))
        #expect(text.contains("Remaining manual matrix: `INCOMPLETE`"))
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

    @Test func staticReleaseAuditPinsBuildFourAndChecksEveryStringCatalog() throws {
        let script = try sourceText("AppStore/Verification/release_audit.sh")

        #expect(script.contains("EXPECTED_BUILD=\"4\""))
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

private func metadataFields(_ relativePath: String) throws -> [String: String] {
    var fields: [String: String] = [:]
    for line in try sourceText(relativePath).split(separator: "\n") {
        guard line.hasPrefix("- "),
              let separator = line.firstIndex(of: ":")
        else { continue }
        let key = String(line[line.index(line.startIndex, offsetBy: 2)..<separator])
        let value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        fields[key] = value
    }
    return fields
}

private let releaseConfigurationRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
