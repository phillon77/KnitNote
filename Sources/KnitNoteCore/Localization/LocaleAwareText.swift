import Foundation

public enum LocaleAwareText {
    public static func string(
        _ key: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let resource = LocalizedStringResource(
            String.LocalizationValue(key),
            locale: locale,
            bundle: .atURL(bundle.bundleURL)
        )
        return String(localized: resource)
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
        let resource = LocalizedStringResource(
            key,
            defaultValue: defaultValue,
            locale: locale,
            bundle: .atURL(bundle.bundleURL)
        )
        return String(localized: resource)
    }

    public static func byteCount(_ bytes: Int64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
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
