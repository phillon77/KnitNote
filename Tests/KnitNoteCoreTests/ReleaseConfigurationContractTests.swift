import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct ReleaseConfigurationContractTests {
    @Test func appDeclaresLocalizedPhotoAddUsage() throws {
        let project = try sourceText("project.yml")
        #expect(project.contains("NSPhotoLibraryAddUsageDescription:"))

        let catalogData = try Data(
            contentsOf: releaseConfigurationRepositoryRoot.appending(
                path: "KnitNote/Localization/InfoPlist.xcstrings"
            )
        )
        let payload = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try #require(payload["strings"] as? [String: Any])
        let entry = try #require(
            strings["NSPhotoLibraryAddUsageDescription"] as? [String: Any]
        )
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let locales = [
            "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
            "nb", "sv", "fi", "da", "ko", "el", "nl",
        ]
        #expect(Set(localizations.keys) == Set(locales))
        for locale in locales {
            let localization = try #require(localizations[locale] as? [String: Any])
            let unit = try #require(localization["stringUnit"] as? [String: Any])
            #expect((unit["value"] as? String)?.isEmpty == false)
        }
    }

    @Test func projectUsesProductionIdentifiersVersionAndTeam() throws {
        let yaml = try sourceText("project.yml")

        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.share"))
        #expect(
            yaml.components(separatedBy: "MARKETING_VERSION: 1.7.0").count == 4
        )
        #expect(
            yaml.components(separatedBy: "CURRENT_PROJECT_VERSION: 15").count == 4
        )
        #expect(yaml.contains("DEVELOPMENT_TEAM: 9CFPAUL5N5"))
    }

    @Test func releaseCandidateUsesCurrentPatternAndBackupFormats() throws {
        let schema = try sourceText(
            "Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift"
        )
        let archive = try sourceText(
            "Sources/KnitNoteCore/Projects/JSONProjectStore.swift"
        )
        let backupManifest = try sourceText(
            "Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift"
        )

        #expect(schema == """
        extension ProjectArchive {
            public static let currentVersion = 14
        }

        """)
        #expect(!archive.contains("static let currentVersion"))
        #expect(ProjectArchive.currentVersion == 14)
        #expect(backupManifest.contains("static let currentFormatVersion = 2"))
    }

    @Test func macAppStoreBuildUsesSandboxWithUserSelectedFileAndOutboundNetworkAccess() throws {
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
        #expect(entitlements?["com.apple.security.network.client"] as? Bool == true)
        #expect(Set(entitlements?.keys.map { $0 } ?? []) == [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client",
        ])
    }

    @Test func submissionSourceHasEveryRequiredSection() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")

        #expect(text.contains("公開版本：iOS／macOS `1.2.1`"))
        #expect(text.contains("legacy paid owner"))
        let source = try sourceText("Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift")
        let sourceMatch = try #require(source.firstMatch(of: /static let currentVersion = ([0-9]+)/))
        let documentedMatch = try #require(text.firstMatch(of: /current project archive format uses schema ([0-9]+)/))
        #expect(sourceMatch.1 == documentedMatch.1)
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

    @Test func releaseAuditUsesVersion170Build13AndHistoricalVerificationStaysLabeled() throws {
        let audit = try sourceText("AppStore/Verification/release_audit.sh")
        let verification = try sourceText(
            "AppStore/Verification/PatternLibraryVerification.md"
        )

        #expect(audit.contains(#"EXPECTED_VERSION="1.7.0""#))
        #expect(audit.contains(#"EXPECTED_BUILD="15""#))
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

        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        #expect(process.terminationStatus == 0)
        #expect(text?.contains("STATIC RELEASE AUDIT: PASS") == true)
    }

    @Test func staticReleaseAuditPinsBuildFifteenAndChecksEveryStringCatalog() throws {
        let script = try sourceText("AppStore/Verification/release_audit.sh")

        #expect(script.contains("EXPECTED_BUILD=\"15\""))
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

        #expect(script.contains("\"$CODESIGN\" -d --entitlements :-"))
        #expect(script.contains("verify_signed_app_group \"$IOS\""))
        #expect(script.contains("verify_signed_app_group \"$SHARE\""))
    }

    @Test func updateReminderSourcesAreOwnedOnlyByTheMainAppTarget() throws {
        try validateUpdateReminderOwnership(
            yaml: sourceText("project.yml"),
            generatedProject: sourceText("KnitNote.xcodeproj/project.pbxproj")
        )
    }

    @Test func updateReminderOwnershipRejectsMissingWatchExclusion() throws {
        let yaml = try sourceText("project.yml")
        let generatedProject = try sourceText("KnitNote.xcodeproj/project.pbxproj")
        let broken = yaml.replacingOccurrences(
            of: "          - App/AppVersion.swift\n",
            with: ""
        )

        #expect(throws: UpdateReminderOwnershipError.self) {
            try validateUpdateReminderOwnership(
                yaml: broken,
                generatedProject: generatedProject
            )
        }
    }

    @Test func updateReminderOwnershipRejectsMissingMainAppMembership() throws {
        let yaml = try sourceText("project.yml")
        let generatedProject = try sourceText("KnitNote.xcodeproj/project.pbxproj")
        let broken = generatedProject.replacingOccurrences(
            of: "path = AppVersion.swift;",
            with: "path = MissingAppVersion.swift;"
        )

        #expect(throws: UpdateReminderOwnershipError.self) {
            try validateUpdateReminderOwnership(yaml: yaml, generatedProject: broken)
        }
    }

    @Test func updateReminderOwnershipRejectsWatchMembership() throws {
        let yaml = try sourceText("project.yml")
        let generatedProject = try sourceText("KnitNote.xcodeproj/project.pbxproj")
        let broken = generatedProject.replacingOccurrences(
            of: "path = KnitNoteWatchApp.swift;",
            with: "path = AppVersion.swift;"
        ).replacingOccurrences(
            of: "path = KnitNoteWatch;",
            with: "path = Sources/KnitNoteCore/App;"
        )

        #expect(throws: UpdateReminderOwnershipError.self) {
            try validateUpdateReminderOwnership(yaml: yaml, generatedProject: broken)
        }
    }

    @Test func updateReminderOwnershipRejectsShareMembership() throws {
        let yaml = try sourceText("project.yml")
        let generatedProject = try sourceText("KnitNote.xcodeproj/project.pbxproj")
        let broken = generatedProject.replacingOccurrences(
            of: "path = ShareViewController.swift;",
            with: "path = AppUpdateReminderLiveFactory.swift;"
        ).replacingOccurrences(
            of: "path = KnitNoteShare;",
            with: "path = KnitNote/App;"
        )

        #expect(throws: UpdateReminderOwnershipError.self) {
            try validateUpdateReminderOwnership(yaml: yaml, generatedProject: broken)
        }
    }

    @Test func staticAuditAcceptsOnlyTheApprovedAppStoreUpdateNetworkSurface() throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status == 0)
        #expect(result.output.contains("TEST FIXTURE STATIC AUDIT: PASS"))
    }

    @Test func staticAuditRejectsAnUnexpectedSecondNetworkFile() throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let unexpected = fixture.appending(path: "KnitNote/UnexpectedNetwork.swift")
        try FileManager.default.createDirectory(
            at: unexpected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let session = URLSession.shared\n".write(
            to: unexpected,
            atomically: true,
            encoding: .utf8
        )

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0)
        #expect(result.output.contains("unexpected network, analytics, or tracking source"))
    }

    @Test func staticAuditRejectsAnUnexpectedLookupHost() throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let lookup = fixture.appending(
            path: "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift"
        )
        let broken = try String(contentsOf: lookup, encoding: .utf8)
            .replacingOccurrences(of: "itunes.apple.com", with: "example.com")
        try broken.write(to: lookup, atomically: true, encoding: .utf8)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0)
        #expect(result.output.contains("App Store update live-network sentinel is not canonical"))
    }

    @Test func staticAuditRejectsLookupWithoutTheProductionIdentity() throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let lookup = fixture.appending(
            path: "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift"
        )
        let broken = try String(contentsOf: lookup, encoding: .utf8)
            .replacingOccurrences(
                of: "static let bundleID = \"com.phillon.KnitNote\"",
                with: "static let bundleID = \"com.example.KnitNote\""
            )
        try broken.write(to: lookup, atomically: true, encoding: .utf8)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0)
        #expect(result.output.contains("App Store update live-network sentinel is not canonical"))
    }

    @Test func staticAuditRejectsANetworkSessionInTheDebugFixture() throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let debugFixture = fixture.appending(path: "KnitNote/App/AppUpdateFixture.swift")
        let broken = try String(contentsOf: debugFixture, encoding: .utf8)
            + "\nlet unexpected = URLSession.shared\n"
        try broken.write(to: debugFixture, atomically: true, encoding: .utf8)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0)
        #expect(result.output.contains("unexpected network, analytics, or tracking source"))
    }

    @Test func staticAuditRejectsDynamicHostLoaderInvocationOutsideTheSentinel() throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let lookup = fixture.appending(
            path: "Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift"
        )
        let source = try String(contentsOf: lookup, encoding: .utf8)
        let dynamicInvocation = """

        extension AppStoreUpdateLookup {
            func reviewerProof(
                loader: @escaping AppStoreUpdateLiveNetworkContract.Loader
            ) async throws -> AppUpdateHTTPResponse {
                var components = URLComponents()
                components.scheme = "https"
                components.host = ProcessInfo.processInfo.environment["LOOKUP_HOST"]
                    ?? "example.com"
                components.path = "/lookup"
                return try await loader(URLRequest(url: components.url!))
            }
        }
        """
        let broken = source + dynamicInvocation
        try broken.write(to: lookup, atomically: true, encoding: .utf8)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0)
        #expect(result.output.contains("unexpected network, analytics, or tracking source"))
    }

    @Test(arguments: updateFactoryBypassMutations)
    func staticAuditRejectsProductionFactoryBypassingTheLiveLookup(
        mutation: UpdateFactoryBypassMutation
    ) throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let factory = fixture.appending(
            path: "KnitNote/App/AppUpdateReminderLiveFactory.swift"
        )
        let source = try String(contentsOf: factory, encoding: .utf8)
        let broken = source.replacingOccurrences(
            of: "        let lookup = AppStoreUpdateLookup.live()",
            with: mutation.replacement
        )
        try #require(broken != source)
        try broken.write(to: factory, atomically: true, encoding: .utf8)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0, Comment(rawValue: mutation.name))
        #expect(
            result.output.contains("production update-reminder factory is not canonical"),
            Comment(rawValue: mutation.name)
        )
    }

    @Test(arguments: unexpectedLookupCapabilitySources)
    func staticAuditRejectsUnexpectedLookupCapabilityUse(
        mutation: UnexpectedLookupCapabilitySource
    ) throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let unexpected = fixture.appending(path: "KnitNote/UnexpectedLookup.swift")
        try FileManager.default.createDirectory(
            at: unexpected.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try mutation.source.write(
            to: unexpected,
            atomically: true,
            encoding: .utf8
        )

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0, Comment(rawValue: mutation.name))
        #expect(
            result.output.contains("unexpected network, analytics, or tracking source"),
            Comment(rawValue: mutation.name)
        )
    }

    @Test(arguments: unsafeLiveSessionMutations)
    func staticAuditRejectsEachMissingOrUnsafeLiveSessionSetting(
        mutation: UpdateNetworkSourceMutation
    ) throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try applyUpdateNetworkMutation(mutation, in: fixture)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0, Comment(rawValue: mutation.name))
        #expect(
            result.output.contains("App Store update live-network sentinel is not canonical"),
            Comment(rawValue: mutation.name)
        )
    }

    @Test(arguments: unsafeStoreURLIdentityMutations)
    func staticAuditRejectsEachMissingStoreURLIdentityGuard(
        mutation: UpdateNetworkSourceMutation
    ) throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try applyUpdateNetworkMutation(mutation, in: fixture)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0, Comment(rawValue: mutation.name))
        #expect(
            result.output.contains("App Store update live-network sentinel is not canonical"),
            Comment(rawValue: mutation.name)
        )
    }

    @Test(arguments: executableNetworkDecoyMutations)
    func staticAuditRejectsExecutableNetworkChangesHiddenBySourceDecoys(
        mutation: UpdateNetworkSourceMutation
    ) throws {
        let fixture = try makeUpdateNetworkScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try applyUpdateNetworkMutation(mutation, in: fixture)

        let result = try runStaticAudit(networkScanRoot: fixture)

        #expect(result.status != 0, Comment(rawValue: mutation.name))
        #expect(
            result.output.contains("App Store update live-network sentinel is not canonical"),
            Comment(rawValue: mutation.name)
        )
    }

    @Test func controlledXcodegenArtifactRejectsOnlyTheForbiddenRepositoryRelativeMembership() throws {
        let canonical = try generateControlledUpdateOwnershipProject(
            removingWatchExclusion: nil
        )
        try validateUpdateReminderOwnership(
            yaml: canonical.yaml,
            generatedProject: canonical.generatedProject
        )

        let mutated = try generateControlledUpdateOwnershipProject(
            removingWatchExclusion: "App/AppVersion.swift"
        )
        #expect(throws: UpdateReminderOwnershipError.self) {
            try validateUpdateReminderOwnership(
                yaml: mutated.yaml,
                generatedProject: mutated.generatedProject
            )
        }
    }
}

struct UpdateNetworkSourceMutation: Sendable, CustomTestStringConvertible {
    let name: String
    let original: String
    let replacement: String

    var testDescription: String { name }
}

struct UpdateFactoryBypassMutation: Sendable, CustomTestStringConvertible {
    let name: String
    let replacement: String

    var testDescription: String { name }
}

private let updateFactoryBypassMutations = [
    UpdateFactoryBypassMutation(
        name: "direct fetcher constructor",
        replacement: "        let lookup = AppStoreUpdateLookup(fetcher: { _, _ in nil })"
    ),
    UpdateFactoryBypassMutation(
        name: "direct fetcher constructor hidden by live comment decoy",
        replacement: """
                // let lookup = AppStoreUpdateLookup.live()
                let lookup = AppStoreUpdateLookup(fetcher: { _, _ in nil })
        """
    ),
]

struct UnexpectedLookupCapabilitySource: Sendable, CustomTestStringConvertible {
    let name: String
    let source: String

    var testDescription: String { name }
}

private let unexpectedLookupCapabilitySources = [
    UnexpectedLookupCapabilitySource(
        name: "direct fetcher constructor outside the sentinel",
        source: "let bypass = AppStoreUpdateLookup(fetcher: { _, _ in nil })\n"
    ),
    UnexpectedLookupCapabilitySource(
        name: "sentinel test seam in production source",
        source: """
        let bypass = AppStoreUpdateLiveNetworkContract.testLookup { _ in
            AppUpdateHTTPResponse(data: Data(), statusCode: 200)
        }

        """
    ),
    UnexpectedLookupCapabilitySource(
        name: "sentinel test seam through a metatype alias",
        source: """
        import Foundation

        private let lookupCapability = AppStoreUpdateLiveNetworkContract.self
        let bypass = lookupCapability.testLookup { _ in
            AppUpdateHTTPResponse(data: Data(), statusCode: 500)
        }

        """
    ),
    UnexpectedLookupCapabilitySource(
        name: "sentinel test seam captured as a member reference",
        source: """
        import Foundation

        private let lookupCapability = AppStoreUpdateLiveNetworkContract.self
        private let makeLookup = lookupCapability.testLookup
        let bypass = makeLookup { _ in
            AppUpdateHTTPResponse(data: Data(), statusCode: 500)
        }

        """
    ),
    UnexpectedLookupCapabilitySource(
        name: "sentinel test seam with line-broken backticked qualification",
        source: """
        import Foundation

        let bypass = AppStoreUpdateLiveNetworkContract
            .`testLookup` { _ in
                AppUpdateHTTPResponse(data: Data(), statusCode: 500)
            }

        """
    ),
]

private let unsafeLiveSessionMutations = [
    UpdateNetworkSourceMutation(
        name: "missing request timeout",
        original: "        configuration.timeoutIntervalForRequest = timeout\n",
        replacement: ""
    ),
    UpdateNetworkSourceMutation(
        name: "missing resource timeout",
        original: "        configuration.timeoutIntervalForResource = timeout\n",
        replacement: ""
    ),
    UpdateNetworkSourceMutation(
        name: "cookies enabled",
        original: "        configuration.httpShouldSetCookies = false\n",
        replacement: "        configuration.httpShouldSetCookies = true\n"
    ),
    UpdateNetworkSourceMutation(
        name: "cookie acceptance enabled",
        original: "        configuration.httpCookieAcceptPolicy = .never\n",
        replacement: "        configuration.httpCookieAcceptPolicy = .always\n"
    ),
    UpdateNetworkSourceMutation(
        name: "shared cookie storage",
        original: "        configuration.httpCookieStorage = nil\n",
        replacement: "        configuration.httpCookieStorage = .shared\n"
    ),
]

private let unsafeStoreURLIdentityMutations = [
    UpdateNetworkSourceMutation(
        name: "missing Store URL user-info guards",
        original: """
                    components.user == nil,
                    components.password == nil,

        """,
        replacement: """
                    // components.user == nil,
                    // components.password == nil,
                    true,

        """
    ),
    UpdateNetworkSourceMutation(
        name: "missing Store URL explicit-port guard",
        original: "            components.port == nil,\n",
        replacement: """
                    // components.port == nil,
                    true,

        """
    ),
    UpdateNetworkSourceMutation(
        name: "missing Store URL app-route guard",
        original: "            path[2] == \"app\",\n",
        replacement: """
                    // path[2] == "app",
                    true,

        """
    ),
    UpdateNetworkSourceMutation(
        name: "missing exact KnitNote product-path guard",
        original: "            path[4] == Substring(\"id\\(appleID)\")\n",
        replacement: """
                    // path[4] == Substring("id\\(appleID)")
                    true

        """
    ),
]

private let executableNetworkDecoyMutations = [
    UpdateNetworkSourceMutation(
        name: "credential-storage comment decoy",
        original: "        configuration.urlCredentialStorage = nil\n",
        replacement: """
                // configuration.urlCredentialStorage = nil
                configuration.urlCredentialStorage = .shared

        """
    ),
    UpdateNetworkSourceMutation(
        name: "dynamic lookup host hidden by comment",
        original: "    private static let lookupHost = \"itunes.apple.com\"\n",
        replacement: """
            // private static let lookupHost = "itunes.apple.com"
            private static var lookupHost: String {
                ProcessInfo.processInfo.environment["LOOKUP_HOST"]!
            }

        """
    ),
    UpdateNetworkSourceMutation(
        name: "production identity hidden by string decoy",
        original: "    private static let bundleID = \"com.phillon.KnitNote\"\n",
        replacement: """
            static var bundleID: String {
                ProcessInfo.processInfo.environment["LOOKUP_BUNDLE_ID"]!
            }
            private static let bundleIDDecoy = "com.phillon.KnitNote"

        """
    ),
    UpdateNetworkSourceMutation(
        name: "duplicate executable request",
        original: "            let (data, response) = try await session.data(for: request)\n",
        replacement: """
                    _ = try await session.data(for: request)
                    let (data, response) = try await session.data(for: request)

        """
    ),
    UpdateNetworkSourceMutation(
        name: "extra dead-code request",
        original: "            let (data, response) = try await session.data(for: request)\n",
        replacement: """
                    if false { _ = try await session.data(for: request) }
                    let (data, response) = try await session.data(for: request)

        """
    ),
    UpdateNetworkSourceMutation(
        name: "noncanonical alternate whitespace",
        original: "        configuration.httpShouldSetCookies = false\n",
        replacement: "        configuration.httpShouldSetCookies=false\n"
    ),
]

private func applyUpdateNetworkMutation(
    _ mutation: UpdateNetworkSourceMutation,
    in fixture: URL
) throws {
    let lookup = fixture.appending(
        path: "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift"
    )
    let source = try String(contentsOf: lookup, encoding: .utf8)
    let mutated = source.replacingOccurrences(
        of: mutation.original,
        with: mutation.replacement
    )
    try #require(mutated != source)
    try mutated.write(to: lookup, atomically: true, encoding: .utf8)
}

private struct ControlledUpdateOwnershipProject {
    let yaml: String
    let generatedProject: String
}

private func generateControlledUpdateOwnershipProject(
    removingWatchExclusion: String?
) throws -> ControlledUpdateOwnershipProject {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "knitnote-update-ownership-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let sources = [
        "Sources/KnitNoteCore/App/AppVersion.swift",
        "Sources/KnitNoteCore/App/UpdateReminderPolicy.swift",
        "Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift",
        "Sources/KnitNoteCore/App/AppUpdateReminderCoordinator.swift",
        "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift",
        "KnitNote/App/AppUpdateReminderLiveFactory.swift",
        "KnitNote/App/AppUpdateFixture.swift",
        "KnitNoteWatch/AppVersion.swift",
        "KnitNoteWatch/KnitNoteWatchApp.swift",
        "KnitNoteShare/AppUpdateFixture.swift",
        "KnitNoteShare/ShareViewController.swift",
    ]
    for relativePath in sources {
        let file = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
    }

    let exclusions: [String] = [
        "App/AppVersion.swift",
        "App/UpdateReminderPolicy.swift",
        "App/AppStoreUpdateLookup.swift",
        "App/AppUpdateReminderCoordinator.swift",
        "App/AppStoreUpdateLiveNetworkContract.swift",
    ].filter { $0 != removingWatchExclusion }
    let exclusionLines = exclusions.map { "          - \($0)" }.joined(separator: "\n")
    let yaml = """
    name: OwnershipFixture
    options:
      bundleIdPrefix: test.knitnote
    targets:
      KnitNote:
        type: application
        platform: iOS
        sources:
          - path: KnitNote
          - path: Sources/KnitNoteCore
      KnitNoteWatch:
        type: application
        platform: watchOS
        sources:
          - path: KnitNoteWatch
          - path: Sources/KnitNoteCore
            excludes:
    \(exclusionLines)
      KnitNoteShare:
        type: app-extension
        platform: iOS
        sources:
          - path: KnitNoteShare

    """
    try yaml.write(
        to: root.appending(path: "project.yml"),
        atomically: true,
        encoding: .utf8
    )

    let process = Process()
    process.executableURL = URL(filePath: "/opt/homebrew/bin/xcodegen")
    process.arguments = ["generate", "--quiet"]
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let processOutput = String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    try #require(process.terminationStatus == 0, Comment(rawValue: processOutput))

    return ControlledUpdateOwnershipProject(
        yaml: yaml,
        generatedProject: try String(
            contentsOf: root.appending(path: "OwnershipFixture.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
    )
}

private struct StaticAuditResult {
    let status: Int32
    let output: String
}

private func runStaticAudit(networkScanRoot: URL) throws -> StaticAuditResult {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = [
        "AppStore/Verification/release_audit.sh",
        "--test-only",
        "--static-only",
    ]
    process.currentDirectoryURL = releaseConfigurationRepositoryRoot
    process.environment = ProcessInfo.processInfo.environment.merging([
        "KNITNOTE_NETWORK_SCAN_ROOT": networkScanRoot.path,
    ]) { _, new in new }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    return StaticAuditResult(
        status: process.terminationStatus,
        output: String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func makeUpdateNetworkScanFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "knitnote-update-network-scan-\(UUID().uuidString)"
    )
    for relativePath in [
        "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift",
        "Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift",
        "KnitNote/App/AppUpdateFixture.swift",
        "KnitNote/App/AppUpdateReminderLiveFactory.swift",
    ] {
        let source = releaseConfigurationRepositoryRoot.appending(path: relativePath)
        let destination = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
    return root
}

private enum UpdateReminderOwnershipError: Error {
    case violation(String)
}

private func validateUpdateReminderOwnership(
    yaml: String,
    generatedProject: String
) throws {
    let watchTarget = try yamlTarget(named: "KnitNoteWatch", before: "KnitNoteShare", in: yaml)
    let coreSources = Set([
        "Sources/KnitNoteCore/App/AppVersion.swift",
        "Sources/KnitNoteCore/App/UpdateReminderPolicy.swift",
        "Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift",
        "Sources/KnitNoteCore/App/AppUpdateReminderCoordinator.swift",
        "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift",
    ])
    let mainOnlySources = coreSources.union([
        "KnitNote/App/AppUpdateReminderLiveFactory.swift",
        "KnitNote/App/AppUpdateFixture.swift",
    ])

    for source in coreSources {
        let watchRelativePath = source.replacingOccurrences(
            of: "Sources/KnitNoteCore/",
            with: ""
        )
        guard watchTarget.contains("          - \(watchRelativePath)\n") else {
            throw UpdateReminderOwnershipError.violation(
                "KnitNoteWatch must exclude \(source)"
            )
        }
    }

    let project = UpdateReminderPBXMembership(contents: generatedProject)
    let appSources = Set(try project.sourcePaths(targetName: "KnitNote"))
    let watchSources = Set(try project.sourcePaths(targetName: "KnitNoteWatch"))
    let shareSources = Set(try project.sourcePaths(targetName: "KnitNoteShare"))

    guard mainOnlySources.isSubset(of: appSources) else {
        throw UpdateReminderOwnershipError.violation(
            "KnitNote is missing update-reminder sources: \(mainOnlySources.subtracting(appSources).sorted())"
        )
    }
    guard mainOnlySources.isDisjoint(with: watchSources) else {
        throw UpdateReminderOwnershipError.violation(
            "KnitNoteWatch owns main-app update-reminder sources: \(mainOnlySources.intersection(watchSources).sorted())"
        )
    }
    guard mainOnlySources.isDisjoint(with: shareSources) else {
        throw UpdateReminderOwnershipError.violation(
            "KnitNoteShare owns main-app update-reminder sources: \(mainOnlySources.intersection(shareSources).sorted())"
        )
    }
}

private func yamlTarget(
    named name: String,
    before nextName: String,
    in yaml: String
) throws -> Substring {
    let start = try #require(yaml.range(of: "  \(name):"))
    let end = try #require(
        yaml.range(of: "  \(nextName):", range: start.upperBound..<yaml.endIndex)
    )
    return yaml[start.lowerBound..<end.lowerBound]
}

private struct UpdateReminderPBXMembership {
    let contents: String

    func sourcePaths(targetName: String) throws -> [String] {
        let target = try targetBody(named: targetName)
        let phaseIDs = captures(
            pattern: #"([A-F0-9]{24}) /\* [^*]+ \*/"#,
            in: try capture(pattern: #"buildPhases = \((.*?)\);"#, in: target)
        )
        let sourcesPhaseID = try #require(phaseIDs.first {
            (try? objectBody(id: $0).contains("isa = PBXSourcesBuildPhase;")) == true
        })
        let sourcesPhase = try objectBody(id: sourcesPhaseID)
        let buildFileIDs = captures(
            pattern: #"([A-F0-9]{24}) /\* [^*]+ in Sources \*/"#,
            in: try capture(pattern: #"files = \((.*?)\);"#, in: sourcesPhase)
        )

        return try buildFileIDs.map { buildFileID in
            let buildFile = try objectBody(id: buildFileID)
            let fileRefID = try capture(
                pattern: #"fileRef = ([A-F0-9]{24}) /\* [^*]+ \*/;"#,
                in: buildFile
            )
            return try repositoryRelativePath(fileRefID: fileRefID)
        }
    }

    private func repositoryRelativePath(fileRefID: String) throws -> String {
        let fileRef = try objectBody(id: fileRefID)
        let filePath = try capture(
            pattern: #"path = \"?([^\";]+)\"?;"#,
            in: fileRef
        )
        let parents = try groupParentIDs()
        var groupPaths: [String] = []
        var childID = fileRefID
        var visited = Set<String>()
        while let parentID = parents[childID] {
            guard visited.insert(parentID).inserted else {
                throw UpdateReminderOwnershipError.violation(
                    "PBX group ancestry contains a cycle at \(parentID)"
                )
            }
            let parent = try objectBody(id: parentID)
            if let path = firstCapture(
                pattern: #"path = \"?([^\";]+)\"?;"#,
                in: parent
            ) {
                groupPaths.append(path)
            }
            childID = parentID
        }
        return (groupPaths.reversed() + [filePath]).joined(separator: "/")
    }

    private func groupParentIDs() throws -> [String: String] {
        let expression = try NSRegularExpression(
            pattern: #"([A-F0-9]{24})(?: /\* [^*]+ \*/)? = \{(.*?)^\s*\};"#,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        )
        let range = NSRange(contents.startIndex..., in: contents)
        var parents: [String: String] = [:]
        for match in expression.matches(in: contents, range: range) {
            let idRange = try #require(Range(match.range(at: 1), in: contents))
            let bodyRange = try #require(Range(match.range(at: 2), in: contents))
            let groupID = String(contents[idRange])
            let body = String(contents[bodyRange])
            guard body.contains("isa = PBXGroup;"),
                  let children = firstCapture(
                    pattern: #"children = \((.*?)\);"#,
                    in: body,
                    options: [.dotMatchesLineSeparators]
                  )
            else {
                continue
            }
            for childID in captures(pattern: #"([A-F0-9]{24})"#, in: children) {
                if let existing = parents[childID], existing != groupID {
                    throw UpdateReminderOwnershipError.violation(
                        "PBX child \(childID) has multiple group parents"
                    )
                }
                parents[childID] = groupID
            }
        }
        return parents
    }

    private func targetBody(named name: String) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let bodies = captures(
            pattern: #"[A-F0-9]{24} /\* \#(escaped) \*/ = \{(.*?)^\s*\};"#,
            in: contents,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        )
        return try #require(bodies.first { $0.contains("isa = PBXNativeTarget;") })
    }

    private func objectBody(id: String) throws -> String {
        try capture(
            pattern: #"\#(id)(?: /\* [^*]+ \*/)? = \{(.*?)^\s*\};"#,
            in: contents,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        )
    }

    private func captures(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range(at: 1), in: value).map { String(value[$0]) }
        }
    }

    private func capture(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
    ) throws -> String {
        let expression = try NSRegularExpression(pattern: pattern, options: options)
        let match = try #require(expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ))
        let range = try #require(Range(match.range(at: 1), in: value))
        return String(value[range])
    }

    private func firstCapture(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[range])
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
