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
