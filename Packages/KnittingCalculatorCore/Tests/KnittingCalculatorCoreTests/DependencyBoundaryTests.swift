import Foundation
import Testing
@testable import KnittingCalculatorCore

@Suite struct DependencyBoundaryTests {
    @Test func productionSourcesDoNotImportProductOrPlatformFrameworks() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = packageRoot
            .appendingPathComponent("Sources/KnittingCalculatorCore", isDirectory: true)
        let sourceURLs = try #require(
            FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
        )

        #expect(!sourceURLs.isEmpty)

        let forbiddenModules = [
            "SwiftUI",
            "UIKit",
            "StoreKit",
            "Combine",
            "SwiftData",
            "CoreData",
            "Network",
        ]
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let importedModules = source
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    let components = line.split(whereSeparator: \.isWhitespace)
                    guard components.first == "import", components.count >= 2 else {
                        return nil
                    }
                    return String(components[1].split(separator: ".")[0])
                }

            for forbiddenModule in forbiddenModules {
                #expect(
                    !importedModules.contains(forbiddenModule),
                    "Production source \(sourceURL.lastPathComponent) imports \(forbiddenModule)"
                )
            }
        }
    }
}
