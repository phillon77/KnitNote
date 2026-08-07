import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case german = "de"
    case french = "fr"
    case japanese = "ja"
    case norwegianBokmal = "nb"
    case swedish = "sv"
    case finnish = "fi"
    case danish = "da"
    case korean = "ko"
    case greek = "el"
}

public enum LanguageSelection: String, CaseIterable, Codable, Sendable {
    case system
    case traditionalChinese
    case simplifiedChinese
    case english
    case german
    case french
    case japanese
    case norwegianBokmal
    case swedish
    case finnish
    case danish
    case korean
    case greek

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
        case .norwegianBokmal:
            .norwegianBokmal
        case .swedish:
            .swedish
        case .finnish:
            .finnish
        case .danish:
            .danish
        case .korean:
            .korean
        case .greek:
            .greek
        }
    }

    public var localizationKey: String {
        switch self {
        case .system: "language.system"
        case .traditionalChinese: "language.traditionalChinese"
        case .simplifiedChinese: "language.simplifiedChinese"
        case .english: "language.english"
        case .german: "language.german"
        case .french: "language.french"
        case .japanese: "language.japanese"
        case .norwegianBokmal: "language.norwegianBokmal"
        case .swedish: "language.swedish"
        case .finnish: "language.finnish"
        case .danish: "language.danish"
        case .korean: "language.korean"
        case .greek: "language.greek"
        }
    }
}
