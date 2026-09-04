import Foundation
import Testing

@Suite struct CloudKitEntitlementContractTests {
    @Test func appTargetsShareOneCanonicalCloudKitContainer() throws {
        let project = try source("project.yml")
        let generatedProject = try source("KnitNote.xcodeproj/project.pbxproj")
        let ios = try entitlements("KnitNote/KnitNote-iOS.entitlements")
        let mac = try entitlements("KnitNote/KnitNote-macOS.entitlements")
        let expectedReference = "$(KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER)"

        #expect(
            project.components(
                separatedBy: "KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER: iCloud.com.phillon.KnitNote"
            ).count == 2
        )
        #expect(ios["com.apple.developer.icloud-container-identifiers"] as? [String] == [expectedReference])
        #expect(mac["com.apple.developer.icloud-container-identifiers"] as? [String] == [expectedReference])
        #expect(
            generatedProject.components(
                separatedBy: "KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.phillon.KnitNote;"
            ).count == 3
        )
    }

    @Test func appTargetsDeclareCloudKitAndRemoteNotificationCapabilities() throws {
        let project = try source("project.yml")
        let ios = try entitlements("KnitNote/KnitNote-iOS.entitlements")
        let mac = try entitlements("KnitNote/KnitNote-macOS.entitlements")

        #expect(ios["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(mac["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
        #expect(ios["aps-environment"] as? String == "development")
        #expect(mac["com.apple.developer.aps-environment"] as? String == "development")
        #expect(project.contains("UIBackgroundModes:\n          - remote-notification"))
    }

    @Test func watchConfigurationContainsNoCloudKitOrPushCapability() throws {
        let project = try source("project.yml")
        let watchInfo = try source("KnitNoteWatch/Info.plist")
        let watchSection = try targetSection(named: "KnitNoteWatch", in: project)

        for forbidden in [
            "KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-services",
            "CloudKit",
            "aps-environment",
            "remote-notification",
        ] {
            #expect(!watchSection.contains(forbidden))
            #expect(!watchInfo.contains(forbidden))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "KnitNoteWatch/KnitNoteWatch.entitlements").path))
    }

    private func targetSection(named name: String, in project: String) throws -> String {
        let startMarker = "  \(name):\n"
        let start = try #require(project.range(of: startMarker)?.lowerBound)
        let afterStart = project.index(start, offsetBy: startMarker.count)
        let next = project.range(
            of: #"\n  [A-Za-z][A-Za-z0-9]*:\n"#,
            options: .regularExpression,
            range: afterStart..<project.endIndex
        )?.lowerBound ?? project.endIndex
        return String(project[start..<next])
    }

    private func entitlements(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: relativePath))
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    private var root: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
