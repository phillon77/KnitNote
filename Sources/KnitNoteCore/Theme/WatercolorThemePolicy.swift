import Foundation

public struct ThemeRGB: Equatable, Sendable {
    public let hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex }
}

public enum WatercolorPalette {
    public static let sky = ThemeRGB(0x9FC7F6)
    public static let lavender = ThemeRGB(0xB9A9E8)
    public static let berry = ThemeRGB(0xC86498)
    public static let actionBerry = ThemeRGB(0x9A3F70)
    public static let flower = ThemeRGB(0xF4D46A)
    public static let softWhite = ThemeRGB(0xFFFDFB)
    public static let ink = ThemeRGB(0x33405C)
    public static let background = ThemeRGB(0xF4F2FF)
}

public enum FamilyHeroLayout: Equatable, Sendable {
    case phone(height: Double)
    case wide(height: Double)
}

public func familyHeroLayout(width: Double, isPad: Bool) -> FamilyHeroLayout {
    isPad || width >= 700 ? .wide(height: 300) : .phone(height: 150)
}

public func familyHeroMaximumImageHeight(
    proposedHeight: Double,
    containerHeight: Double
) -> Double {
    min(proposedHeight, containerHeight)
}
