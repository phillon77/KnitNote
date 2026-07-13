import PDFKit
import SwiftUI

#if os(macOS)
struct PDFReaderView: NSViewRepresentable {
    let url: URL; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool
    func makeNSView(context: Context) -> PDFView { makeView(context: context) }
    func updateNSView(_ view: PDFView, context: Context) { context.coordinator.restore(view, state: state) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError) }
    private func makeView(context: Context) -> PDFView { context.coordinator.make(url: url) }
}
#else
struct PDFReaderView: UIViewRepresentable {
    let url: URL; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool
    func makeUIView(context: Context) -> PDFView { context.coordinator.make(url: url) }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.restore(view, state: state) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError) }
}
#endif

extension PDFReaderView {
    @MainActor final class Coordinator: NSObject, @unchecked Sendable {
        @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var error: Bool; private let initialState: PatternReadingState; private var restoreGate = PatternReadingRestoreGate(); private var restoreAttempts = 0; private weak var view: PDFView?; nonisolated(unsafe) private var timer: Timer?
        init(state: Binding<PatternReadingState>, pageCount: Binding<Int>, error: Binding<Bool>) { _state=state; initialState=state.wrappedValue; _pageCount=pageCount; _error=error }
        func make(url: URL) -> PDFView {
            let view=PDFView(); view.autoScales=true; view.displayMode = .singlePage; view.displayDirection = .horizontal
#if !os(macOS)
            view.usePageViewController(true, withViewOptions: nil)
#endif
            guard let doc=PDFDocument(url:url), doc.pageCount > 0 else { error=true; return view }
            view.document=doc; pageCount=doc.pageCount; self.view=view
            NotificationCenter.default.addObserver(self, selector:#selector(changed(_:)), name:.PDFViewPageChanged, object:view)
            NotificationCenter.default.addObserver(self, selector:#selector(changed(_:)), name:.PDFViewScaleChanged, object:view)
            timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.sample()}
            return view
        }
        func restore(_ view: PDFView, state: PatternReadingState) {
            if restoreGate.beginRestoring() {
                scheduleRestore(view)
            } else if restoreGate.canSample {
                showRequestedPage(in: view, state: state)
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
                } else if self.restoreAttempts < 5 {
                    self.scheduleRestore(view)
                }
            }
        }
        private func showRequestedPage(in view: PDFView, state: PatternReadingState) {
            guard let doc=view.document, doc.pageCount > 0 else { return }
            let targetIndex=state.pdfRestorePageIndex(pageCount:doc.pageCount)
            let currentIndex=view.currentPage.map { doc.index(for:$0) }
            guard currentIndex != targetIndex, let page=doc.page(at:targetIndex) else { return }
            view.autoScales=true
            view.go(to:page)
        }
        @objc private func changed(_ note: Notification) { sample(note.object as? PDFView) }
        private func sample(_ source: PDFView? = nil) { guard restoreGate.canSample, let view=source ?? view else{return}; state.pageIndex=view.currentPage.flatMap{view.document?.index(for:$0)} ?? 0; state.zoomScale=1; state.offsetX=0; state.offsetY=0 }
        deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    }
}
