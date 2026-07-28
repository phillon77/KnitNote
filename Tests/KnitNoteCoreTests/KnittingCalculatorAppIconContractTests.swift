import Foundation
import Testing

@Suite struct KnittingCalculatorAppIconContractTests {
    @Test func freeCalculatorHasIndependentCompleteIconSet() throws {
        let iconRoot = repositoryRoot.appending(path:
            "KnittingCalculator/Assets.xcassets/AppIcon.appiconset")
        let contents = try String(
            contentsOf: iconRoot.appending(path: "Contents.json"),
            encoding: .utf8
        )
        #expect(contents.contains("app-icon-1024.png"))
        #expect(contents.contains("\"idiom\" : \"ios-marketing\""))
        #expect(
            try Data(contentsOf: iconRoot.appending(path: "app-icon-1024.png"))
            != Data(contentsOf: repositoryRoot.appending(path:
                "KnitNote/Assets.xcassets/AppIcon.appiconset/app-icon-1024.png"))
        )
    }
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
