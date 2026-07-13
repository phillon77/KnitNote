import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
}

public enum LanguageSelection: String, CaseIterable, Codable, Sendable {
    case system
    case english
    case traditionalChinese
}
