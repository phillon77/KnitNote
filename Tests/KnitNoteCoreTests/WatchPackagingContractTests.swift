import Foundation
import Testing

@Suite struct WatchPackagingContractTests {
    @Test func iOSAppEmbedsWatchTargetOnlyForIOS() throws {
        let project = try source("project.yml")

        #expect(project.contains("""
            dependencies:
              - target: KnitNoteWatch
                embed: true
                platformFilter: iOS
        """))
    }

    @Test func appAndWatchPlistsUseSharedDynamicReleaseMetadata() throws {
        let appInfo = try plist("KnitNote/Info.plist")
        let watchInfo = try plist("KnitNoteWatch/Info.plist")

        for info in [appInfo, watchInfo] {
            #expect(info["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
            #expect(info["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)")
        }
        #expect(
            watchInfo["WKCompanionAppBundleIdentifier"] as? String
                == "com.phillon.KnitNote"
        )
    }

    @Test func projectGeneratesDynamicReleaseMetadataForBothApps() throws {
        let project = try source("project.yml")

        #expect(
            project.components(
                separatedBy: "CFBundleShortVersionString: $(MARKETING_VERSION)"
            ).count == 3
        )
        #expect(
            project.components(
                separatedBy: "CFBundleVersion: $(CURRENT_PROJECT_VERSION)"
            ).count == 3
        )
        #expect(project.contains("WKCompanionAppBundleIdentifier: com.phillon.KnitNote"))
    }

    @Test func generatedProjectHasCompleteIOSOnlyEmbedContract() throws {
        try validateGeneratedProject(try source("KnitNote.xcodeproj/project.pbxproj"))
    }

    @Test func generatedContractRejectsMissingBuildFileFilter() throws {
        let project = try source("KnitNote.xcodeproj/project.pbxproj")
        let broken = project.replacingOccurrences(
            of: "; platformFilter = ios; settings =",
            with: "; settings ="
        )

        #expect(throws: PackagingContractError.self) {
            try validateGeneratedProject(broken)
        }
    }

    @Test func generatedContractRejectsMissingTargetDependencyFilter() throws {
        let project = try source("KnitNote.xcodeproj/project.pbxproj")
        let broken = project.replacingOccurrences(
            of: "isa = PBXTargetDependency;\n\t\t\tplatformFilter = ios;",
            with: "isa = PBXTargetDependency;"
        )

        #expect(throws: PackagingContractError.self) {
            try validateGeneratedProject(broken)
        }
    }

    private func validateGeneratedProject(_ project: String) throws {
        let buildFiles = try section("PBXBuildFile", in: project)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("KnitNoteWatch.app in Embed Watch Content") }
        try require(buildFiles.count == 1, "one Watch embed build file")
        let buildFile = buildFiles[0]
        try require(buildFile.contains("isa = PBXBuildFile;"), "Watch PBXBuildFile type")
        try require(buildFile.contains("platformFilter = ios;"), "Watch build-file iOS filter")
        let buildFileID = try identifier(from: buildFile)

        let dependency = try uniqueObject(
            in: section("PBXTargetDependency", in: project),
            containing: "/* KnitNoteWatch */"
        )
        try require(
            dependency.contains("isa = PBXTargetDependency;"),
            "Watch target dependency type"
        )
        try require(
            dependency.contains("platformFilter = ios;"),
            "Watch target-dependency iOS filter"
        )

        let embedPhase = try uniqueObject(
            in: section("PBXCopyFilesBuildPhase", in: project),
            containing: "name = \"Embed Watch Content\";"
        )
        try require(
            embedPhase.contains("isa = PBXCopyFilesBuildPhase;"),
            "Watch embed copy-phase type"
        )
        try require(
            embedPhase.contains("dstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";"),
            "Watch embed destination path"
        )
        try require(embedPhase.contains("dstSubfolderSpec = 16;"), "Watch embed destination")
        try require(
            embedPhase.contains("\(buildFileID) /* KnitNoteWatch.app in Embed Watch Content */"),
            "Watch build file in embed phase"
        )
        let embedPhaseID = try identifier(from: embedPhase)

        let appTarget = try uniqueObject(
            in: section("PBXNativeTarget", in: project),
            containing: "\(try appTargetID(in: project)) /* KnitNote */ = {"
        )
        let buildPhases = try valueList("buildPhases", in: appTarget)
        try require(
            buildPhases.contains("\(embedPhaseID) /* Embed Watch Content */"),
            "KnitNote owns Watch embed phase"
        )
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appending(path: path))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw PackagingContractError.missing("property-list dictionary at \(path)")
        }
        return dictionary
    }

    private func section(_ name: String, in project: String) throws -> String {
        let startMarker = "/* Begin \(name) section */"
        let endMarker = "/* End \(name) section */"
        guard
            let start = project.range(of: startMarker),
            let end = project.range(of: endMarker, range: start.upperBound..<project.endIndex)
        else {
            throw PackagingContractError.missing("\(name) section")
        }
        return String(project[start.upperBound..<end.lowerBound])
    }

    private func uniqueObject(in section: String, containing needle: String) throws -> String {
        let objects = section.components(separatedBy: "\n\t\t};")
            .filter { $0.contains(needle) }
            .map { $0 + "\n\t\t};" }
        guard objects.count == 1 else {
            throw PackagingContractError.missing("one object containing \(needle)")
        }
        return objects[0]
    }

    private func identifier(from object: String) throws -> String {
        guard
            let line = object.split(separator: "\n").first(where: { $0.contains(" = {") }),
            let identifier = line.split(whereSeparator: \.isWhitespace).first,
            identifier.count == 24
        else {
            throw PackagingContractError.missing("24-character object identifier")
        }
        return String(identifier)
    }

    private func appTargetID(in project: String) throws -> String {
        let nativeTargets = try section("PBXNativeTarget", in: project)
        let appTarget = try uniqueObject(in: nativeTargets, containing: "name = KnitNote;")
        return try identifier(from: appTarget)
    }

    private func valueList(_ name: String, in object: String) throws -> String {
        let startMarker = "\(name) = ("
        guard
            let start = object.range(of: startMarker),
            let end = object.range(of: ");", range: start.upperBound..<object.endIndex)
        else {
            throw PackagingContractError.missing("\(name) list")
        }
        return String(object[start.upperBound..<end.lowerBound])
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ contract: String
    ) throws {
        guard condition() else {
            throw PackagingContractError.missing(contract)
        }
    }
}

private enum PackagingContractError: Error {
    case missing(String)
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
