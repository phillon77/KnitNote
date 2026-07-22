import Foundation
import Testing
@testable import KnitNoteCore

@Test func projectsHomeUsesThePaintingSurfaceWithoutRestoringTheHeroBanner() throws {
    let source = try appSource("KnitNote/Projects/ProjectsView.swift")

    #expect(!source.contains("FamilyHeroView()"))
    #expect(source.contains("ProjectsPaintingBackground()"))
    #expect(!source.contains("WatercolorBackground()"))

    let background = try #require(source.range(of: "ProjectsPaintingBackground()"))
    let scrollView = try #require(source.range(of: "ScrollView {"))
    #expect(background.lowerBound < scrollView.lowerBound)
}

@Test func otherPrimaryScreensKeepTheGenericWatercolorBackground() throws {
    let paths = [
        "KnitNote/Projects/ProjectDetailView.swift",
        "KnitNote/Patterns/PatternLibraryView.swift",
        "KnitNote/Yarn/YarnLibraryView.swift",
        "KnitNote/Settings/SettingsView.swift"
    ]

    for path in paths {
        #expect(try appSource(path).contains("WatercolorBackground()"), "Missing generic background in \(path)")
    }
}

@Test func projectsPaintingBackgroundUsesTheApprovedArtworkAndVeil() throws {
    let source = try appSource("KnitNote/Theme/WatercolorSurfaces.swift")
    let start = try #require(source.range(of: "struct ProjectsPaintingBackground: View"))
    let end = try #require(source.range(of: "struct WatercolorCard", range: start.upperBound..<source.endIndex))
    let background = String(source[start.lowerBound..<end.lowerBound])

    #expect(background.contains("WatercolorBackground()"))
    #expect(background.contains("Image(\"FamilyKnittingHero\")"))
    #expect(background.contains(".scaledToFill()"))
    #expect(background.contains(".opacity(0.30)"))
    #expect(background.contains("WatercolorTheme.background.opacity(0.72)"))
    #expect(background.contains("WatercolorTheme.background.opacity(0.50)"))
    #expect(background.contains("WatercolorTheme.background.opacity(0.32)"))
    #expect(background.contains(".ignoresSafeArea()"))
    #expect(background.contains(".allowsHitTesting(false)"))
    #expect(background.contains(".accessibilityHidden(true)"))
}

@Test func watercolorPaletteUsesAccessibleActionInk() {
    #expect(WatercolorPalette.actionBerry.hex == 0x9A3F70)
    #expect(WatercolorPalette.ink.hex == 0x33405C)
    #expect(WatercolorPalette.softWhite.hex == 0xFFFDFB)
}

@Test func familyHeroUsesShortPhoneAndWidePadLayouts() {
    #expect(familyHeroLayout(width: 390, isPad: false) == .phone(height: 150))
    #expect(familyHeroLayout(width: 1024, isPad: true) == .wide(height: 300))
}

@Test func familyHeroImageHeightNeverExceedsItsContainer() {
    #expect(familyHeroMaximumImageHeight(proposedHeight: 300, containerHeight: 150) == 150)
    #expect(familyHeroMaximumImageHeight(proposedHeight: 300, containerHeight: 300) == 300)
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
