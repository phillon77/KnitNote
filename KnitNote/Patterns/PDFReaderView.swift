import PDFKit
import SwiftUI

@MainActor final class PDFPageNavigator: ObservableObject {
    private weak var view: PDFView?
    private var request: ((Int) -> Void)?
    private var flushPendingScaleCaptureAction: (() -> Void)?
    private var captureCurrentPositionAction: (() -> Void)?
    private var restoreCurrentPositionAction: (() -> Void)?
    private var prepareForInactivityAction: (() -> Void)?
    private var restoreAfterForegroundAction: (() -> Void)?
    private var cancelForegroundRestoreAction: (() -> Void)?

    func attach(
        _ view: PDFView,
        request: @escaping (Int) -> Void,
        flushPendingScaleCapture: @escaping () -> Void,
        captureCurrentPosition: @escaping () -> Void,
        restoreCurrentPosition: @escaping () -> Void,
        prepareForInactivity: @escaping () -> Void,
        restoreAfterForeground: @escaping () -> Void,
        cancelForegroundRestore: @escaping () -> Void
    ) {
        self.view = view
        self.request = request
        flushPendingScaleCaptureAction = flushPendingScaleCapture
        captureCurrentPositionAction = captureCurrentPosition
        restoreCurrentPositionAction = restoreCurrentPosition
        prepareForInactivityAction = prepareForInactivity
        restoreAfterForegroundAction = restoreAfterForeground
        cancelForegroundRestoreAction = cancelForegroundRestore
    }

    func flushPendingScaleCapture() {
        flushPendingScaleCaptureAction?()
    }

    func captureCurrentPosition() {
        captureCurrentPositionAction?()
    }

    func restoreCurrentPosition() {
        restoreCurrentPositionAction?()
    }

    func prepareForInactivity() {
        prepareForInactivityAction?()
    }

    func restoreAfterForeground() {
        restoreAfterForegroundAction?()
    }

    func go(to pageIndex: Int) {
        guard let view, let document = view.document, document.pageCount > 0 else { return }
        let target = min(document.pageCount - 1, max(0, pageIndex))
        guard let page = document.page(at: target) else { return }
        cancelForegroundRestoreAction?()
        captureCurrentPosition()
        flushPendingScaleCapture()
        request?(target)
        view.go(to: page)
    }
}

#if os(macOS)
struct PDFReaderView: NSViewRepresentable {
    let url: URL; let navigator: PDFPageNavigator; let scaleMode: PatternPDFScaleMode; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool; @Binding var viewport: PatternPDFViewportState; let onReady: @MainActor () -> Void

    init(
        url: URL,
        navigator: PDFPageNavigator,
        scaleMode: PatternPDFScaleMode,
        state: Binding<PatternReadingState>,
        pageCount: Binding<Int>,
        loadError: Binding<Bool>,
        viewport: Binding<PatternPDFViewportState> = .constant(PatternPDFViewportState()),
        onReady: @escaping @MainActor () -> Void
    ) {
        self.url = url
        self.navigator = navigator
        self.scaleMode = scaleMode
        _state = state
        _pageCount = pageCount
        _loadError = loadError
        _viewport = viewport
        self.onReady = onReady
    }

    func makeNSView(context: Context) -> PDFView { makeView(context: context) }
    func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view, state: $state, viewport: $viewport, scaleMode: scaleMode) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError, viewport: $viewport, navigator: navigator, onReady: onReady) }
    private func makeView(context: Context) -> PDFView { context.coordinator.make(url: url) }
}
#else
struct PDFReaderView: UIViewRepresentable {
    let url: URL; let navigator: PDFPageNavigator; let scaleMode: PatternPDFScaleMode; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool; @Binding var viewport: PatternPDFViewportState; let onReady: @MainActor () -> Void

    init(
        url: URL,
        navigator: PDFPageNavigator,
        scaleMode: PatternPDFScaleMode,
        state: Binding<PatternReadingState>,
        pageCount: Binding<Int>,
        loadError: Binding<Bool>,
        viewport: Binding<PatternPDFViewportState> = .constant(PatternPDFViewportState()),
        onReady: @escaping @MainActor () -> Void
    ) {
        self.url = url
        self.navigator = navigator
        self.scaleMode = scaleMode
        _state = state
        _pageCount = pageCount
        _loadError = loadError
        _viewport = viewport
        self.onReady = onReady
    }

