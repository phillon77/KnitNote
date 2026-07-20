import Foundation
import Testing
@testable import KnitNoteCore

@Test func projectsHomeRemovesPaintingButKeepsWatercolorTheme() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent("KnitNote/Projects/ProjectsView.swift"),
        encoding: .utf8
    )

    #expect(!source.contains("FamilyHeroView()"))
    #expect(source.contains("WatercolorBackground()"))
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
