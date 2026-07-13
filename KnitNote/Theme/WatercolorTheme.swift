import SwiftUI

extension Color {
    init(theme value: ThemeRGB) {
        let red = Double((value.hex >> 16) & 0xFF) / 255
        let green = Double((value.hex >> 8) & 0xFF) / 255
        let blue = Double(value.hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue)
    }
}

enum WatercolorTheme {
    static let sky = Color(theme: WatercolorPalette.sky)
    static let lavender = Color(theme: WatercolorPalette.lavender)
    static let berry = Color(theme: WatercolorPalette.berry)
    static let actionBerry = Color(theme: WatercolorPalette.actionBerry)
    static let flower = Color(theme: WatercolorPalette.flower)
    static let softWhite = Color(theme: WatercolorPalette.softWhite)
    static let ink = Color(theme: WatercolorPalette.ink)
    static let background = Color(theme: WatercolorPalette.background)
}
