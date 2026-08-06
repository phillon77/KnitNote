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

            #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == identity.bundleIdentifier)
            #expect(settings["MARKETING_VERSION"] as? String == "1.4.0")
            #expect(settings["CURRENT_PROJECT_VERSION"] as? String == "8")
        }
    }

    @Test func generatedReleaseBuildSettingsUseCandidateIdentityForEveryShippingProduct() throws {
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
            #expect(settings["MARKETING_VERSION"] as? String == "1.4.0")
            #expect(settings["CURRENT_PROJECT_VERSION"] as? String == "8")
        }
    }

    @Test func generatedInfoPlistsPreserveCandidateIdentityAndExactReleaseLocales() throws {
        let payload = try runReleaseIdentityJSONTool(
            executable: "/usr/bin/env",
            arguments: ["xcodegen", "dump", "--type", "parsed-json"]
        )
        let project = try #require(payload as? [String: Any])
        let targets = try #require(project["targets"] as? [String: Any])
        let expectedLocales = ["en", "zh-Hant", "zh-Hans", "de", "fr", "ja"]

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