    func makeUIView(context: Context) -> PDFView { context.coordinator.make(url: url) }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.update(view, state: $state, viewport: $viewport, scaleMode: scaleMode) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError, viewport: $viewport, navigator: navigator, onReady: onReady) }
}
#endif

extension PDFReaderView {
    @MainActor final class Coordinator: NSObject, @unchecked Sendable {
        @Binding var state: PatternReadingState
        @Binding var pageCount: Int
        @Binding var error: Bool
        @Binding private var viewport: PatternPDFViewportState
        private let initialState: PatternReadingState
        private let navigator: PDFPageNavigator
        private let onReady: @MainActor () -> Void
        private var restoreGate = PatternReadingRestoreGate()
        private var pageRequestGate = PatternPDFPageRequestGate()
        private var viewportPublicationGate = PatternPDFViewportPublicationGate()
        private var restoreAttempts = 0
        private var reportedReady = false
        private weak var view: PDFView?
        nonisolated(unsafe) private var timer: Timer?
#if os(macOS)
        private weak var observedScrollView: NSScrollView?
        nonisolated(unsafe) private var boundsObservation: NSObjectProtocol?
#else
        nonisolated(unsafe) private var contentOffsetObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
#endif
        private struct ScaleSignature: Equatable {
            let mode: PatternPDFScaleMode
            let size: CGSize
            let pageIndex: Int
        }

        private var latestScaleMode = PatternPDFScaleMode.automatic
        private var lastScaleSignature: ScaleSignature?
        private var isApplyingSavedScale = false
        private var scaleCaptureTask: Task<Void, Never>?
        private var positionRestoreTask: Task<Void, Never>?
        private var isApplyingSavedPosition = false
        private var foregroundPositionSnapshot: PatternReadingState?
        private var isPositionSamplingSuspended = false
        private var positionRestoreRevision: UInt64 = 0
        private var scaleCaptureGate = PatternPDFScaleCaptureGate()
        private var scaleCaptureContext: UInt64 = 0
        private var lastAppliedScale: (signature: ScaleSignature, scaleFactor: Double)?
        private var lastPublishedViewport: PatternPDFViewportState?

