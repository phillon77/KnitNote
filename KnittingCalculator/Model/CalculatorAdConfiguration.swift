import Foundation

enum CalculatorAdConfiguration: Equatable {
    case disabled
    case test
    case live(bannerUnitID: String)

    var bannerUnitID: String? {
        switch self {
        case .disabled: nil
        case .test: "ca-app-pub-3940256099942544/2934735716"
        case .live(let id): id
        }
    }

    static var current: Self {
#if DEBUG
        let isDebug = true
#else
        let isDebug = false
#endif
        return resolve(
            isDebug: isDebug,
            arguments: ProcessInfo.processInfo.arguments,
            info: Bundle.main.infoDictionary ?? [:],
            isTesting: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || NSClassFromString("XCTestCase") != nil
        )
    }

    static func resolve(isDebug: Bool, arguments: [String], info: [String: Any], isTesting: Bool) -> Self {
        guard !isTesting, !arguments.contains("-storeScreenshotMode") else { return .disabled }
        if isDebug {
            return arguments.contains("-calculatorTestAds") && !arguments.contains("-calculatorBannerPreview")
                ? .test : .disabled
        }
        guard (info["CalculatorAdsReady"] as? String == "YES" || info["CalculatorAdsReady"] as? Bool == true),
              let appID = info["GADApplicationIdentifier"] as? String,
              let unitID = info["CalculatorBannerAdUnitID"] as? String,
              appID.range(of: #"^ca-app-pub-[0-9]{16}~[0-9]{10}$"#, options: .regularExpression) != nil,
              unitID.range(of: #"^ca-app-pub-[0-9]{16}/[0-9]{10}$"#, options: .regularExpression) != nil,
              !appID.hasPrefix("ca-app-pub-3940256099942544"),
              appID.split(separator: "~").first == unitID.split(separator: "/").first else { return .disabled }
        return .live(bannerUnitID: unitID)
    }
}
