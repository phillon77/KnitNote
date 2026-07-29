import Foundation
import Testing

@Suite struct KnittingCalculatorProjectContractTests {
    @Test func knitNoteDeclaresSharedCalculatorPackageDependency() throws {
        let package = try source("Package.swift")
        let compactPackage = package.components(
            separatedBy: .whitespacesAndNewlines
        ).joined()
        let yaml = try source("project.yml")
        let knitNoteTarget = try #require(
            yaml.split(separator: "  KnittingCalculator:").first?
                .split(separator: "  KnitNote:").last
        )

        #expect(compactPackage.contains(".package(path:\"Packages/KnittingCalculatorCore\")"))
        #expect(
            compactPackage.contains(
                ".product(name:\"KnittingCalculatorCore\",package:\"KnittingCalculatorCore\")"
            )
        )
        #expect(yaml.contains("  KnittingCalculatorCore:\n    path: Packages/KnittingCalculatorCore"))
        #expect(knitNoteTarget.contains("- package: KnittingCalculatorCore"))

        for obsoletePath in [
            "Sources/KnitNoteCore/Calculators/GaugeCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentInputParser.swift",
            "Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift",
        ] {
            #expect(!yaml.contains("- path: \(obsoletePath)"))
        }
    }

    @Test func knitNoteCalculatorConsumersImportSharedModule() throws {
        for path in [
            "KnitNote/Calculators/GaugeCalculatorView.swift",
            "KnitNote/Calculators/EvenStitchAdjustmentCalculatorView.swift",
            "KnitNote/Calculators/RowIntervalAdjustmentView.swift",
        ] {
            #expect(
                try source(path).contains("import KnittingCalculatorCore"),
                "\(path) must explicitly import KnittingCalculatorCore"
            )
        }
    }

    @Test func combinedFreeAppCalculatorConsumersImportSharedModule() throws {
        for path in [
            "KnittingCalculator/Adjustment/OneRowAdjustmentView.swift",
            "KnittingCalculator/Adjustment/RowIntervalAdjustmentView.swift",
            "KnittingCalculator/Gauge/GaugeCalculatorScreen.swift",
            "KnittingCalculator/Model/CalculatorPreferencesStore.swift",
            "KnittingCalculator/Model/CalculatorShareText.swift",
            "KnittingCalculator/Settings/CalculatorSettingsView.swift",
        ] {
            #expect(
                try source(path).contains("import KnittingCalculatorCore"),
                "\(path) must explicitly import KnittingCalculatorCore"
            )
        }
    }

    @Test func projectDefinesIsolatedFreeAppAndTestTargets() throws {
        let yaml = try source("project.yml")
        #expect(yaml.contains("  KnittingCalculator:\n    type: application\n    platform: iOS"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnittingCalculator"))
        #expect(yaml.contains("MARKETING_VERSION: 1.0.0"))
        #expect(yaml.contains("CURRENT_PROJECT_VERSION: 1"))
        #expect(yaml.contains("  KnittingCalculatorTests:\n    type: bundle.unit-test"))
        #expect(yaml.contains("- target: KnittingCalculator"))
        #expect(yaml.contains("  KnittingCalculator:\n    build:"))
    }

    @Test func combinedFreeAppConsumesSharedCalculatorPackage() throws {
        let yaml = try source("project.yml")
        let target = try #require(
            yaml.split(separator: "  KnittingCalculatorTests:").first?
                .split(separator: "  KnittingCalculator:").last
        )

        #expect(target.contains("- package: KnittingCalculatorCore"))
        for path in [
            "Sources/KnitNoteCore/Calculators/GaugeCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentInputParser.swift",
            "Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift",
        ] {
            #expect(!target.contains("- path: \(path)"))
        }
        #expect(!target.contains("Sources/KnitNoteCore/Projects"))
        #expect(!target.contains("Sources/KnitNoteCore/Yarn"))
        #expect(!target.contains("KnitNoteWatch"))
    }

    @Test func freeAppReleaseAuditPinsIdentityAndRejectsSentinels() throws {
        let script = try source("AppStore/Verification/knitting_calculator_release_audit.sh")

        #expect(script.contains("EXPECTED_BUNDLE=\"com.phillon.KnittingCalculator\""))
        #expect(script.contains("EXPECTED_VERSION=\"1.0.0\""))
        #expect(script.contains("EXPECTED_BUILD=\"1\""))
        #expect(script.contains("apps.apple.com/app/id[0-9]+"))
        #expect(script.contains("KnittingCalculator/PrivacyInfo.xcprivacy"))
        #expect(script.contains("KnittingCalculator/Localization/Localizable.xcstrings"))
        #expect(script.contains("\"get-task-allow\""))
        #expect(script.contains("ARCHIVE STRUCTURE PASS"))
        #expect(script.contains("ARCHIVE RELEASE SIGNING PASS"))
        #expect(script.contains("--ipa"))
        #expect(script.contains("IPA RELEASE SIGNING PASS"))
    }

    @Test func releaseAuditTargetsOnlyTheIndependentCalculatorProject() throws {
        let script = try source("AppStore/Verification/knitting_calculator_release_audit.sh")

        #expect(
            script.contains(
                "PROJECT_SPEC=\"KnittingCalculator/project.yml\""
            )
        )
        #expect(
            script.contains(
                "PROJECT_FILE=\"KnittingCalculator.xcodeproj\""
            )
        )
        #expect(script.contains("xcodegen dump"))
        #expect(script.contains("--spec \"$PROJECT_SPEC\""))
        #expect(script.contains("require_file \"$PROJECT_FILE/project.pbxproj\""))
        #expect(!script.contains("KnitNote.xcodeproj"))
        #expect(!script.contains("KnitNoteWatch"))
        #expect(!script.contains("KnitNoteShare"))
    }

    @Test func releaseAuditRequiresExactAppStoreDistributionSigning() throws {
        let script = try source("AppStore/Verification/knitting_calculator_release_audit.sh")

        #expect(script.contains("EXPECTED_TEAM_IDENTIFIER=\"9CFPAUL5N5\""))
        #expect(script.contains("security cms -D -i"))
        #expect(script.contains("|| fail \"cannot decode embedded provisioning profile\""))
        #expect(
            script.contains(
                "[[ \"$app_identifier\" == \"$EXPECTED_TEAM_IDENTIFIER.$EXPECTED_BUNDLE\" ]]"
            )
        )
        #expect(script.contains("[[ \"$get_task_allow\" == \"false\" ]]"))
        #expect(script.contains("[[ \"$beta_reports_active\" == \"true\" ]]"))
        #expect(
            script.contains(
                "if plist_value \"$profile_plist\" \"ProvisionedDevices\""
            )
        )
        #expect(
            script.contains(
                "if plist_value \"$profile_plist\" \"ProvisionsAllDevices\""
            )
        )
        #expect(script.contains("TeamIdentifier"))
        #expect(
            script.contains(
                "[[ \"$leaf_authority\" == \"Apple Distribution: \"* ]]"
            )
        )
        #expect(script.contains("|| fail \"cannot decode archive signing authority\""))
        #expect(script.contains("leaf signing authority"))
    }

    @Test func freeAppDeclaresItsOwnLaunchScreen() throws {
        let yaml = try source("project.yml")
        let calculatorTarget = try #require(
            yaml.split(separator: "  KnittingCalculatorTests:").first?
                .split(separator: "  KnittingCalculator:").last
        )
        let storyboard = try source("KnittingCalculator/LaunchScreen.storyboard")

        #expect(calculatorTarget.contains("UILaunchStoryboardName: LaunchScreen"))
        #expect(calculatorTarget.contains("- LaunchScreen.storyboard"))
        #expect(
            calculatorTarget.contains(
                "- path: KnittingCalculator/LaunchScreen.storyboard"
            )
        )
        #expect(storyboard.contains("launchScreen=\"YES\""))
        #expect(!storyboard.contains("FamilyKnittingHero"))
    }

    @Test func independentProjectDefinesOnlyCalculatorAppAndTests() throws {
        let yaml = try source("KnittingCalculator/project.yml")

        #expect(yaml.contains("name: KnittingCalculator"))
        #expect(yaml.contains("  KnittingCalculator:\n    type: application"))
        #expect(yaml.contains("  KnittingCalculatorTests:\n    type: bundle.unit-test"))
        #expect(
            targetNames(in: yaml) == [
                "KnittingCalculator",
                "KnittingCalculatorTests",
            ]
        )
        #expect(!yaml.contains("KnitNoteWatch"))
        #expect(!yaml.contains("KnitNoteShare"))
        #expect(!yaml.contains("StoreKit"))
        #expect(!yaml.contains("entitlements"))
    }

    @Test func independentAppOwnsIdentityResourcesAndSharedPackage() throws {
        let yaml = try source("KnittingCalculator/project.yml")
        let appTarget = try #require(
            yaml.split(separator: "  KnittingCalculatorTests:").first?
                .split(separator: "  KnittingCalculator:").last
        )

        #expect(yaml.contains("path: Packages/KnittingCalculatorCore"))
        #expect(appTarget.contains("- package: KnittingCalculatorCore"))
        #expect(
            appTarget.contains(
                "PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnittingCalculator"
            )
        )
        #expect(appTarget.contains("MARKETING_VERSION: 1.0.0"))
        #expect(appTarget.contains("CURRENT_PROJECT_VERSION: 1"))
        #expect(appTarget.contains("UILaunchStoryboardName: LaunchScreen"))
        #expect(
            appTarget.contains(
                "- path: KnittingCalculator/LaunchScreen.storyboard"
            )
        )
        #expect(
            appTarget.contains(
                "- path: KnittingCalculator/PrivacyInfo.xcprivacy"
            )
        )
        #expect(
            appTarget.contains(
                "- path: KnittingCalculator/Localization/InfoPlist.xcstrings"
            )
        )
        #expect(
            appTarget.contains(
                "- path: KnittingCalculator/Localization/Localizable.xcstrings"
            )
        )
        #expect(appTarget.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"))
    }

    @Test func independentSpecUsesRepositoryRootPathsForProjectRootGeneration() throws {
        let yaml = try source("KnittingCalculator/project.yml")

        #expect(yaml.contains("path: Packages/KnittingCalculatorCore"))
        #expect(yaml.contains("path: KnittingCalculator/Info.plist"))
        #expect(yaml.contains("- path: KnittingCalculator/Adjustment"))
        #expect(yaml.contains("- path: KnittingCalculator/LaunchScreen.storyboard"))
        #expect(yaml.contains("- path: KnittingCalculatorTests"))
        #expect(!yaml.contains("postGenCommand"))
        #expect(!yaml.contains("path: KnittingCalculator/KnittingCalculator/"))
    }

    @Test
    func generatedIndependentProjectContainsOwnedResourcesAndNoKnitNoteProducts() throws {
        let project = try source("KnittingCalculator.xcodeproj/project.pbxproj")

        #expect(project.contains("productName = KnittingCalculator;"))
        #expect(project.contains("productName = KnittingCalculatorTests;"))
        #expect(project.contains("LaunchScreen.storyboard in Resources"))
        #expect(project.contains("PrivacyInfo.xcprivacy in Resources"))
        #expect(project.contains("Localizable.xcstrings in Resources"))
        #expect(project.contains("InfoPlist.xcstrings in Resources"))
        #expect(project.contains("XCLocalSwiftPackageReference"))
        #expect(project.contains("relativePath = Packages/KnittingCalculatorCore;"))
        #expect(project.contains("INFOPLIST_FILE = KnittingCalculator/Info.plist;"))
        #expect(!project.contains("KnittingCalculator/KnittingCalculator/"))
        #expect(!project.contains("KnitNoteWatch"))
        #expect(!project.contains("KnitNoteShare"))
        #expect(!project.contains("KnitNote-iOS.entitlements"))
        #expect(!project.contains("StoreKit"))
    }

    private func targetNames(in yaml: String) -> [String] {
        guard let targets = yaml.split(separator: "targets:", maxSplits: 1).last,
              let schemes = targets.split(separator: "schemes:", maxSplits: 1).first
        else {
            return []
        }

        return schemes.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("  "),
                  !line.hasPrefix("    "),
                  line.hasSuffix(":")
            else {
                return nil
            }
            return String(line.dropFirst(2).dropLast())
        }
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: path),
            encoding: .utf8
        )
    }
}
