import Foundation

public struct LanguageSelectionProjection {
    public static let appGroupIdentifier = "group.com.phillon.KnitNote"
    public static let selectionKey = "languageSelection"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func live() -> LanguageSelectionProjection? {
        UserDefaults(suiteName: appGroupIdentifier).map(Self.init(defaults:))
    }

    public func write(_ selection: LanguageSelection) {
        defaults.set(selection.rawValue, forKey: Self.selectionKey)
    }

    public func readSelection() -> LanguageSelection {
        defaults.string(forKey: Self.selectionKey)
            .flatMap(LanguageSelection.init(rawValue:)) ?? .system
    }

    public func resolvedLocale(
        systemLanguages: [String] = Locale.preferredLanguages,
        regionLocale: Locale = .current
    ) -> Locale {
        LanguageSettings(selection: readSelection()).resolvedLocale(
            systemLanguages: systemLanguages,
            regionLocale: regionLocale
        )
    }
}
