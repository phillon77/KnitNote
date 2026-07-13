import Foundation

public final class LanguageSettings {
    public var selection: LanguageSelection

    public init(selection: LanguageSelection = .system) {
        self.selection = selection
    }

    public func resolvedLanguage(
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        switch selection {
        case .english:
            return .english
        case .traditionalChinese:
            return .traditionalChinese
        case .system:
            guard let first = systemLanguages.first?.lowercased() else {
                return .english
            }
            return first.hasPrefix("zh-hant") ? .traditionalChinese : .english
        }
    }
}
