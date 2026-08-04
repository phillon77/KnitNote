import Foundation

public struct AppVersionInfo: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public init?(infoDictionary: [String: Any]) {
        guard
            let rawVersion = infoDictionary["CFBundleShortVersionString"] as? String,
            let rawBuild = infoDictionary["CFBundleVersion"] as? String
        else { return nil }

        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = rawBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !build.isEmpty else { return nil }

        self.init(version: version, build: build)
    }

    public static func current(in bundle: Bundle = .main) -> AppVersionInfo? {
        guard let dictionary = bundle.infoDictionary else { return nil }
        return AppVersionInfo(infoDictionary: dictionary)
    }
}

public enum AppVersionDisplayFormatter {
    public static func string(
        for versionInfo: AppVersionInfo?,
        bundle: Bundle = .main,
        locale: Locale
    ) -> String {
        guard let versionInfo else { return "—" }
        let version = versionInfo.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = versionInfo.build.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !build.isEmpty else { return "—" }

        let format = localizedFormat(in: bundle, locale: locale)
        return String(
            format: format,
            locale: locale,
            version,
            build
        )
    }

    private static func localizedFormat(in bundle: Bundle, locale: Locale) -> String {
        let localization = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: [locale.identifier]
        ).first

        guard
            let localization,
            let localizationURL = bundle.url(forResource: localization, withExtension: "lproj"),
            let localizationBundle = Bundle(url: localizationURL)
        else {
            return bundle.localizedString(
                forKey: "settings.version.format",
                value: nil,
                table: nil
            )
        }

        return localizationBundle.localizedString(
            forKey: "settings.version.format",
            value: nil,
            table: nil
        )
    }
}
