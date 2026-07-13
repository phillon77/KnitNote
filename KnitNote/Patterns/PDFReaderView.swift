import PDFKit
import SwiftUI

#if os(macOS)
struct PDFReaderView: NSViewRepresentable {
    let url: URL; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool
    func makeNSView(context: Context) -> PDFView { context.coordinator.make(url: url) }
    func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError) }
}
#else
struct PDFReaderView: UIViewRepresentable {
    let url: URL; @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var loadError: Bool
    func makeUIView(context: Context) -> PDFView { context.coordinator.make(url: url) }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.update(view) }
    func makeCoordinator() -> Coordinator { Coordinator(state: $state, pageCount: $pageCount, error: $loadError) }
}
#endif

extension PDFReaderView {
    @MainActor final class Coordinator: NSObject, @unchecked Sendable {
        @Binding private var state: PatternReadingState
        @Binding private var pageCount: Int
        @Binding private var error: Bool
        private let initialState: PatternReadingState
        private var restoreGate = PatternReadingRestoreGate()
        private var wasHighlightEnabled: Bool
        private weak var view: PDFView?
        nonisolated(unsafe) private var timer: Timer?
#if os(macOS)
        private let horizontalBand = NSView()
        private let verticalBand = NSView()
#else
        private let horizontalBand = UIView()
        private let verticalBand = UIView()
#endif

        init(state: Binding<PatternReadingState>, pageCount: Binding<Int>, error: Binding<Bool>) {
            _state = state; initialState = state.wrappedValue; wasHighlightEnabled = state.wrappedValue.highlightEnabled
            _pageCount = pageCount; _error = error
        }

        func make(url: URL) -> PDFView {
            let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
            guard let document = PDFDocument(url: url), document.pageCount > 0 else { error = true; return view }
            view.document = document; pageCount = document.pageCount; self.view = view
            configureBands(in: view)
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewScaleChanged, object: view)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            return view
        }

        func update(_ view: PDFView) {
            if state.highlightEnabled && !wasHighlightEnabled, let document = view.document, let page = view.currentPage {
                state.highlightPageIndex = document.index(for: page)
            }
            wasHighlightEnabled = state.highlightEnabled
            refreshBands(in: view)
            guard restoreGate.beginRestoring() else { return }
            Task { @MainActor [weak self, weak view] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let view, let document = view.document, document.pageCount > 0 else { return }
                let index = self.initialState.pdfRestorePageIndex(pageCount: document.pageCount)
                guard let page = document.page(at: index) else { return }
#if os(macOS)
                view.layoutSubtreeIfNeeded()
#else
                view.layoutIfNeeded()
#endif
                if self.initialState.zoomScale > 0.1 { view.scaleFactor = CGFloat(self.initialState.zoomScale) }
                let bounds = page.bounds(for: .mediaBox)
                let point = CGPoint(x: bounds.minX + bounds.width * self.initialState.offsetX, y: bounds.minY + bounds.height * self.initialState.offsetY)
                view.go(to: PDFDestination(page: page, at: point))
                await Task.yield()
                self.restoreGate.didRestore(); self.sample(view); self.refreshBands(in: view)
            }
        }

        private func tick() { guard let view else { return }; sample(view); refreshBands(in: view) }
        @objc private func changed(_ note: Notification) { guard let view = note.object as? PDFView else { return }; sample(view); refreshBands(in: view) }

        private func sample(_ view: PDFView) {
            guard restoreGate.canSample else { return }
            state.zoomScale = Double(view.scaleFactor)
            guard let document = view.document else { return }
            guard let destination = view.currentDestination, let page = destination.page else {
                if let page = view.currentPage { state.pageIndex = document.index(for: page) }
                return
            }
            let bounds = page.bounds(for: .mediaBox)
            state.setPDFAnchor(
                pageIndex: document.index(for: page),
                offsetX: Double((destination.point.x - bounds.minX) / max(1, bounds.width)),
                offsetY: Double((destination.point.y - bounds.minY) / max(1, bounds.height))
            )
        }

