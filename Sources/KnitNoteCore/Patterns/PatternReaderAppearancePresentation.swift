public struct PatternReaderAppearancePresentation: Equatable, Sendable {
    public enum ReaderChrome: Equatable, Sendable {
        case light
        case dark
    }

    public enum ToggleIntent: Equatable, Sendable {
        case showOriginalColors
        case restoreNightAppearance
    }

    public enum AccessibilityHint: Equatable, Sendable {
        case lightAppearance
        case darkAppearance
    }

    public let usesNightRendering: Bool
    public let readerChrome: ReaderChrome
    public let toggleIntent: ToggleIntent
    public let accessibilityHint: AccessibilityHint

    public init(
        systemAppearance: PatternSystemAppearance,
        prefersOriginalColorsInDarkMode: Bool
    ) {
        usesNightRendering = PatternReaderAppearancePolicy.usesNightRendering(
            systemAppearance: systemAppearance,
            prefersOriginalColorsInDarkMode: prefersOriginalColorsInDarkMode
        )
        readerChrome = systemAppearance == .dark ? .dark : .light
        toggleIntent = prefersOriginalColorsInDarkMode
            ? .restoreNightAppearance
            : .showOriginalColors
        accessibilityHint = systemAppearance == .dark ? .darkAppearance : .lightAppearance
    }
}
