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
    let url: URL; let navigator: PDFPageNavigator; let scaleMode: PatternPDFScaleMode; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool; let onReady: @MainActor () -> Void
    func makeNSView(context: Context) -> PDFView { makeView(context: context) }
    func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view, state: state, scaleMode: scaleMode) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError, navigator: navigator, onReady: onReady) }
    private func makeView(context: Context) -> PDFView { context.coordinator.make(url: url) }
}
#else
struct PDFReaderView: UIViewRepresentable {
    let url: URL; let navigator: PDFPageNavigator; let scaleMode: PatternPDFScaleMode; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool; let onReady: @MainActor () -> Void
    func makeUIView(context: Context) -> PDFView { context.coordinator.make(url: url) }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.update(view, state: state, scaleMode: scaleMode) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError, navigator: navigator, onReady: onReady) }
}
#endif

extension PDFReaderView {
    @MainActor final class Coordinator: NSObject, @unchecked Sendable {
        @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var error: Bool; private let initialState: PatternReadingState; private let navigator: PDFPageNavigator; private let onReady: @MainActor () -> Void; private var restoreGate = PatternReadingRestoreGate(); private var pageRequestGate = PatternPDFPageRequestGate(); private var restoreAttempts = 0; private var reportedReady = false; private weak var view: PDFView?; nonisolated(unsafe) private var timer: Timer?
        private struct ScaleSignature: Equatable {
            let mode: PatternPDFScaleMode
            let size: CGSize
            let pageIndex: Int
        }

        private var latestScaleMode = PatternPDFScaleMode.automatic
        private var lastScaleSignature: ScaleSignature?

        init(state: Binding<PatternReadingState>, pageCount: Binding<Int>, error: Binding<Bool>, navigator: PDFPageNavigator, onReady: @escaping @MainActor () -> Void) { _state=state; initialState=state.wrappedValue; _pageCount=pageCount; _error=error; self.navigator=navigator; self.onReady=onReady }
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
            state: PatternReadingState,
            scaleMode: PatternPDFScaleMode
        ) {
            latestScaleMode = scaleMode
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
#if os(macOS)
            view.layoutSubtreeIfNeeded()
#else
            view.layoutIfNeeded()
#endif
            let signature = ScaleSignature(
                mode: mode,
                size: view.bounds.size,
                pageIndex: document.index(for: page)
            )
            guard signature != lastScaleSignature else { return }
            lastScaleSignature = signature

            switch mode {
            case .automatic:
                view.autoScales = true
            case .fitWidth:
                let pageWidth = page.bounds(for: view.displayBox).width
                let availableWidth = max(1, view.bounds.width - 16)
                guard pageWidth > 0 else { return }
                let widthScale = availableWidth / pageWidth
                let sizeToFit = view.scaleFactorForSizeToFit
                view.autoScales = false
                view.minScaleFactor = min(sizeToFit, widthScale)
                view.maxScaleFactor = max(widthScale * 4, widthScale)
                view.scaleFactor = widthScale
            }
        }

        @objc private func changed(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            if note.name == .PDFViewPageChanged {
                lastScaleSignature = nil
                applyScaleMode(latestScaleMode, to: view)
            }
            sample(view)
        }
        private func sample(_ source: PDFView? = nil) { guard restoreGate.canSample, let view=source ?? view else{return}; let visiblePage=view.currentPage.flatMap{view.document?.index(for:$0)} ?? 0; guard pageRequestGate.accepts(visiblePage) else { return }; state.transitionToPDFPage(visiblePage); state.zoomScale=1; state.offsetX=0; state.offsetY=0 }
        deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    }
}
