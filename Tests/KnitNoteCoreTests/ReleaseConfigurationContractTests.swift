import Foundation
import Testing

@Suite struct ReleaseConfigurationContractTests {
    @Test func projectUsesProductionIdentifiersVersionAndTeam() throws {
        let yaml = try sourceText("project.yml")

        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.share"))
        #expect(
            yaml.components(separatedBy: "MARKETING_VERSION: 1.3.1").count == 4
        )
        #expect(
            yaml.components(separatedBy: "CURRENT_PROJECT_VERSION: 7").count == 4
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

        #expect(projectArchive.contains("static let currentVersion = 12"))
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

        #expect(text.contains("公開版本：iOS／macOS `1.2.1`"))
        #expect(text.contains("legacy paid owner"))
        #expect(text.contains("schema 11"))
        #expect(text.contains("manifest 2"))
        #expect(text.contains("KnitNoteShare"))
        for heading in [
            "App identity",
            "Current commercial state",
            "Commercial release boundary",
            "Entitlement and privacy contracts",
            "Current acceptance evidence",
            "Historical records",
        ] {
            #expect(text.contains(heading))
        }
    }

    @Test func submissionPreservesVersion130EvidenceAndKeepsVersion131PhysicalGatesOpen() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")
        let historicalSections = text.components(
            separatedBy: "## 1.3.0 historical verification"
        )
        #expect(historicalSections.count == 2)
        let afterHistoricalHeading = try #require(historicalSections.last)
        let currentSections = afterHistoricalHeading.components(
            separatedBy: "## 1.3.1 development verification"
        )
        #expect(currentSections.count == 2)
        let historical = try #require(currentSections.first)
        let currentAndFollowing = try #require(currentSections.last)
        let currentSectionsEnd = currentAndFollowing.components(
            separatedBy: "## Historical records"
        )
        #expect(currentSectionsEnd.count == 2)
        let current = try #require(currentSectionsEnd.first)

        #expect(historical.contains("Branch: `release/knitnote-1.3`"))
        #expect(historical.contains("Candidate: `1.3.0` / Build `6`"))
        #expect(historical.contains("Physical iPhone/iPad core acceptance: `PASS`"))
        #expect(historical.contains("Physical Mac core acceptance: `PASS`"))

        #expect(current.contains("Branch: `feat/knitnote-1.3.1`"))
        #expect(current.contains("Candidate: `1.3.1` / Build `7`"))
        #expect(current.contains("Automated verification: `PASS`"))
        #expect(current.contains("Physical iPhone/iPad core acceptance: `INCOMPLETE`"))
        #expect(current.contains("Physical Mac core acceptance: `INCOMPLETE`"))
        #expect(current.contains("Extended physical edge-case matrix: `INCOMPLETE`"))
        #expect(current.contains("TestFlight commercial matrix: `INCOMPLETE`"))
        #expect(current.contains("No physical acceptance or public release approval exists yet"))
    }

    @Test func releaseAuditUsesRepairVersionAndHistoricalVerificationStaysLabeled() throws {
        let audit = try sourceText("AppStore/Verification/release_audit.sh")
        let verification = try sourceText(
            "AppStore/Verification/PatternLibraryVerification.md"
        )

        #expect(audit.contains(#"EXPECTED_VERSION="1.3.1""#))
        #expect(audit.contains(#"EXPECTED_BUILD="7""#))
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
            "CommercialConfiguration.json",
            "CommercialReleaseChecklist.md",
            "US$4.99",
            "NT$150",
            "175 個 storefronts",
            "沒有未來價格調整",
            "advertising hold",
        ] {
            #expect(text.localizedCaseInsensitiveContains(requirement))
        }
    }

    @Test func legacyPaidAppPricingRecordCannotBeMistakenForTheVersion12IAPPlan() throws {
        let pricing = try sourceText("AppStore/KnitNotePricing.md")
        let current = try #require(
            pricing.components(separatedBy: "## Historical").first
        )

        #expect(pricing.contains("Historical — KnitNote 1.0 paid-download record"))
        #expect(pricing.contains("NOT EXECUTABLE"))
        #expect(pricing.contains("AppStore/CommercialConfiguration.json"))
        #expect(pricing.contains("com.phillon.KnitNote.lifetimeUnlock"))
        #expect(current.contains("App download: Free"))
        #expect(current.contains("Future App price changes: None"))
        #expect(!current.contains("App download: US$2.99"))
        #expect(!current.contains("2026-08-23"))
    }

    @Test func submissionRecordsCurrentFreeStateAsTimePointEvidence() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")

        #expect(text.contains("公開版本：iOS／macOS `1.2.1`"))
        #expect(text.contains("175 個 storefronts 價格均為 0"))
        #expect(text.contains("United States App 本體價格為 US$0.00"))
        #expect(text.contains("Taiwan App 本體價格為 NT$0"))
        #expect(text.contains("App 本體沒有未來價格調整"))
        #expect(text.contains("不得代替下一次 release 或 re-listing 的"))
    }

    @Test func checklistSeparatesTestFlightFromPublicBuildAcceptance() throws {
        let text = try sourceText(
            "AppStore/Verification/CommercialReleaseChecklist.md"
        )

        #expect(text.contains("Earlier TestFlight evidence, not public-build acceptance"))
        #expect(text.contains("- [x] 2026-07-29: iOS TestFlight"))
        #expect(text.contains("- [ ] Fresh public iOS install"))
        #expect(text.contains("- [ ] Fresh public macOS install"))
        #expect(text.contains("advertising remains blocked"))
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

    @Test func staticReleaseAuditPinsBuildSevenAndChecksEveryStringCatalog() throws {
        let script = try sourceText("AppStore/Verification/release_audit.sh")

        #expect(script.contains("EXPECTED_BUILD=\"7\""))
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
