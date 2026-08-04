import Foundation
import Testing

@Suite struct PatternReaderCalculatorIntegrationTests {
    @Test func readerOwnsSessionStateAndPresentsThePanelFromItsToolbar() throws {
        let source = try appSource("KnitNote/Patterns/PatternReaderView.swift")
        #expect(source.contains("@State private var calculatorState = PatternCalculatorState()"))
        #expect(source.contains("@State private var showingCalculator = false"))
        #expect(source.contains("Label(\"patterns.calculator.title\", systemImage: \"plus.forwardslash.minus\")"))
        #expect(source.contains(".frame(minWidth: 44, minHeight: 44)"))
        #expect(source.contains(".accessibilityHint(Text(\"patterns.calculator.hint\"))"))
        #expect(source.contains("PatternCalculatorView(state: $calculatorState)"))
        #expect(source.contains(".presentationCompactAdaptation(.sheet)"))
        #expect(source.contains(".presentationDetents(calculatorPresentationDetents)"))
        #expect(source.contains("verticalSizeClass == .compact ? [.large] : [.medium]"))
        #expect(!source.contains(".presentationDetents([.medium])"))
    }

    @Test func calculatorIsNotWrittenIntoReaderOrStoreState() throws {
        let reader = try appSource("KnitNote/Patterns/PatternReaderView.swift")
        let document = try appSource("Sources/KnitNoteCore/Patterns/PatternDocument.swift")
        let usage = try appSource("Sources/KnitNoteCore/Patterns/PatternProjectUsage.swift")
        #expect(!document.contains("PatternCalculator"))
        #expect(!usage.contains("PatternCalculator"))
        #expect(!reader.contains("mutatePatternReaderCalculator"))
        #expect(!reader.contains("saveCalculator"))
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
