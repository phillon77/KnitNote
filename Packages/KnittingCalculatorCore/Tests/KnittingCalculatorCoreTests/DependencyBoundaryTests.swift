import Foundation
import Testing
@testable import KnittingCalculatorCore

private func importedModules(in source: String) -> [String] {
    let declarationKinds: Set<Substring> = [
        "class",
        "enum",
        "func",
        "let",
        "protocol",
        "struct",
        "typealias",
        "var",
    ]

    return source
        .split(whereSeparator: \.isNewline)
        .flatMap { line in
            line.split(separator: ";")
        }
        .compactMap { statement -> String? in
            let components = statement
                .split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace)
            guard let importIndex = components.firstIndex(of: "import") else {
                return nil
            }
            var moduleIndex = components.index(after: importIndex)
            guard moduleIndex < components.endIndex else {
                return nil
            }
            if declarationKinds.contains(components[moduleIndex]) {
                moduleIndex = components.index(after: moduleIndex)
            }
            guard moduleIndex < components.endIndex else {
                return nil
            }
            return String(components[moduleIndex].split(separator: ".")[0])
        }
}

@Suite struct DependencyBoundaryTests {
    @Test func recognizesDeclarationSpecificAndExportedImports() {
        let source = """
        @_exported import UIKit
        import struct StoreKit.Product
        public import Combine
        """

        #expect(importedModules(in: source) == ["UIKit", "StoreKit", "Combine"])
    }

    @Test func recognizesSemicolonSeparatedImports() {
        let source = "import Foundation; import StoreKit; public import Combine"

        #expect(
            importedModules(in: source) == ["Foundation", "StoreKit", "Combine"]
        )
    }

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
            let importedModules = importedModules(in: source)

            for forbiddenModule in forbiddenModules {
                #expect(
                    !importedModules.contains(forbiddenModule),
                    "Production source \(sourceURL.lastPathComponent) imports \(forbiddenModule)"
                )
            }
        }
    }
}