        init(state: Binding<PatternReadingState>, pageCount: Binding<Int>, error: Binding<Bool>, viewport: Binding<PatternPDFViewportState>, navigator: PDFPageNavigator, onReady: @escaping @MainActor () -> Void) { _state=state; initialState=state.wrappedValue; _pageCount=pageCount; _error=error; _viewport=viewport; self.navigator=navigator; self.onReady=onReady }
        func make(url: URL) -> PDFView {
            let view=PDFView(); view.autoScales=true; view.displayMode = .singlePage; view.displayDirection = .horizontal
#if !os(macOS)
            view.usePageViewController(true, withViewOptions: nil)
#endif
            guard let doc=PDFDocument(url:url), doc.pageCount > 0 else {
                Task { @MainActor [weak self] in self?.error = true }
                return view
            }
            view.document=doc; self.view=view
            installScrollObservation(in: view)
            navigator.attach(
                view,
                request: { [weak self] target in self?.pageRequestGate.request(target) },
                flushPendingScaleCapture: { [weak self] in self?.flushPendingScaleCapture() },
                captureCurrentPosition: { [weak self] in self?.captureCurrentPosition() },
                restoreCurrentPosition: { [weak self] in self?.scheduleCurrentPositionRestore() },
                prepareForInactivity: { [weak self] in self?.prepareForInactivity() },
                restoreAfterForeground: { [weak self] in self?.scheduleForegroundPositionRestore() },
                cancelForegroundRestore: { [weak self] in self?.cancelForegroundPositionRestore() }
            )
            let loadedPageCount = doc.pageCount
            Task { @MainActor [weak self] in self?.pageCount = loadedPageCount }
            NotificationCenter.default.addObserver(self, selector:#selector(changed(_:)), name:.PDFViewPageChanged, object:view)
            NotificationCenter.default.addObserver(self, selector:#selector(changed(_:)), name:.PDFViewScaleChanged, object:view)
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sample() }
            }
            return view
        }
        func update(
            _ view: PDFView,
            state: Binding<PatternReadingState>,
            viewport: Binding<PatternPDFViewportState>,
            scaleMode: PatternPDFScaleMode
        ) {
            _state = state
            _viewport = viewport
            latestScaleMode = scaleMode
            installScrollObservation(in: view)
            if restoreGate.beginRestoring() {
                scheduleRestore(view)
            } else if restoreGate.canSample {
                applyScaleMode(scaleMode, to: view)
            }
        }
        private func scheduleRestore(_ view: PDFView) {
            Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let view else { return }
                self.attemptRestore(view)
            }
        }
        private func attemptRestore(_ view: PDFView) {
            guard let doc=view.document, doc.pageCount > 0 else { return }
            let targetIndex=initialState.pdfRestorePageIndex(pageCount:doc.pageCount)
            guard let page=doc.page(at:targetIndex) else { return }
            restoreAttempts += 1
#if os(macOS)
            view.layoutSubtreeIfNeeded()
#else
            view.layoutIfNeeded()
#endif
            installScrollObservation(in: view)
            view.autoScales=true
            view.go(to: page)
            Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self, let view, let doc=view.document else { return }
                let current=view.currentPage.flatMap{doc.index(for:$0)}
                if current == self.initialState.pdfRestorePageIndex(pageCount:doc.pageCount) {
                    self.restoreGate.didRestore()
                    self.applyScaleMode(self.latestScaleMode, to: view)
                    self.scheduleCurrentPositionRestore()
                    self.installScrollObservation(in: view)
                    self.publishViewport(from: view)
                    if !self.reportedReady {
                        self.reportedReady = true
                        self.onReady()
                    }
                } else if self.restoreAttempts < 5 {
                    self.scheduleRestore(view)
                }
            }
        }

        private func applyScaleMode(_ mode: PatternPDFScaleMode, to view: PDFView) {
            guard let page = view.currentPage,
                  let document = view.document
            else { return }
            defer { publishViewport(from: view) }
#if os(macOS)
            view.layoutSubtreeIfNeeded()
#else
            view.layoutIfNeeded()
#endif
            installScrollObservation(in: view)
            let signature = ScaleSignature(
                mode: mode,
                size: view.bounds.size,
                pageIndex: document.index(for: page)
            )
            guard signature != lastScaleSignature else { return }
            flushPendingScaleCapture()
            scaleCaptureGate.invalidate()
            scaleCaptureContext &+= 1
            isApplyingSavedScale = true
            defer { isApplyingSavedScale = false }

            switch mode {
            case .automatic:
                view.autoScales = true
            case .fitWidth:
                view.autoScales = false
            }

            guard let baseline = fitWidthBaseline(for: view, mode: mode) else { return }
            let baselineScale = CGFloat(baseline)
            let sizeToFit = view.scaleFactorForSizeToFit
            view.autoScales = false
            view.minScaleFactor = min(sizeToFit, baselineScale)
            view.maxScaleFactor = max(baselineScale * 4, baselineScale)

            let absoluteScale = PatternPDFScalePolicy.absoluteScale(
                ratio: state.pdfWidthScaleRatio,
                fitWidthScale: baseline,
                allowed: Double(view.minScaleFactor)...Double(view.maxScaleFactor)
            )
            lastScaleSignature = signature
            lastAppliedScale = (signature, absoluteScale)
            view.scaleFactor = CGFloat(absoluteScale)
        }

        private func fitWidthBaseline(for view: PDFView, mode: PatternPDFScaleMode) -> Double? {
            let baseline: CGFloat
            switch mode {
            case .automatic:
                baseline = view.scaleFactorForSizeToFit
            case .fitWidth:
                guard let page = view.currentPage else { return nil }
                let pageWidth = page.bounds(for: view.displayBox).width
                guard pageWidth.isFinite, pageWidth > 0 else { return nil }
                baseline = max(1, view.bounds.width - 16) / pageWidth
            }
            guard baseline.isFinite, baseline > 0 else { return nil }
            return Double(baseline)
        }

        private func scaleSignature(for view: PDFView, mode: PatternPDFScaleMode) -> ScaleSignature? {
            guard let page = view.currentPage,
                  let document = view.document else { return nil }
            return ScaleSignature(
                mode: mode,
                size: view.bounds.size,
                pageIndex: document.index(for: page)
            )
        }

        private func flushPendingScaleCapture() {
            scaleCaptureTask?.cancel()
            scaleCaptureTask = nil
            guard let ratio = scaleCaptureGate.flush(context: scaleCaptureContext) else { return }
            commitScaleRatio(ratio)
        }

        private func discardPendingScaleCapture() {
            scaleCaptureTask?.cancel()
            scaleCaptureTask = nil
            scaleCaptureGate.discardPendingObservation(context: scaleCaptureContext)
        }

        private func captureCurrentPosition() {
            guard restoreGate.canSample, !isApplyingSavedPosition, !isPositionSamplingSuspended,
                  let view,
                  let document = view.document,
                  let page = view.currentPage
            else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex == state.pageIndex else { return }
#if os(macOS)
            guard let destination = view.currentDestination,
                  destination.page === page else { return }
            let pageBounds = page.bounds(for: view.displayBox)
            let anchor = PatternPDFPageAnchorGeometry.normalizedAnchor(
                for: destination.point,
                in: pageBounds
            )
#else
            guard let scroll = contentScrollView(in: view) else { return }
            let range = scrollOffsetRange(for: scroll)
            let anchor = PatternPDFScrollAnchorGeometry.normalizedAnchor(
                for: scroll.contentOffset,
                minimum: range.minimum,
                maximum: range.maximum
            )
#endif
            var updatedState = state
            updatedState.setPDFAnchor(
                pageIndex: pageIndex,
                offsetX: Double(anchor.x),
                offsetY: Double(anchor.y)
            )
            guard updatedState != state else { return }
            state = updatedState
        }

        private func prepareForInactivity() {
            if !isPositionSamplingSuspended {
                captureCurrentPosition()
                foregroundPositionSnapshot = state
            }
            positionRestoreTask?.cancel()
            positionRestoreTask = nil
            positionRestoreRevision &+= 1
            isApplyingSavedPosition = false
            isPositionSamplingSuspended = true
        }

        private func scheduleForegroundPositionRestore() {
            let savedState = foregroundPositionSnapshot ?? state
#if os(macOS)
            foregroundPositionSnapshot = nil
            isPositionSamplingSuspended = false
            scheduleCurrentPositionRestore(savedState: savedState, settleAfterForeground: false)
#else
            scheduleCurrentPositionRestore(savedState: savedState, settleAfterForeground: true)
#endif
        }

        private func cancelForegroundPositionRestore() {
            guard isPositionSamplingSuspended || foregroundPositionSnapshot != nil else { return }
            positionRestoreTask?.cancel()
            positionRestoreTask = nil
            positionRestoreRevision &+= 1
            foregroundPositionSnapshot = nil
            isPositionSamplingSuspended = false
            isApplyingSavedPosition = false
        }

        private func scheduleCurrentPositionRestore(
            savedState: PatternReadingState? = nil,
            settleAfterForeground: Bool = false
        ) {
            guard settleAfterForeground || !isPositionSamplingSuspended else { return }
            positionRestoreTask?.cancel()
            positionRestoreRevision &+= 1
            let revision = positionRestoreRevision
            let savedState = savedState ?? state
            let delays = settleAfterForeground
                ? [Duration.zero, .milliseconds(40), .milliseconds(120), .milliseconds(250)]
                : [Duration.zero, .milliseconds(20), .milliseconds(20), .milliseconds(20), .milliseconds(20)]
            isApplyingSavedPosition = true
            positionRestoreTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                defer {
                    if self.positionRestoreRevision == revision {
                        self.isApplyingSavedPosition = false
                        if settleAfterForeground {
                            self.foregroundPositionSnapshot = nil
                            self.isPositionSamplingSuspended = false
                        }
                    }
                }
                for delay in delays {
                    if delay == .zero {
                        await Task.yield()
                    } else {
                        try? await Task.sleep(for: delay)
                    }
                    guard !Task.isCancelled,
                          self.positionRestoreRevision == revision else { return }
#if os(macOS)
                    view.layoutSubtreeIfNeeded()
#else
                    view.layoutIfNeeded()
#endif
                    if self.restorePosition(savedState, in: view) {
                        self.publishViewport(from: view)
                        if !settleAfterForeground { return }
                    }
                }
            }
        }

        @discardableResult
        private func restorePosition(_ savedState: PatternReadingState, in view: PDFView) -> Bool {
            guard let document = view.document,
                  document.pageCount > 0,
                  let page = document.page(at: savedState.pdfRestorePageIndex(pageCount: document.pageCount))
            else { return false }
#if os(macOS)
            let pageBounds = page.bounds(for: view.displayBox)
            let point = PatternPDFPageAnchorGeometry.pagePoint(
                offsetX: savedState.offsetX,
                offsetY: savedState.offsetY,
                in: pageBounds
            )
            view.go(to: PDFDestination(page: page, at: point))
            return true
#else
            guard view.currentPage === page,
                  let scroll = contentScrollView(in: view) else { return false }
            let range = scrollOffsetRange(for: scroll)
            let contentOffset = PatternPDFScrollAnchorGeometry.contentOffset(
                anchorX: savedState.offsetX,
                anchorY: savedState.offsetY,
                minimum: range.minimum,
                maximum: range.maximum
            )
            scroll.setContentOffset(contentOffset, animated: false)
            return true
#endif
        }

        private func scheduleUserScaleCapture(from view: PDFView) {
            guard restoreGate.canSample, !isApplyingSavedScale,
                  let signature = scaleSignature(for: view, mode: latestScaleMode),
                  signature == lastScaleSignature,
                  let baseline = fitWidthBaseline(for: view, mode: latestScaleMode)
            else { return }

            let observedScale = Double(view.scaleFactor)
            guard observedScale.isFinite, observedScale > 0 else { return }
            if let lastAppliedScale,
               lastAppliedScale.signature == signature,
               scalesMatch(observedScale, lastAppliedScale.scaleFactor) {
                discardPendingScaleCapture()
                return
            }

            scaleCaptureTask?.cancel()
            let context = scaleCaptureContext
            guard let revision = scaleCaptureGate.observe(
                currentScale: observedScale,
                fitWidthScale: baseline,
                context: context
            ) else { return }
            scaleCaptureTask = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, let view else { return }

                let settledScale = Double(view.scaleFactor)
                let settledRatio = self.scaleCaptureGate.settle(
                    revision: revision,
                    context: self.scaleCaptureContext,
                    liveScale: settledScale
                )
                guard self.restoreGate.canSample, !self.isApplyingSavedScale,
                      let settledSignature = self.scaleSignature(for: view, mode: self.latestScaleMode),
                      settledSignature == signature,
                      settledSignature == self.lastScaleSignature,
                      let settledRatio
                else { return }

                self.commitScaleRatio(settledRatio)
                self.publishViewport(from: view)
            }
        }

        private func commitScaleRatio(_ ratio: Double) {
            guard !scalesMatch(ratio, state.pdfWidthScaleRatio) else { return }
            var updatedState = state
            updatedState.pdfWidthScaleRatio = ratio
            state = updatedState
            lastAppliedScale = nil
        }

        private func scalesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
            guard lhs.isFinite, rhs.isFinite else { return false }
            return abs(lhs - rhs) <= max(0.0001, max(abs(lhs), abs(rhs)) * 0.001)
        }

        private func publishViewport(from view: PDFView, isUserInteracting: Bool = false) {
            let page = view.currentPage
            let pageIndex = page.flatMap { view.document?.index(for: $0) } ?? 0
            let platformFrame: CGRect? = {
                guard let page else { return nil }
                let converted = view.convert(page.bounds(for: view.displayBox), from: page)
#if os(macOS)
                let platformFrame = PatternPDFPageFrameGeometry.flippedFrame(converted, in: view.bounds)
#else
                let platformFrame = converted
#endif
                return platformFrame
            }()
            let candidate = PatternPDFViewportState(
                pageIndex: pageIndex,
                pageFrame: platformFrame,
                scaleFactor: view.scaleFactor,
                fitWidthScaleFactor: CGFloat(
                    fitWidthBaseline(for: view, mode: latestScaleMode)
                        ?? PatternPDFScalePolicy.defaultRatio
                ),
                isUserInteracting: isUserInteracting
            )
            guard viewportPublicationGate.accept(candidate) else { return }
            lastPublishedViewport = candidate
            Task { @MainActor [weak self] in
                guard let self, self.lastPublishedViewport == candidate else { return }
                self.viewport = candidate
            }
        }

        private func installScrollObservation(in view: PDFView) {
#if os(macOS)
            guard let scroll = findScrollView(in: view), scroll !== observedScrollView else { return }
            if let boundsObservation {
                NotificationCenter.default.removeObserver(boundsObservation)
            }
            observedScrollView = scroll
            let clipView = scroll.contentView
            clipView.postsBoundsChangedNotifications = true
            boundsObservation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self, weak view, weak scroll] _ in
                Task { @MainActor [weak self, weak view, weak scroll] in
                    guard let self, let view, let scroll else { return }
                    self.publishViewport(
                        from: view,
                        isUserInteracting: scroll.inLiveResize || scroll.contentView.inLiveResize
                    )
                }
            }
