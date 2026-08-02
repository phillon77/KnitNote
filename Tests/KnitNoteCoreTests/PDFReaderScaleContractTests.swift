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

    @Test func readerReportsTheCurrentDisplayedPageFrameInItsViewport() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        #expect(pdf.contains("@Binding var viewport: PatternPDFViewportState"))
        #expect(pdf.contains("view.convert(page.bounds(for: view.displayBox), from: page)"))
        #expect(pdf.contains("publishViewport"))
    }

    @Test func macOSFlipsOnlyThePublishedFrameWhileIOSKeepsTheRawConversion() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let method = try #require(
            pdf.slice(from: "private func publishViewport", to: "@objc private func changed")
        )

        #expect(method.contains("#if os(macOS)"))
        #expect(method.contains("PatternPDFPageFrameGeometry.flippedFrame(converted, in: view.bounds)"))
        #expect(method.contains("#else"))
        #expect(method.contains("let platformFrame = converted"))
    }

    @Test func readerIgnoresStaleAsynchronousPageFrameWrites() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let method = try #require(pdf.slice(from: "private func publishViewport", to: "@objc private func changed"))

        #expect(method.contains("guard let self, self.lastPublishedViewport == candidate else { return }"))
    }

    @Test func readerProvidesDefaultViewportBindingForExistingCallSites() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        #expect(pdf.contains("viewport: Binding<PatternPDFViewportState> = .constant(PatternPDFViewportState())"))
    }

    @Test func readerPublishesOneViewportFromPageScaleLayoutAndScrollEvents() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")

        #expect(pdf.contains("@Binding var viewport: PatternPDFViewportState"))
        #expect(pdf.contains("private func publishViewport(from view: PDFView"))
        #expect(pdf.contains("viewportPublicationGate.accept(candidate)"))
        #expect(pdf.contains("installScrollObservation(in: view)"))
        #expect(pdf.contains("contentOffsetObservation"))
        #expect(pdf.contains("NSView.boundsDidChangeNotification"))
        #expect(!pdf.contains("scroll.delegate ="))
    }

    @Test func iOSObservesEveryNestedPDFScrollLayerInsteadOfOnlyThePagingContainer() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")

        #expect(pdf.contains(
            "private var contentOffsetObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]"
        ))
        #expect(pdf.contains("for scroll in findScrollViews(in: view)"))
        #expect(pdf.contains("private func findScrollViews(in root: UIView) -> [UIScrollView]"))
        #expect(!pdf.contains("private weak var observedScrollView: UIScrollView?"))
    }

    @Test func fallbackTimerDoesNotPublishViewport() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let sample = try #require(pdf.slice(from: "private func sample", to: "deinit"))
        #expect(!sample.contains("publishViewport"))
        #expect(!sample.contains("pageFrame"))
    }

    @Test func everyPlatformUpdateRefreshesTheCoordinatorStateBindingBeforeUpdateWork() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")

        #expect(pdf.contains(
            "func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view, state: $state, viewport: $viewport, scaleMode: scaleMode) }"
        ))
        #expect(pdf.contains(
            "func updateUIView(_ view: PDFView, context: Context) { context.coordinator.update(view, state: $state, viewport: $viewport, scaleMode: scaleMode) }"
        ))

        let method = try #require(pdf.slice(from: "        func update(\n", to: "        private func scheduleRestore"))
        let bindingRefresh = try #require(method.range(of: "_state = state"))
        let viewportBindingRefresh = try #require(method.range(of: "_viewport = viewport"))
        let scaleModeUpdate = try #require(method.range(of: "latestScaleMode = scaleMode"))
        let restoreOrScaleWork = try #require(method.range(of: "if restoreGate.beginRestoring()"))

        #expect(method.contains("state: Binding<PatternReadingState>"))
        #expect(method.contains("viewport: Binding<PatternPDFViewportState>"))
        #expect(bindingRefresh.lowerBound < scaleModeUpdate.lowerBound)
        #expect(bindingRefresh.lowerBound < restoreOrScaleWork.lowerBound)
        #expect(viewportBindingRefresh.lowerBound < scaleModeUpdate.lowerBound)
        #expect(viewportBindingRefresh.lowerBound < restoreOrScaleWork.lowerBound)
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
