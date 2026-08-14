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
    public typealias Loader = @Sendable (URLRequest) async throws -> AppUpdateHTTPResponse

    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func fetch(countryCode: String?, platform: AppStorePlatform) async -> AvailableAppUpdate? {
        do {
            let response = try await loader(
                AppStoreUpdateLiveNetworkContract.request(countryCode: countryCode)
            )
            guard (200...299).contains(response.statusCode) else { return nil }

            let payload = try JSONDecoder().decode(LookupPayload.self, from: response.data)
            guard payload.resultCount == 1, payload.results.count == 1, let result = payload.results.first else {
                return nil
            }
            guard
                result.trackID == AppStoreUpdateLiveNetworkContract.appleID,
                result.bundleID == AppStoreUpdateLiveNetworkContract.bundleID
            else {
                return nil
            }
            guard
                let displayVersion = result.version,
                let version = AppVersion(displayVersion),
                let storeURLString = result.trackViewURL,
                let storeURL = AppStoreUpdateLiveNetworkContract.validStoreURL(
                    storeURLString
                ),
                Self.supports(platform: platform, devices: result.supportedDevices)
            else {
                return nil
            }

            return AvailableAppUpdate(
                version: version,
                displayVersion: displayVersion,
                storeURL: storeURL
            )
        } catch {
            return nil
        }
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

    private static func supports(platform: AppStorePlatform, devices: [String]) -> Bool {
        switch platform {
        case .iPhone:
            devices.contains { $0.hasPrefix("iPhone") }
        case .iPad:
            devices.contains { $0.hasPrefix("iPad") }
        case .macOS:
            devices.contains { $0 == "MacDesktop-MacDesktop" || $0.hasPrefix("Mac") }
        }
    }
}

private struct LookupPayload: Decodable {
    let resultCount: Int
    let results: [LookupResult]
}

private struct LookupResult: Decodable {
    let trackID: Int
    let bundleID: String
    let version: String?
    let trackViewURL: String?
    let supportedDevices: [String]

    private enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case bundleID = "bundleId"
        case version
        case trackViewURL = "trackViewUrl"
        case supportedDevices
    }
}