#else
            let currentScrollIDs = Set(findScrollViews(in: view).map(ObjectIdentifier.init))
            let staleScrollIDs = contentOffsetObservations.keys.filter { !currentScrollIDs.contains($0) }
            for identifier in staleScrollIDs {
                contentOffsetObservations.removeValue(forKey: identifier)?.invalidate()
            }

            for scroll in findScrollViews(in: view) {
                let identifier = ObjectIdentifier(scroll)
                guard contentOffsetObservations[identifier] == nil else { continue }
                contentOffsetObservations[identifier] = scroll.observe(\.contentOffset, options: [.new]) { [weak self, weak view, weak scroll] _, _ in
                    Task { @MainActor [weak self, weak view, weak scroll] in
                        guard let self, let view, let scroll else { return }
                        self.installScrollObservation(in: view)
                        if scroll.isDragging || scroll.isDecelerating || scroll.isZooming {
                            self.cancelForegroundPositionRestore()
                        }
                        if scroll === self.contentScrollView(in: view) {
                            self.captureCurrentPosition()
                        }
                        self.publishViewport(
                            from: view,
                            isUserInteracting: scroll.isDragging || scroll.isDecelerating || scroll.isZooming
                        )
                    }
                }
            }
#endif
        }

#if os(macOS)
        private func findScrollView(in root: NSView) -> NSScrollView? {
            if let scroll = root as? NSScrollView { return scroll }
            for subview in root.subviews {
                if let scroll = findScrollView(in: subview) { return scroll }
            }
            return nil
        }
