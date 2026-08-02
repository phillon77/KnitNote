import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderAppearanceTests {
    @Test func nightRenderingRequiresDarkSystemAndNoOriginalColorOverride() {
        #expect(!PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .unresolved,
            prefersOriginalColorsInDarkMode: false
        ))
        #expect(!PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .light,
            prefersOriginalColorsInDarkMode: false
        ))
        #expect(PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .dark,
            prefersOriginalColorsInDarkMode: false
        ))
        #expect(!PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: .dark,
            prefersOriginalColorsInDarkMode: true
        ))
    }

    @Test func legacyPatternWithoutAppearancePreferenceDefaultsToNightInDarkMode() throws {
        let assetID = UUID()
        let patternID = UUID()
        let data = Data("""
        {
          "id":"\(patternID.uuidString)",
          "assetID":"\(assetID.uuidString)",
          "displayName":"Legacy",
          "createdAt":0
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(StoredPattern.self, from: data)
        #expect(!decoded.prefersOriginalColorsInDarkMode)
    }

    @Test func patternAppearancePreferenceRoundTrips() throws {
        let pattern = StoredPattern(
            assetID: UUID(),
            displayName: "Color chart",
            prefersOriginalColorsInDarkMode: true
        )
        let decoded = try JSONDecoder().decode(
            StoredPattern.self,
            from: JSONEncoder().encode(pattern)
        )
        #expect(decoded == pattern)
        #expect(decoded.prefersOriginalColorsInDarkMode)
    }
}
