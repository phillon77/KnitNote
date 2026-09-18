import Foundation

enum ShortRowStrings {
    static func text(_ key: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier
        let traditionalChinese = language == "zh" &&
            (locale.language.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(locale.region?.identifier ?? ""))
        let identifier = traditionalChinese ? "zh-Hant" : "en"
        guard let path = Bundle.module.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, locale: Locale, _ arguments: CVarArg...) -> String {
        String(format: text(key, locale: locale), locale: locale, arguments: arguments)
    }
}

/// Navigation labels come from the same resource bundle as the tool screen.
public enum ShortRowTool {
    public static func title(locale: Locale) -> String {
        ShortRowStrings.text("title", locale: locale)
    }

    public static func summary(locale: Locale) -> String {
        ShortRowStrings.text("subtitle", locale: locale)
    }
}
