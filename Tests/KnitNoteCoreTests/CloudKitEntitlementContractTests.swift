import Foundation
import Testing

@Suite struct CloudKitEntitlementContractTests {
    @Test func appTargetsShareOneCanonicalCloudKitContainer() throws {
        let project = try source("project.yml")
        let generatedProject = try source("KnitNote.xcodeproj/project.pbxproj")
        let ios = try entitlements("KnitNote/KnitNote-iOS.entitlements")
        let mac = try entitlements("KnitNote/KnitNote-macOS.entitlements")

        #expect(
            project.components(
                separatedBy: "KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER: iCloud.com.phillon.KnitNote"
            ).count == 2
        )
        #expect(ios["com.apple.developer.icloud-container-identifiers"] == nil)
        #expect(mac["com.apple.developer.icloud-container-identifiers"] == nil)
        #expect(
            generatedProject.components(
                separatedBy: "KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.phillon.KnitNote;"
            ).count == 3
        )
    }

    @Test func localOnlyAppTargetsPreserveRequiredSecurityWithoutCloudCapabilities() throws {
        let project = try source("project.yml")
        let ios = try entitlements("KnitNote/KnitNote-iOS.entitlements")
        let mac = try entitlements("KnitNote/KnitNote-macOS.entitlements")

        #expect(ios["com.apple.security.application-groups"] as? [String] == ["group.com.phillon.KnitNote"])
        #expect(mac["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(mac["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(mac["com.apple.security.network.client"] as? Bool == true)
        #expect(Set(ios.keys) == Set([
            "com.apple.security.application-groups",
        ]))
        #expect(Set(mac.keys) == Set([
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client",
        ]))
        #expect(!project.contains("- remote-notification"))
        let info = try entitlements("KnitNote/Info.plist")
        #expect(!(info["UIBackgroundModes"] as? [String] ?? []).contains("remote-notification"))
    }

    @Test func generatedTargetsResolveOnlyCanonicalEntitlementFiles() throws {
        let project = try source("KnitNote.xcodeproj/project.pbxproj")
        let appExpected = [
            "CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]": "KnitNote/KnitNote-iOS.entitlements",
            "CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]": "KnitNote/KnitNote-iOS.entitlements",
            "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "KnitNote/KnitNote-macOS.entitlements",
        ]
        let shareExpected = [
            "CODE_SIGN_ENTITLEMENTS": "KnitNoteShare/KnitNoteShare.entitlements",
        ]

        for configuration in ["Debug", "Release"] {
            #expect(try entitlementSettings(target: "KnitNote", configuration: configuration, project: project) == appExpected)
            #expect(try entitlementSettings(target: "KnitNoteShare", configuration: configuration, project: project) == shareExpected)
            #expect(try entitlementSettings(target: "KnitNoteWatch", configuration: configuration, project: project).isEmpty)
        }

        #expect(Set(appExpected.values).union(shareExpected.values) == Set([
            "KnitNote/KnitNote-iOS.entitlements",
            "KnitNote/KnitNote-macOS.entitlements",
            "KnitNoteShare/KnitNoteShare.entitlements",
        ]))
    }

    @Test func watchAndShareConfigurationsContainNoCloudKitOrPushCapability() throws {
        let project = try source("project.yml")
        let watchInfo = try source("KnitNoteWatch/Info.plist")
        let shareInfo = try source("KnitNoteShare/Info.plist")
        let sectionsAndInfo = [
            try targetSection(named: "KnitNoteWatch", in: project),
            try targetSection(named: "KnitNoteShare", in: project),
            watchInfo,
            shareInfo,
        ]

        for forbidden in [
            "KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-services",
            "CloudKit",
            "aps-environment",
            "remote-notification",
        ] {
            for source in sectionsAndInfo {
                #expect(!source.contains(forbidden))
            }
        }
        let watchEntitlementFiles = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "KnitNoteWatch"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "entitlements" }
        #expect(watchEntitlementFiles.isEmpty)
        let share = try entitlements("KnitNoteShare/KnitNoteShare.entitlements")
        #expect(share.count == 1)
        #expect(
            share["com.apple.security.application-groups"] as? [String]
                == ["group.com.phillon.KnitNote"]
        )
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

    private func entitlementSettings(
        target: String,
        configuration: String,
        project: String
    ) throws -> [String: String] {
        let listMarker = #"/* Build configuration list for PBXNativeTarget "\#(target)" */ = {"#
        let listStart = try #require(project.range(of: listMarker))
        let listEnd = try #require(project.range(
            of: "\n\t\t};",
            range: listStart.upperBound..<project.endIndex
        ))
        let list = project[listStart.lowerBound..<listEnd.upperBound]
        let line = try #require(list.split(separator: "\n").first { $0.contains("/* \(configuration) */") })
        let identifier = try #require(line.split(whereSeparator: { $0.isWhitespace }).first)
        let marker = "\t\t\(identifier) /* \(configuration) */ = {"
        let start = try #require(project.range(of: marker))
        let end = try #require(project.range(
            of: "\n\t\t};",
            range: start.upperBound..<project.endIndex
        ))
        let section = String(project[start.lowerBound..<end.upperBound])
        let expression = try NSRegularExpression(
            pattern: #"(?m)^\s*"?(CODE_SIGN_ENTITLEMENTS(?:\[sdk=[^]]+\])?)"?\s*=\s*"?([^";]+)"?;\s*$"#
        )
        return try expression.matches(
            in: section,
            range: NSRange(section.startIndex..., in: section)
        ).reduce(into: [:]) { result, match in
            let keyRange = try #require(Range(match.range(at: 1), in: section))
            let valueRange = try #require(Range(match.range(at: 2), in: section))
            let key = String(section[keyRange])
            try #require(result[key] == nil)
            result[key] = String(section[valueRange]).trimmingCharacters(in: .whitespaces)
        }
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
