import Foundation

enum AppStoreUpdateLiveNetworkContract {
    static let appleID = 6_793_023_054
    static let bundleID = "com.phillon.KnitNote"
    private static let defaultCountryCode = "tw"
    private static let lookupHost = "itunes.apple.com"
    private static let lookupPath = "/lookup"
    private static let storeHost = "apps.apple.com"

    static func request(countryCode: String?) -> URLRequest {
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

    static func validStoreURL(_ string: String) -> URL? {
        guard
            let components = URLComponents(string: string),
            components.scheme == "https",
            components.host == storeHost,
            let url = components.url
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

    static func loader(timeout: TimeInterval) -> AppStoreUpdateLookup.Loader {
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
}

extension AppStoreUpdateLookup {
    public static func live(timeout: TimeInterval = 8) -> Self {
        Self(loader: AppStoreUpdateLiveNetworkContract.loader(timeout: timeout))
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
