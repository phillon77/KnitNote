import Foundation
import Testing

@Suite struct KnittingCalculatorProjectContractTests {
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

    @Test func freeAppCompilesOnlyCalculatorCoreFiles() throws {
        let yaml = try source("project.yml")
        for path in [
            "Sources/KnitNoteCore/Calculators/GaugeCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentCalculator.swift",
            "Sources/KnitNoteCore/Calculators/EvenStitchAdjustmentInputParser.swift",
            "Sources/KnitNoteCore/Calculators/RowIntervalAdjustmentCalculator.swift",
        ] {
            #expect(yaml.contains("- path: \(path)"))
        }
        let target = try #require(
            yaml.split(separator: "  KnittingCalculatorTests:").first?
                .split(separator: "  KnittingCalculator:").last
        )
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
