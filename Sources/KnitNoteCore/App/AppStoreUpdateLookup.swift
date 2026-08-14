import Foundation

public enum AppStorePlatform: Sendable {
    case iPhone
    case iPad
    case macOS
}

public struct AvailableAppUpdate: Equatable, Sendable, Identifiable {
    public var id: AppVersion { version }
    public let version: AppVersion
    public let displayVersion: String
    public let storeURL: URL

    public init(version: AppVersion, displayVersion: String, storeURL: URL) {
        self.version = version
        self.displayVersion = displayVersion
        self.storeURL = storeURL
    }
}

public struct AppUpdateHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public struct AppStoreUpdateLookup: Sendable {
    typealias Fetcher = @Sendable (
        _ countryCode: String?,
        _ platform: AppStorePlatform
    ) async -> AvailableAppUpdate?

    private let fetcher: Fetcher

    init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    public func fetch(countryCode: String?, platform: AppStorePlatform) async -> AvailableAppUpdate? {
        await fetcher(countryCode, platform)
    }

    public static func normalizedCountryCode(_ candidate: String?) -> String? {
        guard
            let candidate,
            candidate.utf8.count == 2,
            candidate.utf8.allSatisfy({ byte in
                (65...90).contains(byte) || (97...122).contains(byte)
            })
        else {
            return nil
        }
        return candidate.lowercased()
    }

    public static func alpha2CountryCode(storefrontCountryCode: String?) -> String? {
        guard let storefrontCountryCode else { return nil }
        return switch storefrontCountryCode {
        case "TWN": "tw"
        case "USA": "us"
        case "JPN": "jp"
        case "DEU": "de"
        default: nil
        }
    }
}
