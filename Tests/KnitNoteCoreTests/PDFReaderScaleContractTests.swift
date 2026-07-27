import Foundation
import Testing

@Suite struct PDFReaderScaleContractTests {
    @Test func readerPassesAdaptiveScaleModeIntoPDFKit() throws {
        let reader = try source("KnitNote/Patterns/PatternReaderView.swift")
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        #expect(reader.contains("scaleMode: layout.pdfScaleMode"))
        #expect(pdf.contains("let scaleMode: PatternPDFScaleMode"))
        #expect(pdf.contains("applyScaleMode"))
    }

    @Test func fitWidthDoesNotTransitionOrOverwriteReadingState() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let method = try #require(pdf.slice(from: "private func applyScaleMode", to: "@objc private func changed"))
        #expect(!method.contains("state.transitionToPDFPage"))
        #expect(!method.contains("state.highlight"))
        #expect(!method.contains("state.pageNote"))
    }

    @Test func readerReportsTheCurrentDisplayedPageFrame() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        #expect(pdf.contains("@Binding var pageFrame: CGRect?"))
        #expect(pdf.contains("view.convert(page.bounds(for: view.displayBox), from: page)"))
        #expect(pdf.contains("publishPageFrame"))
    }

    @Test func readerIgnoresStaleAsynchronousPageFrameWrites() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let method = try #require(pdf.slice(from: "private func publishPageFrame", to: "@objc private func changed"))

        #expect(method.contains("guard let self, self.lastPublishedPageFrame == nil else { return }"))
        #expect(method.contains("guard let self, self.lastPublishedPageFrame == candidate else { return }"))
    }

    @Test func readerProvidesDefaultPageFrameBindingForExistingCallSites() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        #expect(pdf.contains("pageFrame: Binding<CGRect?> = .constant(nil)"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}

private extension String {
    func slice(from start: String, to end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex)
        else { return nil }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}
