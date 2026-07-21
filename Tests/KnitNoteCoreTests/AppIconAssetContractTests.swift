import Foundation
import ImageIO
import Testing

@Suite struct AppIconAssetContractTests {
    @Test func mainAndWatchCatalogsContainAnOpaque1024Master() throws {
        for relativePath in [
            "KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png",
            "KnitNoteWatch/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png"
        ] {
            let url = repositoryRoot.appendingPathComponent(relativePath)
            #expect(FileManager.default.fileExists(atPath: url.path))

            let data = try Data(contentsOf: url)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
            #expect(properties[kCGImagePropertyPixelHeight] as? Int == 1024)
            #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        }
    }

    @Test func projectUsesAppIconForBothTargets() throws {
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        #expect(
            project.components(
                separatedBy: "ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"
            ).count == 3
        )
    }

    @Test func originalLemonAssetRemainsTrackedSeparately() {
        let original = repositoryRoot.appendingPathComponent(
            "KnitNote/Assets.xcassets/LemonYarn.imageset/lemon-yarn.png"
        )
        #expect(FileManager.default.fileExists(atPath: original.path))
    }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
