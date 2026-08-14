import Foundation

struct AppUpdateFixture: Equatable, Sendable {
    let availableUpdate: AvailableAppUpdate

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppUpdateFixtureResolution {
        let requestsFixture = arguments.contains("-appUpdateFixture")
            || arguments.contains("-appUpdateFixtureVersion")
        guard requestsFixture else { return .notRequested }

#if DEBUG
        guard !arguments.contains("-storeScreenshotMode"),
              arguments.occurrences(of: "-appUpdateFixture") == 1,
              arguments.occurrences(of: "-appUpdateFixtureVersion") == 1,
              argumentValue(after: "-appUpdateFixture", in: arguments) == "YES",
              let rawVersion = argumentValue(
                after: "-appUpdateFixtureVersion",
                in: arguments
              ),
              let version = AppVersion(rawVersion),
              let storeURL = AppStoreUpdateLiveNetworkContract
                .debugFixtureStoreURL() else {
            return .invalid
        }
        return .ready(AppUpdateFixture(
            availableUpdate: AvailableAppUpdate(
                version: version,
                displayVersion: rawVersion,
                storeURL: storeURL
            )
        ))
#else
        return .invalid
#endif
    }

    private static func argumentValue(
        after flag: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum AppUpdateFixtureResolution: Equatable {
    case notRequested
    case ready(AppUpdateFixture)
    case invalid
}

private extension Array where Element == String {
    func occurrences(of value: String) -> Int {
        count(where: { $0 == value })
    }
}
