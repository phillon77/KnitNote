import PDFKit
import SwiftUI

private enum HighlightDragAxis { case horizontal, vertical }

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
        @Binding var state: PatternReadingState; @Binding var pageCount: Int; @Binding var error: Bool; private let initialState: PatternReadingState; private var restoreGate = PatternReadingRestoreGate(); private var restoreAttempts = 0; private weak var view: PDFView?; private var highlightAnnotations:[PDFAnnotation]=[]; private var activeAxis:HighlightDragAxis?; nonisolated(unsafe) private var timer: Timer?
        init(state: Binding<PatternReadingState>, pageCount: Binding<Int>, error: Binding<Bool>) { _state=state; initialState=state.wrappedValue; _pageCount=pageCount; _error=error }
        func make(url: URL) -> PDFView {
            let view=PDFView(); view.autoScales=true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
            guard let doc=PDFDocument(url:url), doc.pageCount > 0 else { error=true; return view }
            view.document=doc; pageCount=doc.pageCount; self.view=view
            NotificationCenter.default.addObserver(self, selector:#selector(changed(_:)), name:.PDFViewPageChanged, object:view)
            NotificationCenter.default.addObserver(self, selector:#selector(changed(_:)), name:.PDFViewScaleChanged, object:view)
#if os(macOS)
            let pan=NSPanGestureRecognizer(target:self,action:#selector(handlePan(_:))); pan.delegate=self; view.addGestureRecognizer(pan)
#else
            let pan=UIPanGestureRecognizer(target:self,action:#selector(handlePan(_:))); pan.delegate=self; pan.cancelsTouchesInView=false; view.addGestureRecognizer(pan)
#endif
            timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.sample()}
            return view
        }
        func restore(_ view: PDFView, state: PatternReadingState) {
            refreshHighlights(in:view)
            guard restoreGate.beginRestoring() else { return }
            scheduleRestore(view)
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
            if initialState.zoomScale > 0.1 { view.scaleFactor=CGFloat(initialState.zoomScale) }
            let bounds=page.bounds(for:.mediaBox)
            let point=CGPoint(x:bounds.minX+bounds.width*initialState.offsetX,y:bounds.minY+bounds.height*initialState.offsetY)
            view.go(to:PDFDestination(page:page,at:point))
            Task { @MainActor [weak self, weak view] in
                await Task.yield()
                guard let self, let view, let doc=view.document else { return }
                let current=view.currentDestination?.page.map{doc.index(for:$0)}
                if current == self.initialState.pdfRestorePageIndex(pageCount:doc.pageCount) {
                    self.restoreGate.didRestore()
                } else if self.restoreAttempts < 5 {
                    self.scheduleRestore(view)
                }
            }
        }
        @objc private func changed(_ note: Notification) { let source=note.object as? PDFView; sample(source); if let source { refreshHighlights(in:source) } }
        private func sample(_ source: PDFView? = nil) {
            guard restoreGate.canSample, let view=source ?? view else{return}
            state.zoomScale=Double(view.scaleFactor)
            guard let doc=view.document, let destination=view.currentDestination, let page=destination.page else{return}
            let bounds=page.bounds(for:.mediaBox)
            state.setPDFAnchor(
                pageIndex:doc.index(for:page),
                offsetX:Double((destination.point.x-bounds.minX)/max(1,bounds.width)),
                offsetY:Double((destination.point.y-bounds.minY)/max(1,bounds.height))
            )
        }
        private func refreshHighlights(in view:PDFView) {
            clearHighlights()
            guard state.highlightEnabled, let doc=view.document, doc.pageCount > 0 else{return}
            let index=min(state.highlightPageIndex,doc.pageCount-1); guard let page=doc.page(at:index) else{return}
            let bounds=page.bounds(for:.mediaBox); let thickness=44/max(0.1,view.scaleFactor)
            if state.highlightMode == .horizontal || state.highlightMode == .cross {
                let center=bounds.maxY-bounds.height*state.highlightPosition
                let rect=CGRect(x:bounds.minX,y:max(bounds.minY,min(bounds.maxY-thickness,center-thickness/2)),width:bounds.width,height:thickness)
                addHighlight(to:page,bounds:rect,horizontal:true)
            }
            if state.highlightMode == .vertical || state.highlightMode == .cross {
                let center=bounds.minX+bounds.width*state.verticalHighlightPosition
                let rect=CGRect(x:max(bounds.minX,min(bounds.maxX-thickness,center-thickness/2)),y:bounds.minY,width:thickness,height:bounds.height)
                addHighlight(to:page,bounds:rect,horizontal:false)
            }
        }
        private func addHighlight(to page:PDFPage,bounds:CGRect,horizontal:Bool) {
            let annotation=PDFAnnotation(bounds:bounds,forType:.square,withProperties:nil); annotation.border=PDFBorder(); annotation.border?.lineWidth=0
#if os(macOS)
            annotation.color = .clear; annotation.interiorColor = (horizontal ? NSColor.systemYellow : NSColor.systemPink).withAlphaComponent(0.32)
#else
            annotation.color = .clear; annotation.interiorColor = (horizontal ? UIColor.systemYellow : UIColor.systemPink).withAlphaComponent(0.32)
#endif
            page.addAnnotation(annotation); highlightAnnotations.append(annotation)
        }
        private func clearHighlights() { for annotation in highlightAnnotations { annotation.page?.removeAnnotation(annotation) }; highlightAnnotations.removeAll() }
        private func hitAxis(at point:CGPoint,in view:PDFView)->HighlightDragAxis? {
            for annotation in highlightAnnotations.reversed() { guard let page=annotation.page else{continue}; if view.convert(annotation.bounds,from:page).insetBy(dx:-12,dy:-12).contains(point) { return annotation.bounds.width > annotation.bounds.height ? .horizontal : .vertical } }; return nil
        }
        private func moveHighlight(to point:CGPoint,in view:PDFView) {
            guard let axis=activeAxis,let doc=view.document,let page=view.page(for:point,nearest:true) else{return}; let p=view.convert(point,to:page); let b=page.bounds(for:.mediaBox); state.highlightPageIndex=doc.index(for:page)
            if axis == .horizontal { state.highlightPosition=min(1,max(0,Double((b.maxY-p.y)/max(1,b.height)))) } else { state.verticalHighlightPosition=min(1,max(0,Double((p.x-b.minX)/max(1,b.width)))) }
            refreshHighlights(in:view)
        }
#if os(macOS)
        @objc fileprivate func handlePan(_ gesture:NSPanGestureRecognizer) { guard let view else{return}; if gesture.state == .began { activeAxis=hitAxis(at:gesture.location(in:view),in:view) }; if gesture.state == .began || gesture.state == .changed { moveHighlight(to:gesture.location(in:view),in:view) }; if gesture.state == .ended || gesture.state == .cancelled { activeAxis=nil } }
#else
        @objc fileprivate func handlePan(_ gesture:UIPanGestureRecognizer) { guard let view else{return}; if gesture.state == .began { activeAxis=hitAxis(at:gesture.location(in:view),in:view) }; if gesture.state == .began || gesture.state == .changed { moveHighlight(to:gesture.location(in:view),in:view) }; if gesture.state == .ended || gesture.state == .cancelled { activeAxis=nil } }
#endif
        deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    }
}

#if os(macOS)
extension PDFReaderView.Coordinator:NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer:NSGestureRecognizer)->Bool { guard let view else{return false}; return hitAxis(at:gestureRecognizer.location(in:view),in:view) != nil }
}
#else
extension PDFReaderView.Coordinator:UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool { guard let view else{return false}; return hitAxis(at:touch.location(in:view),in:view) != nil }
}
#endif
