import Foundation
import Testing

@Suite struct PatternCalculatorViewContractTests {
    @Test func panelUsesOneBoundStateAndTheApprovedKeys() throws {
        let source = try appSource("KnitNote/Patterns/PatternCalculatorView.swift")
        #expect(source.contains("@Binding var state: PatternCalculatorState"))
        #expect(source.contains("state.press(key)"))
        for token in [".clear", ".toggleSign", ".percent", ".divide", ".multiply", ".subtract", ".add", ".decimal", ".equals"] {
            #expect(source.contains(token))
        }
        #expect(!source.contains("JSONProjectStore"))
        #expect(!source.contains("UserDefaults"))
    }

    @Test func panelKeepsReadableInkAndAdaptiveKeySurfacesInDarkMode() throws {
        let source = try appSource("KnitNote/Patterns/PatternCalculatorView.swift")
        #expect(source.contains(".foregroundStyle(WatercolorTheme.ink)"))
        #expect(source.contains("WatercolorTheme.softWhite.opacity(0.88)"))
        #expect(!source.contains(".white.opacity(0.72)"))
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
