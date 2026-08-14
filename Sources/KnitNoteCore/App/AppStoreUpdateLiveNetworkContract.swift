import Foundation

public struct AppStoreUpdateLookup: Sendable {
    fileprivate typealias Fetcher = @Sendable (
        _ countryCode: String?,
        _ platform: AppStorePlatform
    ) async -> AvailableAppUpdate?

    private let fetcher: Fetcher

    fileprivate init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    public func fetch(
        countryCode: String?,
        platform: AppStorePlatform
    ) async -> AvailableAppUpdate? {
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

    public static func alpha2CountryCode(
        storefrontCountryCode: String?
    ) -> String? {
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

enum AppStoreUpdateLiveNetworkContract {
    typealias Loader = @Sendable (URLRequest) async throws -> AppUpdateHTTPResponse

    private static let appleID = 6_793_023_054
    private static let bundleID = "com.phillon.KnitNote"
    private static let defaultCountryCode = "tw"
    private static let lookupHost = "itunes.apple.com"
    private static let lookupPath = "/lookup"
    private static let storeHost = "apps.apple.com"

    private static func request(countryCode: String?) -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = lookupHost
        components.path = lookupPath
        components.queryItems = [
            URLQueryItem(name: "id", value: String(appleID)),
            URLQueryItem(
                name: "country",
                value: AppStoreUpdateLookup.normalizedCountryCode(countryCode)
                    ?? defaultCountryCode
            ),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    private static func validStoreURL(_ string: String) -> URL? {
        guard
            let components = URLComponents(string: string),
            components.scheme == "https",
            components.host == storeHost,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            let url = components.url
        else {
            return nil
        }

        let path = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            path.count == 5,
            path[0].isEmpty,
            AppStoreUpdateLookup.normalizedCountryCode(String(path[1])) != nil,
            path[2] == "app",
            !path[3].isEmpty,
            path[4] == Substring("id\(appleID)")
        else {
            return nil
        }
        return url
    }

    static func debugFixtureStoreURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = storeHost
        components.path = "/tw/app/id\(appleID)"
        return components.url
    }

    static func testLookup(loader: @escaping Loader) -> AppStoreUpdateLookup {
        AppStoreUpdateLookup(fetcher: fetcher(loader: loader))
    }

    fileprivate static func fetcher(
        loader: @escaping Loader
    ) -> AppStoreUpdateLookup.Fetcher {
        { countryCode, platform in
            await fetch(
                loader: loader,
                countryCode: countryCode,
                platform: platform
            )
        }
    }

    private static func fetch(
        loader: Loader,
        countryCode: String?,
        platform: AppStorePlatform
    ) async -> AvailableAppUpdate? {
        do {
            let response = try await loader(request(countryCode: countryCode))
            guard (200...299).contains(response.statusCode) else { return nil }

            let payload = try JSONDecoder().decode(LookupPayload.self, from: response.data)
            guard
                payload.resultCount == 1,
                payload.results.count == 1,
                let result = payload.results.first,
                result.trackID == appleID,
                result.bundleID == bundleID,
                let displayVersion = result.version,
                let version = AppVersion(displayVersion),
                let storeURLString = result.trackViewURL,
                let storeURL = validStoreURL(storeURLString),
                supports(platform: platform, devices: result.supportedDevices)
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

    fileprivate static func loader(timeout: TimeInterval) -> Loader {
        let configuration = sessionConfiguration(timeout: timeout)
        let session = URLSession(configuration: configuration)

        return { request in
            var request = request
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AppStoreUpdateLiveNetworkError.nonHTTPResponse
            }
            return AppUpdateHTTPResponse(data: data, statusCode: response.statusCode)
        }
    }

    static func sessionConfiguration(
        timeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    private static func supports(
        platform: AppStorePlatform,
        devices: [String]
    ) -> Bool {
        switch platform {
        case .iPhone:
            devices.contains { $0.hasPrefix("iPhone") }
        case .iPad:
            devices.contains { $0.hasPrefix("iPad") }
        case .macOS:
            devices.contains {
                $0 == "MacDesktop-MacDesktop" || $0.hasPrefix("Mac")
            }
        }
    }
}

extension AppStoreUpdateLookup {
    public static func live(timeout: TimeInterval = 8) -> Self {
        let loader = AppStoreUpdateLiveNetworkContract.loader(timeout: timeout)
        return Self(
            fetcher: AppStoreUpdateLiveNetworkContract.fetcher(loader: loader)
        )
    }

    static func liveSessionConfiguration(
        timeout: TimeInterval
    ) -> URLSessionConfiguration {
        AppStoreUpdateLiveNetworkContract.sessionConfiguration(timeout: timeout)
    }
}

private enum AppStoreUpdateLiveNetworkError: Error {
    case nonHTTPResponse
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
