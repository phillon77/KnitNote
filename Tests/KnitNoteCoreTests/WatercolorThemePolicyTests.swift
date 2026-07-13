import Testing
@testable import KnitNoteCore

@Test func watercolorPaletteUsesAccessibleActionInk() {
    #expect(WatercolorPalette.actionBerry.hex == 0x9A3F70)
    #expect(WatercolorPalette.ink.hex == 0x33405C)
    #expect(WatercolorPalette.softWhite.hex == 0xFFFDFB)
}

@Test func familyHeroUsesShortPhoneAndWidePadLayouts() {
    #expect(familyHeroLayout(width: 390, isPad: false) == .phone(height: 150))
    #expect(familyHeroLayout(width: 1024, isPad: true) == .wide(height: 300))
}
