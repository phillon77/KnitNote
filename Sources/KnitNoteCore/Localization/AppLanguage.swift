import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case german = "de"
    case french = "fr"
    case japanese = "ja"
}

public enum LanguageSelection: String, CaseIterable, Codable, Sendable {
    case system
    case traditionalChinese
    case simplifiedChinese
    case english
    case german
    case french
    case japanese

    public var explicitLanguage: AppLanguage? {
        switch self {
        case .system:
            nil
        case .traditionalChinese:
            .traditionalChinese
        case .simplifiedChinese:
            .simplifiedChinese
        case .english:
            .english
        case .german:
            .german
        case .french:
            .french
        case .japanese:
            .japanese
        }
    }
}
