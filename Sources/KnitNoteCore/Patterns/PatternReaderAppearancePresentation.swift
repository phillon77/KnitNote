public struct PatternNightRenderingConfiguration: Equatable, Sendable {
    public enum PageSurfaceColor: Equatable, Sendable {
        case white
    }

    public let pageSurfaceColor: PageSurfaceColor = .white
    public let pageSurfaceOpacity: Double = 1
    public let contrastAmount: Double
    public let hueRotationDegrees: Double

    public init(isActive: Bool) {
        contrastAmount = isActive ? -1 : 1
        hueRotationDegrees = isActive ? 180 : 0
    }
}

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
