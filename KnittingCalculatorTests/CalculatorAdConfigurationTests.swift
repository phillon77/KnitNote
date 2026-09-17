import XCTest
@testable import KnittingCalculator

final class CalculatorAdConfigurationTests: XCTestCase {
    private let liveInfo: [String: Any] = [
        "CalculatorAdsReady": true,
        "GADApplicationIdentifier": "ca-app-pub-1234567890123456~1234567890",
        "CalculatorBannerAdUnitID": "ca-app-pub-1234567890123456/1234567890",
    ]

    func testNormalDebugLaunchNeverRequestsLiveAds() {
        XCTAssertEqual(resolve(debug: true, info: liveInfo), .disabled)
        XCTAssertEqual(
            resolve(debug: true, args: ["app", "-calculatorTestAds"], info: liveInfo),
            .test
        )
    }

    func testScreenshotAndTestProcessesNeverEnableAds() {
        for debug in [true, false] {
            XCTAssertEqual(resolve(debug: debug, args: ["app", "-calculatorTestAds", "-storeScreenshotMode", "YES"], info: liveInfo), .disabled)
            XCTAssertEqual(resolve(debug: debug, info: liveInfo, testing: true), .disabled)
        }
    }

    func testReleaseRequiresReadinessAndValidMatchingPublisherIDs() {
        XCTAssertEqual(resolve(debug: false), .disabled)
        var info = liveInfo
        info["CalculatorAdsReady"] = false
        XCTAssertEqual(resolve(debug: false, info: info), .disabled)
        info = liveInfo
        info["CalculatorBannerAdUnitID"] = "$(CALCULATOR_BANNER_ID)"
        XCTAssertEqual(resolve(debug: false, info: info), .disabled)
        info["CalculatorBannerAdUnitID"] = "ca-app-pub-9999999999999999/1234567890"
        XCTAssertEqual(resolve(debug: false, info: info), .disabled)
        XCTAssertEqual(resolve(debug: false, info: liveInfo).bannerUnitID, "ca-app-pub-1234567890123456/1234567890")
    }

    func testReleaseRejectsGoogleSampleIDsEvenWithReadinessEnabled() {
        var info = liveInfo
        info["GADApplicationIdentifier"] = "ca-app-pub-3940256099942544~1458002511"
        info["CalculatorBannerAdUnitID"] = "ca-app-pub-3940256099942544/2934735716"
        XCTAssertEqual(resolve(debug: false, args: ["app", "-calculatorTestAds"], info: info), .disabled)
    }

    func testPreviewDoesNotEnableNetworking() {
        XCTAssertEqual(resolve(debug: true, args: ["app", "-calculatorBannerPreview"], info: liveInfo), .disabled)
    }

    private func resolve(debug: Bool, args: [String] = ["app"], info: [String: Any] = [:], testing: Bool = false) -> CalculatorAdConfiguration {
        CalculatorAdConfiguration.resolve(isDebug: debug, arguments: args, info: info, isTesting: testing)
    }
}