        private func refreshBands(in view: PDFView) {
            guard state.highlightEnabled, let document = view.document, document.pageCount > 0 else { horizontalBand.isHidden = true; verticalBand.isHidden = true; return }
            let index = min(state.highlightPageIndex, document.pageCount - 1)
            guard let page = document.page(at: index) else { return }
            let pageBounds = page.bounds(for: .mediaBox); let thickness = 44 / max(0.1, view.scaleFactor)
            let horizontalCenter = pageBounds.maxY - pageBounds.height * state.highlightPosition
            let horizontalRect = CGRect(x: pageBounds.minX, y: max(pageBounds.minY, min(pageBounds.maxY - thickness, horizontalCenter - thickness / 2)), width: pageBounds.width, height: thickness)
            let verticalCenter = pageBounds.minX + pageBounds.width * state.verticalHighlightPosition
            let verticalRect = CGRect(x: max(pageBounds.minX, min(pageBounds.maxX - thickness, verticalCenter - thickness / 2)), y: pageBounds.minY, width: thickness, height: pageBounds.height)
            horizontalBand.frame = view.convert(horizontalRect, from: page).standardized
            verticalBand.frame = view.convert(verticalRect, from: page).standardized
            horizontalBand.isHidden = !(state.highlightMode == .horizontal || state.highlightMode == .cross)
            verticalBand.isHidden = !(state.highlightMode == .vertical || state.highlightMode == .cross)
#if os(macOS)
            view.addSubview(horizontalBand, positioned: .above, relativeTo: nil); view.addSubview(verticalBand, positioned: .above, relativeTo: nil)
#else
            view.bringSubviewToFront(horizontalBand); view.bringSubviewToFront(verticalBand)
#endif
        }

        private func moveBand(horizontal: Bool, point: CGPoint, in view: PDFView) {
            guard let document = view.document, let page = view.page(for: point, nearest: true) else { return }
            let pagePoint = view.convert(point, to: page); let bounds = page.bounds(for: .mediaBox)
            state.highlightPageIndex = document.index(for: page)
            if horizontal { state.highlightPosition = min(1, max(0, Double((bounds.maxY - pagePoint.y) / max(1, bounds.height)))) }
            else { state.verticalHighlightPosition = min(1, max(0, Double((pagePoint.x - bounds.minX) / max(1, bounds.width)))) }
            refreshBands(in: view)
        }

#if os(macOS)
        private func configureBands(in view: PDFView) {
            for (band, color) in [(horizontalBand, NSColor.systemYellow), (verticalBand, NSColor.systemPink)] { band.wantsLayer = true; band.layer?.backgroundColor = color.withAlphaComponent(0.32).cgColor; band.layer?.cornerRadius = 6; view.addSubview(band) }
            horizontalBand.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragHorizontal(_:))))
            verticalBand.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragVertical(_:))))
        }
        @objc private func dragHorizontal(_ gesture: NSPanGestureRecognizer) { guard let view else { return }; moveBand(horizontal: true, point: gesture.location(in: view), in: view) }
        @objc private func dragVertical(_ gesture: NSPanGestureRecognizer) { guard let view else { return }; moveBand(horizontal: false, point: gesture.location(in: view), in: view) }
#else
        private func configureBands(in view: PDFView) {
            for (band, color) in [(horizontalBand, UIColor.systemYellow), (verticalBand, UIColor.systemPink)] { band.backgroundColor = color.withAlphaComponent(0.32); band.layer.cornerRadius = 6; view.addSubview(band) }
            horizontalBand.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragHorizontal(_:))))
            verticalBand.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragVertical(_:))))
        }
        @objc private func dragHorizontal(_ gesture: UIPanGestureRecognizer) { guard let view else { return }; moveBand(horizontal: true, point: gesture.location(in: view), in: view) }
        @objc private func dragVertical(_ gesture: UIPanGestureRecognizer) { guard let view else { return }; moveBand(horizontal: false, point: gesture.location(in: view), in: view) }
#endif

        deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    }
}
