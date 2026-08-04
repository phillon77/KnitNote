import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct AppVersionInfoTests {
    @Test func parsesAndTrimsBothRequiredStrings() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.3.1 ",
            "CFBundleVersion": " 007 ",
        ])
        #expect(info == AppVersionInfo(version: "1.3.1", build: "007"))
    }

    @Test func rejectsIncompleteMalformedOrBlankMetadata() {
        let dictionaries: [[String: Any]] = [
            [:],
            ["CFBundleShortVersionString": "1.3.1"],
            ["CFBundleVersion": "7"],
            ["CFBundleShortVersionString": "", "CFBundleVersion": "7"],
            ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "   "],
            ["CFBundleShortVersionString": 131, "CFBundleVersion": "7"],
            ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": 7],
        ]

        for dictionary in dictionaries {
            #expect(AppVersionInfo(infoDictionary: dictionary) == nil)
        }
    }

    @Test func preservesNonNumericComponents() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.3.1-beta",
            "CFBundleVersion": "7A",
        ])
        #expect(info?.version == "1.3.1-beta")
        #expect(info?.build == "7A")
    }
}
