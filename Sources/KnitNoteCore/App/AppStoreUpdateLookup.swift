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
