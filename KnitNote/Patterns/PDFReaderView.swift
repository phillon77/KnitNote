import PDFKit
import SwiftUI

@MainActor final class PDFPageNavigator: ObservableObject {
    private weak var view: PDFView?
    private var request: ((Int) -> Void)?

    func attach(_ view: PDFView, request: @escaping (Int) -> Void) {
        self.view = view
        self.request = request
    }

    func go(to pageIndex: Int) {
        guard let view, let document = view.document, document.pageCount > 0 else { return }
        let target = min(document.pageCount - 1, max(0, pageIndex))
        guard let page = document.page(at: target) else { return }
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
        private var scaleCaptureRevision: UInt64 = 0
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
            navigator.attach(view) { [weak self] target in self?.pageRequestGate.request(target) }
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
                    self.state.offsetX=0
                    self.state.offsetY=0
                    self.restoreGate.didRestore()
                    self.applyScaleMode(self.latestScaleMode, to: view)
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
            invalidatePendingScaleCapture()
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

        private func invalidatePendingScaleCapture() {
            scaleCaptureRevision &+= 1
            scaleCaptureTask?.cancel()
            scaleCaptureTask = nil
        }

        private func scheduleUserScaleCapture(from view: PDFView) {
            guard restoreGate.canSample, !isApplyingSavedScale,
                  let signature = scaleSignature(for: view, mode: latestScaleMode),
                  signature == lastScaleSignature,
                  fitWidthBaseline(for: view, mode: latestScaleMode) != nil
            else { return }

            let observedScale = Double(view.scaleFactor)
            guard observedScale.isFinite, observedScale > 0 else { return }
            if let lastAppliedScale,
               lastAppliedScale.signature == signature,
               scalesMatch(observedScale, lastAppliedScale.scaleFactor) {
                return
            }

            scaleCaptureTask?.cancel()
            scaleCaptureRevision &+= 1
            let revision = scaleCaptureRevision
            scaleCaptureTask = Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, let view,
                      self.restoreGate.canSample, !self.isApplyingSavedScale,
                      self.scaleCaptureRevision == revision,
                      let settledSignature = self.scaleSignature(for: view, mode: self.latestScaleMode),
                      settledSignature == signature,
                      settledSignature == self.lastScaleSignature
                else { return }

                let settledScale = Double(view.scaleFactor)
                guard self.scalesMatch(settledScale, observedScale),
                      let baseline = self.fitWidthBaseline(for: view, mode: self.latestScaleMode)
                else { return }

                let ratio = PatternPDFScalePolicy.ratio(
                    currentScale: settledScale,
                    fitWidthScale: baseline
                )
                guard !self.scalesMatch(ratio, self.state.pdfWidthScaleRatio) else { return }
                var updatedState = self.state
                updatedState.pdfWidthScaleRatio = ratio
                self.state = updatedState
                self.lastAppliedScale = nil
                self.publishViewport(from: view)
            }
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
        private func findScrollViews(in root: UIView) -> [UIScrollView] {
            var result = root.subviews.flatMap(findScrollViews(in:))
            if let scroll = root as? UIScrollView {
                result.insert(scroll, at: 0)
            }
            return result
        }
#endif

        @objc private func changed(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            installScrollObservation(in: view)
            if note.name == .PDFViewPageChanged {
                lastScaleSignature = nil
                applyScaleMode(latestScaleMode, to: view)
            } else if note.name == .PDFViewScaleChanged {
                scheduleUserScaleCapture(from: view)
            }
            publishViewport(from: view)
            sample(view)
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
