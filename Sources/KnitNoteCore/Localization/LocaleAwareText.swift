import Foundation

public enum LocaleAwareText {
    public static func string(
        _ key: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let selected = resolve(key, locale: locale, bundle: bundle)
        guard selected == key else { return selected }
        return resolve(key, locale: englishLocale, bundle: bundle)
    }

    public static func format(
        _ key: String,
        locale: Locale,
        bundle: Bundle = .main,
        _ arguments: any CVarArg...
    ) -> String {
        let format = string(key, locale: locale, bundle: bundle)
        return String(format: format, locale: locale, arguments: arguments)
    }

    public static func interpolated(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let selected = resolve(
            key,
            defaultValue: defaultValue,
            locale: locale,
            bundle: bundle
        )
        let defaultRendered = String(
            localized: defaultValue,
            table: "__KnitNoteMissingLocalization__",
            bundle: bundle,
            locale: locale,
            comment: ""
        )
        let keyString = String(describing: key)
        guard selected == keyString
                || selected == defaultRendered
                || selected == "(null)"
                || selected.contains("%#@")
        else {
            return selected
        }
        return resolve(
            key,
            defaultValue: defaultValue,
            locale: englishLocale,
            bundle: bundle
        )
    }

    public static func byteCount(_ bytes: Int64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    private static let englishLocale = Locale(identifier: "en")

    private static func resolve(
        _ key: String,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        let resource = LocalizedStringResource(
            String.LocalizationValue(key),
            locale: locale,
            bundle: .atURL(bundle.bundleURL)
        )
        return String(localized: resource)
    }

    private static func resolve(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        let resource = LocalizedStringResource(
            key,
            defaultValue: defaultValue,
            locale: locale,
            bundle: .atURL(bundle.bundleURL)
        )
        return String(localized: resource)
    }
}

public enum LocalizedMessage: Equatable, Sendable {
    case key(String)

    public func resolved(
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        switch self {
        case let .key(key):
            LocaleAwareText.string(key, locale: locale, bundle: bundle)
        }
    }
}
