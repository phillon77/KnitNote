import Foundation
import Testing

@Suite struct PDFReaderScaleContractTests {
    @Test func pdfReaderRestoresSavedWidthInsteadOfResettingEveryPageToFitWidth() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")

        #expect(pdf.contains("PatternPDFScalePolicy.absoluteScale"))
        #expect(pdf.contains("state.pdfWidthScaleRatio"))
        #expect(pdf.contains("isApplyingSavedScale"))
    }

    @Test func programmaticScaleEventsCannotOverwriteASettledUserWidth() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let application = try #require(
            pdf.slice(from: "private func applyScaleMode", to: "private func publishViewport")
        )
        let capture = try #require(
            pdf.slice(from: "private func scheduleUserScaleCapture", to: "private func publishViewport")
        )

        #expect(application.contains("isApplyingSavedScale = true"))
        #expect(application.contains("defer { isApplyingSavedScale = false }"))
        let flush = try #require(application.range(of: "flushPendingScaleCapture()"))
        let invalidate = try #require(application.range(of: "scaleCaptureGate.invalidate()"))
        let programmaticApplication = try #require(application.range(of: "isApplyingSavedScale = true"))
        #expect(flush.lowerBound < invalidate.lowerBound)
        #expect(invalidate.lowerBound < programmaticApplication.lowerBound)
        #expect(capture.contains("guard restoreGate.canSample, !isApplyingSavedScale"))
        #expect(capture.contains("scaleCaptureTask?.cancel()"))
        #expect(capture.contains("scaleCaptureGate.observe"))
        #expect(capture.contains("scaleCaptureGate.settle"))
        #expect(capture.contains("discardPendingScaleCapture()"))
        #expect(capture.contains("liveScale: settledScale"))
        #expect(capture.contains("state.pdfWidthScaleRatio"))
    }

    @Test func navigatorFlushesPendingWidthBeforeRequestingOrDisplayingAnotherPage() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let navigation = try #require(
            pdf.slice(from: "func go(to pageIndex: Int)", to: "}\n\n#if os(macOS)")
        )
        let flush = try #require(navigation.range(of: "flushPendingScaleCapture()"))
        let capture = try #require(navigation.range(of: "captureCurrentPosition()"))
        let request = try #require(navigation.range(of: "request?(target)"))
        let display = try #require(navigation.range(of: "view.go(to: page)"))

        #expect(flush.lowerBound < request.lowerBound)
        #expect(capture.lowerBound < request.lowerBound)
        #expect(flush.lowerBound < display.lowerBound)
    }

    @Test func iOSPositionPersistenceUsesTheActualPDFContentScrollLayer() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let capture = try #require(
            pdf.slice(from: "private func captureCurrentPosition", to: "private func scheduleCurrentPositionRestore")
        )
        let restore = try #require(
            pdf.slice(from: "private func restorePosition", to: "private func scheduleUserScaleCapture")
        )

        #expect(capture.contains("contentScrollView(in: view)"))
        #expect(capture.contains("PatternPDFScrollAnchorGeometry.normalizedAnchor"))
        #expect(restore.contains("PatternPDFScrollAnchorGeometry.contentOffset"))
        #expect(restore.contains("setContentOffset"))
        #expect(pdf.contains("private func contentScrollView(in view: PDFView) -> UIScrollView?"))
    }

    @Test func programmaticPositionRestoreCannotOverwriteItsSavedAnchor() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let capture = try #require(
            pdf.slice(from: "private func captureCurrentPosition", to: "private func scheduleCurrentPositionRestore")
        )
        let schedule = try #require(
            pdf.slice(from: "private func scheduleCurrentPositionRestore", to: "private func restorePosition")
        )

        #expect(pdf.contains("private var isApplyingSavedPosition = false"))
        #expect(capture.contains("!isApplyingSavedPosition"))
        #expect(schedule.contains("let savedState = savedState ?? state"))
        #expect(schedule.contains("isApplyingSavedPosition = true"))
        #expect(schedule.contains("restorePosition(savedState, in: view)"))
        #expect(!schedule.contains("restorePosition(self.state, in: view)"))
    }

    @Test func appInactivityFreezesTheLastStablePDFPositionUntilForegroundRestoreFinishes() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let capture = try #require(
            pdf.slice(from: "private func captureCurrentPosition", to: "private func scheduleCurrentPositionRestore")
        )
        let inactivity = try #require(
            pdf.slice(from: "private func prepareForInactivity", to: "private func scheduleForegroundPositionRestore")
        )
        let foreground = try #require(
            pdf.slice(from: "private func scheduleForegroundPositionRestore", to: "private func scheduleCurrentPositionRestore")
        )

        #expect(pdf.contains("private var foregroundPositionSnapshot: PatternReadingState?"))
        #expect(pdf.contains("private var isPositionSamplingSuspended = false"))
        #expect(capture.contains("!isPositionSamplingSuspended"))
        #expect(inactivity.contains("captureCurrentPosition()"))
        #expect(inactivity.contains("foregroundPositionSnapshot = state"))
        #expect(inactivity.contains("isPositionSamplingSuspended = true"))
        #expect(foreground.contains("let savedState = foregroundPositionSnapshot ?? state"))
        #expect(foreground.contains("settleAfterForeground: true"))
    }

    @Test func foregroundRestoreReappliesTheFrozenPositionAcrossDelayedPDFKitLayout() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let schedule = try #require(
            pdf.slice(from: "private func scheduleCurrentPositionRestore", to: "private func restorePosition")
        )

        #expect(schedule.contains("settleAfterForeground: Bool = false"))
        #expect(schedule.contains("let delays = settleAfterForeground"))
        #expect(schedule.contains("restorePosition(savedState, in: view)"))
        #expect(schedule.contains("foregroundPositionSnapshot = nil"))
        #expect(schedule.contains("isPositionSamplingSuspended = false"))
    }

    @Test func foregroundRestoreYieldsImmediatelyToExplicitPageNavigation() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let navigation = try #require(
            pdf.slice(from: "func go(to pageIndex: Int)", to: "}\n\n#if os(macOS)")
        )
        let cancellation = try #require(navigation.range(of: "cancelForegroundRestoreAction?()"))
        let capture = try #require(navigation.range(of: "captureCurrentPosition()"))
        let display = try #require(navigation.range(of: "view.go(to: page)"))

        #expect(cancellation.lowerBound < capture.lowerBound)
        #expect(cancellation.lowerBound < display.lowerBound)
        #expect(pdf.contains("cancelForegroundRestore: { [weak self] in self?.cancelForegroundPositionRestore() }"))
    }

    @Test func foregroundRestoreYieldsToAnIOSUserScrollGesture() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let observation = try #require(
            pdf.slice(from: "private func installScrollObservation", to: "#if os(macOS)\n        private func findScrollView")
        )

        #expect(observation.contains("scroll.isDragging || scroll.isDecelerating || scroll.isZooming"))
        #expect(observation.contains("cancelForegroundPositionRestore()"))
        #expect(observation.contains("captureCurrentPosition()"))
        #expect(pdf.contains("private func cancelForegroundPositionRestore()"))
    }

    @Test func delayedForegroundSettlingIsIOSOnly() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let foreground = try #require(
            pdf.slice(from: "private func scheduleForegroundPositionRestore", to: "private func scheduleCurrentPositionRestore")
        )

        #expect(foreground.contains("#if os(macOS)"))
        #expect(foreground.contains("settleAfterForeground: false"))
        #expect(foreground.contains("#else"))
        #expect(foreground.contains("settleAfterForeground: true"))
    }

    @Test func nativePDFKitPageSwipeCancelsForegroundRestoreBeforeRestoringTheNewPage() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let changed = try #require(
            pdf.slice(from: "@objc private func changed", to: "private func sample")
        )
        let cancellation = try #require(changed.range(of: "cancelForegroundRestoreIfPageChanged(in: view)"))
        let restore = try #require(changed.range(of: "scheduleCurrentPositionRestore()"))

        #expect(cancellation.lowerBound < restore.lowerBound)
        #expect(pdf.contains("private func cancelForegroundRestoreIfPageChanged(in view: PDFView)"))
        #expect(pdf.contains("visiblePage != snapshot.pageIndex"))
    }

    @Test func iOSRotationRestoresTheSameVisiblePDFLineWithoutChangingSavedWidthOrHighlight() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let scale = try #require(
            pdf.slice(from: "private func applyScaleMode", to: "private func fitWidthBaseline")
        )
        let rotation = try #require(
            pdf.slice(from: "private func scheduleRotationPositionRestore", to: "private func restoreRotationPosition")
        )
        let restore = try #require(
            pdf.slice(from: "private func restoreRotationPosition", to: "private func scheduleUserScaleCapture")
        )

        #expect(pdf.contains("private var visiblePageVerticalAnchor"))
        #expect(scale.contains("previous.size != signature.size"))
        #expect(scale.contains("scheduleRotationPositionRestore"))
        #expect(rotation.contains("isApplyingSavedPosition = true"))
        #expect(restore.contains("PatternPDFViewportAnchorGeometry.verticalContentOffset"))
        #expect(restore.contains("scroll.setContentOffset"))
        #expect(!restore.contains("pdfWidthScaleRatio ="))
        #expect(!restore.contains("highlight"))
    }

    @Test func rotationAnchorSurvivesAnAppSwitchDuringPDFKitSettling() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let inactivity = try #require(
            pdf.slice(from: "private func prepareForInactivity", to: "private func scheduleForegroundPositionRestore")
        )
        let foreground = try #require(
            pdf.slice(from: "private func scheduleForegroundPositionRestore", to: "private func cancelForegroundPositionRestore")
        )
        let schedule = try #require(
            pdf.slice(from: "private func scheduleCurrentPositionRestore", to: "private func restorePosition")
        )

        #expect(pdf.contains("private var foregroundVisiblePageVerticalAnchor"))
        #expect(inactivity.contains("foregroundVisiblePageVerticalAnchor = isApplyingSavedPosition"))
        #expect(inactivity.contains("? visiblePageVerticalAnchor"))
        #expect(foreground.contains("let savedVisiblePageVerticalAnchor = foregroundVisiblePageVerticalAnchor"))
        #expect(foreground.contains("visiblePageVerticalAnchor: savedVisiblePageVerticalAnchor"))
        #expect(schedule.contains("if let visiblePageVerticalAnchor"))
        #expect(schedule.contains("restoreRotationPosition(visiblePageVerticalAnchor, in: view)"))
        #expect(schedule.contains("foregroundVisiblePageVerticalAnchor = nil"))
    }

    @Test func rotationDuringForegroundSettlingCompletesForegroundCleanup() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let rotation = try #require(
            pdf.slice(from: "private func scheduleRotationPositionRestore", to: "private func restoreRotationPosition")
        )

        #expect(rotation.contains("let completesForegroundRestore = isPositionSamplingSuspended"))
        #expect(rotation.contains("if completesForegroundRestore"))
        #expect(rotation.contains("foregroundPositionSnapshot = nil"))
        #expect(rotation.contains("foregroundVisiblePageVerticalAnchor = nil"))
        #expect(rotation.contains("isPositionSamplingSuspended = false"))
    }

    @Test func viewportAndSavedWidthUseTheSameModeSpecificBaseline() throws {
        let pdf = try source("KnitNote/Patterns/PDFReaderView.swift")
        let application = try #require(
            pdf.slice(from: "private func applyScaleMode", to: "private func scheduleUserScaleCapture")
        )
        let publication = try #require(
            pdf.slice(from: "private func publishViewport", to: "private func installScrollObservation")
        )

        #expect(pdf.contains("private func fitWidthBaseline(for view: PDFView, mode: PatternPDFScaleMode)"))
        #expect(application.contains("fitWidthBaseline(for: view, mode: mode)"))
        #expect(publication.contains("fitWidthBaseline(for: view, mode: latestScaleMode)"))
        #expect(!publication.contains("fitWidthScaleFactor: view.scaleFactorForSizeToFit"))
    }

    @Test func visiblePageSynchronizationKeepsTheSharedWidthAndPerPageOffsets() throws {
        let document = try source("Sources/KnitNoteCore/Patterns/PatternDocument.swift")
        let synchronization = try #require(
            document.slice(from: "public mutating func synchronizeVisiblePDFPage", to: "public mutating func saveCurrentPage")
        )

        #expect(!synchronization.contains("zoomScale = 1"))
        #expect(!synchronization.contains("offsetX = 0"))
        #expect(!synchronization.contains("offsetY = 0"))
        #expect(!synchronization.contains("pdfWidthScaleRatio"))
    }

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