#else
        private func contentScrollView(in view: PDFView) -> UIScrollView? {
            findScrollViews(in: view)
                .filter { scroll in
                    guard !scroll.isHidden,
                          scroll.alpha > 0,
                          scroll.bounds.width > 0,
                          scroll.bounds.height > 0 else { return false }
                    let range = scrollOffsetRange(for: scroll)
                    guard range.maximum.y - range.minimum.y > 1 else { return false }
                    let frame = scroll.convert(scroll.bounds, to: view)
                    return !frame.intersection(view.bounds).isNull
                }
                .max { lhs, rhs in
                    visibleArea(of: lhs, in: view) < visibleArea(of: rhs, in: view)
                }
        }

        private func scrollOffsetRange(for scroll: UIScrollView) -> (minimum: CGPoint, maximum: CGPoint) {
            let inset = scroll.adjustedContentInset
            let minimum = CGPoint(x: -inset.left, y: -inset.top)
            return (
                minimum,
                CGPoint(
                    x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + inset.right),
                    y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
                )
            )
        }

        private func visibleArea(of scroll: UIScrollView, in view: PDFView) -> CGFloat {
            let intersection = scroll.convert(scroll.bounds, to: view).intersection(view.bounds)
            guard !intersection.isNull else { return 0 }
            return intersection.width * intersection.height
        }

        private func findScrollViews(in root: UIView) -> [UIScrollView] {
            var result = root.subviews.flatMap(findScrollViews(in:))
            if let scroll = root as? UIScrollView {
                result.insert(scroll, at: 0)
            }
            return result
        }
