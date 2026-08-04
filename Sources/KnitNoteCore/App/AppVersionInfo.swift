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
