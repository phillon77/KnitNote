import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct AppStoreUpdateLookupTests {
    @Test(arguments: [
        (AppStorePlatform.iPhone, "iPhone17ProMax-iPhone17ProMax", ["iPadAir5-iPadAir5", "MacDesktop-MacDesktop"]),
        (AppStorePlatform.iPad, "iPadAir5-iPadAir5", ["iPhone17ProMax-iPhone17ProMax", "MacDesktop-MacDesktop"]),
        (AppStorePlatform.macOS, "MacDesktop-MacDesktop", ["iPhone17ProMax-iPhone17ProMax", "iPadAir5-iPadAir5"]),
    ])
    func fetchUsesExactLookupRequestAndAcceptsOnlyItsPlatformFamily(
        platform: AppStorePlatform,
        supportedToken: String,
        otherFamilyTokens: [String]
    ) async {
        let capturedRequest = RequestCapture()
        let lookup = AppStoreUpdateLookup { request in
            await capturedRequest.record(request)
            return .init(data: Self.validPayload(supportedDevices: [supportedToken]), statusCode: 200)
        }

        let update = await lookup.fetch(countryCode: "tw", platform: platform)

        let request = await capturedRequest.request
        #expect(request?.url?.absoluteString == "https://itunes.apple.com/lookup?id=6793023054&country=tw")
        #expect(request?.httpMethod == "GET")
        #expect(update?.version == AppVersion("1.5.2"))
        #expect(update?.displayVersion == "1.5.2")
        #expect(update?.storeURL.host == "apps.apple.com")

        for otherFamilyToken in otherFamilyTokens {
            let otherFamilyLookup = AppStoreUpdateLookup { _ in
                .init(data: Self.validPayload(supportedDevices: [otherFamilyToken]), statusCode: 200)
            }
            #expect(await otherFamilyLookup.fetch(countryCode: "tw", platform: platform) == nil)
        }
    }

    @Test(arguments: FailureCase.allCases)
    private func fetchFailsSilentForEveryInvalidResponse(_ failure: FailureCase) async {
        let lookup = AppStoreUpdateLookup { _ in
            try failure.load()
        }

        #expect(await lookup.fetch(countryCode: "tw", platform: .iPhone) == nil)
    }

    @Test(arguments: [
        ("tw", "tw"),
        ("us", "us"),
        ("jp", "jp"),
        ("de", "de"),
    ])
    func requestUsesEachValidCountryCode(candidate: String, expectedCountryCode: String) async {
        let capturedRequest = RequestCapture()
        let lookup = AppStoreUpdateLookup { request in
            await capturedRequest.record(request)
            return .init(data: Self.validPayload(), statusCode: 200)
        }

        _ = await lookup.fetch(countryCode: candidate, platform: .iPhone)

        #expect(await capturedRequest.request?.url?.query == "id=6793023054&country=\(expectedCountryCode)")
    }

    @Test(arguments: ["", "t", "tww", "t!", "t/", "t?", "t#", "t=", "t%", "t&"])
    func invalidCountryCandidatesAreRejectedAndFallBackToTaiwan(candidate: String) async {
        #expect(AppStoreUpdateLookup.normalizedCountryCode(candidate) == nil)

        let capturedRequest = RequestCapture()
        let lookup = AppStoreUpdateLookup { request in
            await capturedRequest.record(request)
            return .init(data: Self.validPayload(), statusCode: 200)
        }
        _ = await lookup.fetch(countryCode: candidate, platform: .iPhone)

        #expect(await capturedRequest.request?.url?.query == "id=6793023054&country=tw")
    }

    @Test func missingCountryCandidateFallsBackToTaiwan() async {
        #expect(AppStoreUpdateLookup.normalizedCountryCode(nil) == nil)

        let capturedRequest = RequestCapture()
        let lookup = AppStoreUpdateLookup { request in
            await capturedRequest.record(request)
            return .init(data: Self.validPayload(), statusCode: 200)
        }
        _ = await lookup.fetch(countryCode: nil, platform: .iPhone)

        #expect(await capturedRequest.request?.url?.query == "id=6793023054&country=tw")
    }

    @Test(arguments: [
        ("TWN", "tw"),
        ("USA", "us"),
        ("JPN", "jp"),
        ("DEU", "de"),
    ])
    func convertsKnownStorefrontCountryCodes(storefrontCountryCode: String, expectedCountryCode: String) {
        #expect(AppStoreUpdateLookup.alpha2CountryCode(storefrontCountryCode: storefrontCountryCode) == expectedCountryCode)
    }

    @Test(arguments: [nil, "", "TWN?", "TWN ", "XXX", "tw", "TWNN"])
    func rejectsUnknownOrMalformedStorefrontCountryCodes(_ storefrontCountryCode: String?) {
        #expect(AppStoreUpdateLookup.alpha2CountryCode(storefrontCountryCode: storefrontCountryCode) == nil)
    }

    private static func validPayload(
        trackID: Int = 6_793_023_054,
        bundleID: String = "com.phillon.KnitNote",
        version: String? = "1.5.2",
        trackViewURL: String? = "https://apps.apple.com/tw/app/knitnote/id6793023054?uo=4",
        supportedDevices: [String] = ["iPhone17ProMax-iPhone17ProMax"],
        resultCount: Int = 1,
        results: String? = nil
    ) -> Data {
        let versionField = version.map { #""version":"\#($0)","# } ?? ""
        let trackViewURLField = trackViewURL.map { #""trackViewUrl":"\#($0)","# } ?? ""
        let supportedDevicesJSON = supportedDevices.map { #""\#($0)""# }.joined(separator: ",")
        let validResult = #"{"trackId":\#(trackID),"bundleId":"\#(bundleID)",\#(versionField)\#(trackViewURLField)"supportedDevices":[\#(supportedDevicesJSON)]}"#
        let resultsJSON = results ?? "[\(validResult)]"
        return Data(#"{"resultCount":\#(resultCount),"results":\#(resultsJSON)}"#.utf8)
    }

    private actor RequestCapture {
        private(set) var request: URLRequest?

        func record(_ request: URLRequest) {
            self.request = request
        }
    }

    private enum FailureCase: CaseIterable, Sendable {
        case http404
        case http500
        case emptyData
        case invalidJSON
        case zeroResultCount
        case multipleResultCount
        case zeroResults
        case duplicateResults
        case nonObjectResult
        case extraResults
        case wrongTrackID
        case wrongBundleID
        case missingVersion
        case malformedVersion
        case insecureStoreURL
        case unrelatedStoreHost
        case deceptiveStoreHost
        case missingStoreURL
        case missingCurrentPlatform
        case offlineError
        case timeoutError
        case cancellationError

        func load() throws -> AppUpdateHTTPResponse {
            switch self {
            case .http404:
                return .init(data: AppStoreUpdateLookupTests.validPayload(), statusCode: 404)
            case .http500:
                return .init(data: AppStoreUpdateLookupTests.validPayload(), statusCode: 500)
            case .emptyData:
                return .init(data: Data(), statusCode: 200)
            case .invalidJSON:
                return .init(data: Data("not json".utf8), statusCode: 200)
            case .zeroResultCount:
                return .init(data: AppStoreUpdateLookupTests.validPayload(resultCount: 0), statusCode: 200)
            case .multipleResultCount:
                return .init(data: AppStoreUpdateLookupTests.validPayload(resultCount: 2), statusCode: 200)
            case .zeroResults:
                return .init(data: AppStoreUpdateLookupTests.validPayload(results: "[]"), statusCode: 200)
            case .duplicateResults:
                let result = #"{"trackId":6793023054,"bundleId":"com.phillon.KnitNote","version":"1.5.2","trackViewUrl":"https://apps.apple.com/tw/app/knitnote/id6793023054?uo=4","supportedDevices":["iPhone17ProMax-iPhone17ProMax"]}"#
                return .init(data: AppStoreUpdateLookupTests.validPayload(results: "[\(result),\(result)]"), statusCode: 200)
            case .nonObjectResult:
                return .init(data: AppStoreUpdateLookupTests.validPayload(results: "[false]"), statusCode: 200)
            case .extraResults:
                let extra = #"{"trackId":1,"bundleId":"com.example.Other","version":"1.0","trackViewUrl":"https://apps.apple.com/tw/app/other/id1","supportedDevices":["iPhone17ProMax-iPhone17ProMax"]}"#
                return .init(data: AppStoreUpdateLookupTests.validPayload(results: "[\(Self.validResultJSON),\(extra)]"), statusCode: 200)
            case .wrongTrackID:
                return .init(data: AppStoreUpdateLookupTests.validPayload(trackID: 6_793_023_055), statusCode: 200)
            case .wrongBundleID:
                return .init(data: AppStoreUpdateLookupTests.validPayload(bundleID: "com.example.KnitNote"), statusCode: 200)
            case .missingVersion:
                return .init(data: AppStoreUpdateLookupTests.validPayload(version: nil), statusCode: 200)
            case .malformedVersion:
                return .init(data: AppStoreUpdateLookupTests.validPayload(version: "1.5-beta"), statusCode: 200)
            case .insecureStoreURL:
                return .init(data: AppStoreUpdateLookupTests.validPayload(trackViewURL: "http://apps.apple.com/tw/app/knitnote/id6793023054"), statusCode: 200)
            case .unrelatedStoreHost:
                return .init(data: AppStoreUpdateLookupTests.validPayload(trackViewURL: "https://example.com/knitnote"), statusCode: 200)
            case .deceptiveStoreHost:
                return .init(data: AppStoreUpdateLookupTests.validPayload(trackViewURL: "https://apps.apple.com.evil.example/knitnote"), statusCode: 200)
            case .missingStoreURL:
                return .init(data: AppStoreUpdateLookupTests.validPayload(trackViewURL: nil), statusCode: 200)
            case .missingCurrentPlatform:
                return .init(data: AppStoreUpdateLookupTests.validPayload(supportedDevices: ["iPadAir5-iPadAir5"]), statusCode: 200)
            case .offlineError:
                throw URLError(.notConnectedToInternet)
            case .timeoutError:
                throw URLError(.timedOut)
            case .cancellationError:
                throw CancellationError()
            }
        }

        private static let validResultJSON = #"{"trackId":6793023054,"bundleId":"com.phillon.KnitNote","version":"1.5.2","trackViewUrl":"https://apps.apple.com/tw/app/knitnote/id6793023054?uo=4","supportedDevices":["iPhone17ProMax-iPhone17ProMax"]}"#
    }
}
