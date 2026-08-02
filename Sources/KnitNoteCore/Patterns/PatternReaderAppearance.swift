import Foundation

public enum PatternSystemAppearance: Equatable, Sendable {
    case unresolved
    case light
    case dark
}

public enum PatternReaderAppearancePolicy: Sendable {
    public static func usesNightRendering(
        systemAppearance: PatternSystemAppearance,
        prefersOriginalColorsInDarkMode: Bool
    ) -> Bool {
        systemAppearance == .dark && !prefersOriginalColorsInDarkMode
    }
}
