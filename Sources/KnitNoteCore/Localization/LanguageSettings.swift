import Foundation

public final class LanguageSettings {
    public var selection: LanguageSelection

    public init(selection: LanguageSelection = .system) {
        self.selection = selection
    }

    public func resolvedLanguage(
        systemLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        if let explicitLanguage = selection.explicitLanguage {
            return explicitLanguage
        }

        guard let identifier = systemLanguages.first else {
            return .english
        }

        let subtags = identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)

        guard let languageCode = subtags.first?.lowercased() else {
            return .english
        }

        if languageCode == "zh" {
            let chineseSubtags = subtags.dropFirst()
            if chineseSubtags.contains(where: { $0.caseInsensitiveCompare("Hant") == .orderedSame }) {
                return .traditionalChinese
            }
            if chineseSubtags.contains(where: { $0.caseInsensitiveCompare("Hans") == .orderedSame }) {
                return .simplifiedChinese
            }
            if chineseSubtags.contains(where: { ["TW", "HK", "MO"].contains($0.uppercased()) }) {
                return .traditionalChinese
            }
            if chineseSubtags.contains(where: { ["CN", "SG"].contains($0.uppercased()) }) {
                return .simplifiedChinese
            }
        }

        switch languageCode {
        case "de": return .german
        case "fr": return .french
        case "ja": return .japanese
        case "en": return .english
        default: return .english
        }
    }

    public func resolvedLocale(
        systemLanguages: [String] = Locale.preferredLanguages,
        regionLocale: Locale = .current
    ) -> Locale {
        let language = resolvedLanguage(systemLanguages: systemLanguages)
        guard let region = regionLocale.region?.identifier else {
            return Locale(identifier: language.rawValue)
        }
        return Locale(identifier: "\(language.rawValue)_\(region)")
    }
}
