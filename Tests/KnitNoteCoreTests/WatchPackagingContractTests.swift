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

    @Test func watchInfoDeclaresItsCompanionApp() throws {
        let project = try source("project.yml")

        #expect(project.contains("""
            info:
              path: KnitNoteWatch/Info.plist
              properties:
                CFBundleDisplayName: KnitNote
                WKCompanionAppBundleIdentifier: com.phillon.KnitNote
        """))
    }

    @Test func generatedProjectFiltersWatchEmbeddingToIOS() throws {
        let project = try source("KnitNote.xcodeproj/project.pbxproj")

        #expect(project.contains("KnitNoteWatch.app in Embed Watch Content"))
        #expect(project.contains("platformFilter = ios;"))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
