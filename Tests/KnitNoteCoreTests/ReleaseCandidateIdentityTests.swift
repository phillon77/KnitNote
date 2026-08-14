import Foundation
import Testing

@Suite(.serialized) struct ReleaseCandidateIdentityTests {
    @Test func parsedProjectSpecificationUsesCandidateIdentityForEveryShippingTarget() throws {
        let payload = try runReleaseIdentityJSONTool(
            executable: "/usr/bin/env",
            arguments: ["xcodegen", "dump", "--type", "parsed-json"]
        )
        let project = try #require(payload as? [String: Any])
        let targets = try #require(project["targets"] as? [String: Any])

        for identity in shippingTargetIdentities {
            let target = try #require(targets[identity.target] as? [String: Any])
            let settings = try #require(target["settings"] as? [String: Any])
            let baseSettings = try #require(settings["base"] as? [String: Any])

            #expect(baseSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == identity.bundleIdentifier)
            #expect(baseSettings["MARKETING_VERSION"] as? String == "1.5.1")
            #expect(baseSettings["CURRENT_PROJECT_VERSION"] as? String == "11")
        }
    }

    @Test func generatedReleaseBuildSettingsUseAutomaticDevelopmentSigningWithoutProfiles() throws {
        for product in shippingProductBuildSettings {
            let payload = try runReleaseIdentityJSONTool(
                executable: "/usr/bin/xcodebuild",
                arguments: [
                    "-project", "KnitNote.xcodeproj",
                    "-target", product.target,
                    "-configuration", "Release",
                    "-sdk", product.sdk,
                    "-showBuildSettings",
                    "-json",
                    "CODE_SIGNING_ALLOWED=NO",
                ]
            )
            let entries = try #require(payload as? [[String: Any]])
            let entry = try #require(entries.first { $0["target"] as? String == product.target })
            let settings = try #require(entry["buildSettings"] as? [String: Any])

            #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == product.bundleIdentifier)
            #expect(settings["INFOPLIST_FILE"] as? String == product.infoPlist)
            #expect(settings["MARKETING_VERSION"] as? String == "1.5.1")
            #expect(settings["CURRENT_PROJECT_VERSION"] as? String == "11")
            #expect(settings["CODE_SIGN_STYLE"] as? String == "Automatic")
            #expect(settings["CODE_SIGN_IDENTITY"] as? String == "Apple Development")
            #expect(settings["DEVELOPMENT_TEAM"] as? String == "9CFPAUL5N5")
            #expect((settings["PROVISIONING_PROFILE_SPECIFIER"] as? String ?? "").isEmpty)
        }
    }

    @Test func generatedDebugBuildSettingsUseAutomaticDevelopmentSigningWithoutProfiles() throws {
        for product in shippingProductBuildSettings {
            let payload = try runReleaseIdentityJSONTool(
                executable: "/usr/bin/xcodebuild",
                arguments: [
                    "-project", "KnitNote.xcodeproj",
                    "-target", product.target,
                    "-configuration", "Debug",
                    "-sdk", product.sdk,
                    "-showBuildSettings",
                    "-json",
                    "CODE_SIGNING_ALLOWED=NO",
                ]
            )
            let entries = try #require(payload as? [[String: Any]])
            let entry = try #require(entries.first { $0["target"] as? String == product.target })
            let settings = try #require(entry["buildSettings"] as? [String: Any])

            #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == product.bundleIdentifier)
            #expect(settings["CODE_SIGN_STYLE"] as? String == "Automatic")
            #expect(settings["CODE_SIGN_IDENTITY"] as? String == "Apple Development")
            #expect(settings["DEVELOPMENT_TEAM"] as? String == "9CFPAUL5N5")
            #expect((settings["PROVISIONING_PROFILE_SPECIFIER"] as? String ?? "").isEmpty)
        }
    }