#endif

        private func cancelForegroundRestoreIfPageChanged(in view: PDFView) {
            guard isPositionSamplingSuspended,
                  let snapshot = foregroundPositionSnapshot,
                  let page = view.currentPage,
                  let document = view.document
            else { return }
            let visiblePage = document.index(for: page)
            guard visiblePage != snapshot.pageIndex else { return }
            cancelForegroundPositionRestore()
        }

        @objc private func changed(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            installScrollObservation(in: view)
            if note.name == .PDFViewPageChanged {
                cancelForegroundRestoreIfPageChanged(in: view)
                lastScaleSignature = nil
                applyScaleMode(latestScaleMode, to: view)
                sample(view)
                scheduleCurrentPositionRestore()
            } else if note.name == .PDFViewScaleChanged {
                scheduleUserScaleCapture(from: view)
            }
            publishViewport(from: view)
            if note.name != .PDFViewPageChanged {
                sample(view)
            }
        }
        private func sample(_ source: PDFView? = nil) {
            guard restoreGate.canSample, let view=source ?? view else { return }
            let visiblePage=view.currentPage.flatMap{view.document?.index(for:$0)} ?? 0
            guard pageRequestGate.accepts(visiblePage) else { return }
            var synchronizedState = state
            guard synchronizedState.synchronizeVisiblePDFPage(visiblePage) else { return }
            state = synchronizedState
        }
        deinit {
            timer?.invalidate()
            positionRestoreTask?.cancel()
#if os(macOS)
            if let boundsObservation {
                NotificationCenter.default.removeObserver(boundsObservation)
            }
#else
            for observation in contentOffsetObservations.values {
                observation.invalidate()
            }
#endif
            NotificationCenter.default.removeObserver(self)
        }
    }
}
