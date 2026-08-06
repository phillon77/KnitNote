import Foundation
import Testing

@Suite(.serialized) struct RuntimeLocalizationSourceContractTests {
    @Test func compilerASTDetectorCatchesDirectFoundationLocalizationCalls() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "RuntimeLocalizationSourceContractTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appending(path: "runtime-localization-detector.swift")
        try Data(
            """
            import Foundation
            func render(locale: Locale) {
                _ = String(localized: "unqualified")
                _ = String(localized: "locale-is-formatting-only", locale: locale)
                _ = String.localizedStringWithFormat("%d", 1)
            }
            """.utf8
        ).write(to: source)

        let violations = directLocalizationViolations(in: try swiftAST(for: source))

        #expect(violations == [
            "String(localized:)",
            "String(localized:locale:)",
            "String.localizedStringWithFormat",
        ])
    }

    @Test func shippingUISourcesUseTheRuntimeLocaleAwareBoundary() throws {
        var violations: [String] = []
        for directory in ["KnitNote", "KnitNoteShare", "KnitNoteWatch"] {
            let root = runtimeLocalizationRepositoryRoot.appending(path: directory)
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil
                )
            )
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let findings = directLocalizationViolations(in: try swiftAST(for: file))
                let relative = file.path.replacingOccurrences(
                    of: runtimeLocalizationRepositoryRoot.path + "/",
                    with: ""
                )
                violations.append(contentsOf: findings.map { "\(relative): \($0)" })
            }
        }

        if !violations.isEmpty {
            Issue.record("Direct process-language localization calls:\n\(violations.sorted().joined(separator: "\n"))")
        }
    }

    @Test func visibleErrorsKeepSemanticKeysUntilRenderingWithTheCurrentLocale() throws {
        for contract in [
            ("KnitNote/Patterns/PatternDetailView.swift", "errorMessage"),
            ("KnitNote/Patterns/ProjectPatternsView.swift", "errorMessage"),
            ("KnitNote/Patterns/PatternReaderView.swift", "saveError"),
        ] {
            let source = try repositorySource(contract.0)
            #expect(source.contains("@Environment(\\.locale) private var locale"))
            #expect(source.contains("@State private var \(contract.1): LocalizedMessage?"))
            #expect(source.contains("\(contract.1)?.resolved(locale: locale)"))
            #expect(!source.contains("\(contract.1) = error.localizedDescription"))
        }
    }

    @Test func dynamicTitlesAndToolbarResolveFromTheCurrentSwiftUILocale() throws {
        for path in [
            "KnitNote/Patterns/EditPatternPageNoteView.swift",
            "KnitNote/Projects/EditRowNoteView.swift",
            "KnitNote/Patterns/PatternReaderView.swift",
        ] {
            let source = try repositorySource(path)
            #expect(source.contains("LocaleAwareText.format("))
            #expect(source.contains("locale: locale"))
        }

        let toolbar = try repositorySource("KnitNote/Patterns/PatternMarkupToolbar.swift")
        #expect(toolbar.contains("Button(LocalizedStringKey("))
        #expect(toolbar.contains("patterns.markup.color.\\(value.rawValue)"))
    }

    @Test func storageCachesBytesNotLocaleDerivedCopy() throws {
        let source = try repositorySource("KnitNote/Settings/YarnLabelStorageRow.swift")
        let state = try #require(
            sourceSection(source, from: "private enum StorageState", to: "var body:")
        )
        let loaded = try #require(
            sourceSection(source, from: "case let .loaded", to: "case .unavailable")
        )

        #expect(state.contains("case loaded(Int64)"))
        #expect(!source.contains("ByteCountFormatter"))
        #expect(loaded.contains("LocaleAwareText.byteCount(bytes, locale: locale)"))
    }

    @Test func cameraRefreshesAnActiveOverlayWhenTheSelectedLocaleChanges() throws {
        let source = try repositorySource("KnitNote/Projects/CameraCaptureView.swift")
        let representable = try #require(
            sourceSection(source, from: "struct CameraCaptureView", to: "@MainActor\n    final class Coordinator")
        )
        let coordinator = try #require(
            sourceSection(source, from: "final class Coordinator", to: "}\n}\n\nprivate extension")
        )

        #expect(representable.contains("@Environment(\\.locale) private var locale"))
        #expect(representable.contains("context.coordinator.update(parent: self, locale: locale)"))
        #expect(coordinator.contains("private var locale: Locale"))
        #expect(coordinator.contains("processingOverlay?.accessibilityLabel = processingAccessibilityLabel"))
        #expect(coordinator.contains("LocaleAwareText.string(\"journal.photo.loading\", locale: locale)"))
    }
}

private func directLocalizationViolations(in ast: String) -> [String] {
    let lines = ast.split(separator: "\n", omittingEmptySubsequences: false)
    var violations: [String] = []

    for (index, line) in lines.enumerated() {
        if line.contains("field=\"localizedStringWithFormat\"") {
            violations.append("String.localizedStringWithFormat")
        }
        guard line.contains("name=\"String\"") else { continue }

        for candidate in lines.dropFirst(index + 1).prefix(4) {
            guard let labelsRange = candidate.range(of: "argument_list labels=\"") else {
                continue
            }
            let suffix = candidate[labelsRange.upperBound...]
            guard let closingQuote = suffix.firstIndex(of: "\"") else { break }
            let labels = String(suffix[..<closingQuote])
            if labels.hasPrefix("localized:") {
                violations.append("String(\(labels))")
            }
            break
        }
    }
    return violations
}

private func swiftAST(for source: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-frontend", "-dump-parse", source.path]
    process.currentDirectoryURL = runtimeLocalizationRepositoryRoot
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors

    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RuntimeLocalizationContractError.parseFailed(
            String(data: errorData + outputData, encoding: .utf8) ?? ""
        )
    }
    return String(data: outputData, encoding: .utf8) ?? ""
}

private func repositorySource(_ path: String) throws -> String {
    try String(
        contentsOf: runtimeLocalizationRepositoryRoot.appending(path: path),
        encoding: .utf8
    )
}

private func sourceSection(
    _ source: String,
    from start: String,
    to end: String
) -> Substring? {
    guard let startRange = source.range(of: start),
          let endRange = source.range(
              of: end,
              range: startRange.upperBound..<source.endIndex
          ) else {
        return nil
    }
    return source[startRange.lowerBound..<endRange.lowerBound]
}

private enum RuntimeLocalizationContractError: Error {
    case parseFailed(String)
}

private let runtimeLocalizationRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