    @Test func generatedInfoPlistsPreserveCandidateIdentityAndVersion151ReleaseLocales() throws {
        let payload = try runReleaseIdentityJSONTool(
            executable: "/usr/bin/env",
            arguments: ["xcodegen", "dump", "--type", "parsed-json"]
        )
        let project = try #require(payload as? [String: Any])
        let targets = try #require(project["targets"] as? [String: Any])
        let expectedLocales = [
            "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
            "nb", "sv", "fi", "da", "ko", "el", "nl",
        ]

        for identity in shippingTargetIdentities {
            let target = try #require(targets[identity.target] as? [String: Any])
            let info = try #require(target["info"] as? [String: Any])
            let properties = try #require(info["properties"] as? [String: Any])
            #expect(info["path"] as? String == identity.infoPlist)
            #expect(properties["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
            #expect(properties["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
            #expect(properties["CFBundleLocalizations"] as? [String] == expectedLocales)

            let data = try Data(
                contentsOf: releaseCandidateIdentityRepositoryRoot.appending(path: identity.infoPlist)
            )
            let generated = try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            #expect(generated["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
            #expect(generated["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
            #expect(generated["CFBundleLocalizations"] as? [String] == expectedLocales)
        }
    }

    @Test func generatedProjectKnownRegionsMatchTheVersion151CatalogResources() throws {
        let project = try String(
            contentsOf: releaseCandidateIdentityRepositoryRoot
                .appending(path: "KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        #expect(projectKnownRegions(in: project) == [
            "Base", "da", "de", "el", "en", "fi", "fr", "ja", "ko", "nb", "nl", "sv",
            "zh-Hans", "zh-Hant",
        ])
    }
}

private struct ShippingTargetIdentity {
    let target: String
    let bundleIdentifier: String
    let infoPlist: String
}

private struct ShippingProductBuildSettings {
    let target: String
    let sdk: String
    let bundleIdentifier: String
    let infoPlist: String
}

private let shippingTargetIdentities = [
    ShippingTargetIdentity(
        target: "KnitNote",
        bundleIdentifier: "com.phillon.KnitNote",
        infoPlist: "KnitNote/Info.plist"
    ),
    ShippingTargetIdentity(
        target: "KnitNoteWatch",
        bundleIdentifier: "com.phillon.KnitNote.watch",
        infoPlist: "KnitNoteWatch/Info.plist"
    ),
    ShippingTargetIdentity(
        target: "KnitNoteShare",
        bundleIdentifier: "com.phillon.KnitNote.share",
        infoPlist: "KnitNoteShare/Info.plist"
    ),
]

private let shippingProductBuildSettings = [
    ShippingProductBuildSettings(
        target: "KnitNote",
        sdk: "iphoneos",
        bundleIdentifier: "com.phillon.KnitNote",
        infoPlist: "KnitNote/Info.plist"
    ),
    ShippingProductBuildSettings(
        target: "KnitNote",
        sdk: "macosx",
        bundleIdentifier: "com.phillon.KnitNote",
        infoPlist: "KnitNote/Info.plist"
    ),
    ShippingProductBuildSettings(
        target: "KnitNoteWatch",
        sdk: "watchos",
        bundleIdentifier: "com.phillon.KnitNote.watch",
        infoPlist: "KnitNoteWatch/Info.plist"
    ),
    ShippingProductBuildSettings(
        target: "KnitNoteShare",
        sdk: "iphoneos",
        bundleIdentifier: "com.phillon.KnitNote.share",
        infoPlist: "KnitNoteShare/Info.plist"
    ),
]

private func runReleaseIdentityJSONTool(
    executable: String,
    arguments: [String]
) throws -> Any {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = releaseCandidateIdentityRepositoryRoot
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors

    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: errorData + outputData, encoding: .utf8) ?? ""
        throw ReleaseCandidateIdentityTestError.commandFailed(message)
    }
    return try JSONSerialization.jsonObject(with: outputData)
}

private enum ReleaseCandidateIdentityTestError: Error {
    case commandFailed(String)
}

private let releaseCandidateIdentityRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func projectKnownRegions(in project: String) -> [String] {
    guard let regionBlock = project.components(separatedBy: "knownRegions = (").dropFirst().first,
          let end = regionBlock.range(of: ");")
    else {
        return []
    }

    return regionBlock[..<end.lowerBound]
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",\"")) }
        .filter { !$0.isEmpty }
}
