import SwiftUI

#if os(macOS)
import AppKit
struct ImageReaderView: NSViewRepresentable {
    let url: URL; @Binding var state: PatternReadingState; @Binding var loadError: Bool
    func makeCoordinator() -> Coordinator { Coordinator(state:$state) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll=NSScrollView(); scroll.allowsMagnification=true; scroll.minMagnification=0.1; scroll.maxMagnification=8
        guard let image=NSImage(contentsOf:url) else { loadError=true; return scroll }
        let imageView=NSImageView(image:image); imageView.imageScaling = .scaleProportionallyUpOrDown; imageView.frame=NSRect(origin:.zero,size:image.size)
        scroll.documentView=imageView; scroll.magnification=state.zoomScale; scroll.contentView.postsBoundsChangedNotifications=true
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.restore(view,state:state) }
    @MainActor final class Coordinator:NSObject { @Binding var state:PatternReadingState; private var restored=false; weak var scroll:NSScrollView?
        init(state:Binding<PatternReadingState>){_state=state}
        func observe(_ scroll:NSScrollView){self.scroll=scroll;NotificationCenter.default.addObserver(self,selector:#selector(changed),name:NSView.boundsDidChangeNotification,object:scroll.contentView);NotificationCenter.default.addObserver(self,selector:#selector(changed),name:NSScrollView.didEndLiveMagnifyNotification,object:scroll)}
        func restore(_ scroll:NSScrollView,state:PatternReadingState){guard !restored else{return};restored=true;scroll.magnification=state.zoomScale;let size=scroll.documentView?.bounds.size ?? .zero;let maxX=max(0,size.width-scroll.contentView.bounds.width);let maxY=max(0,size.height-scroll.contentView.bounds.height);scroll.contentView.scroll(to:NSPoint(x:maxX*state.offsetX,y:maxY*state.offsetY));scroll.reflectScrolledClipView(scroll.contentView)}
        @objc func changed(){guard let s=scroll else{return};state.zoomScale=s.magnification;let size=s.documentView?.bounds.size ?? .zero;let maxX=max(1,size.width-s.contentView.bounds.width);let maxY=max(1,size.height-s.contentView.bounds.height);state.offsetX=Double(s.contentView.bounds.origin.x/maxX);state.offsetY=Double(s.contentView.bounds.origin.y/maxY)}
    }
}
#else
import UIKit
struct ImageReaderView: UIViewRepresentable {
    let url: URL; @Binding var state: PatternReadingState; @Binding var loadError: Bool
    func makeCoordinator() -> Coordinator { Coordinator(state:$state) }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll=UIScrollView(); scroll.minimumZoomScale=0.1; scroll.maximumZoomScale=8; scroll.delegate=context.coordinator
        guard let image=UIImage(contentsOfFile:url.path) else { loadError=true; return scroll }
        let imageView=UIImageView(image:image); imageView.contentMode = .scaleAspectFit; imageView.frame=CGRect(origin:.zero,size:image.size); imageView.isUserInteractionEnabled=true
        scroll.addSubview(imageView); scroll.contentSize=image.size; scroll.zoomScale=CGFloat(state.zoomScale); context.coordinator.imageView=imageView
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.reset(_:))); tap.numberOfTapsRequired=2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ view: UIScrollView, context: Context) { context.coordinator.restore(view,state:state) }
    @MainActor final class Coordinator:NSObject,UIScrollViewDelegate { @Binding var state:PatternReadingState; weak var imageView:UIImageView?; private var restored=false; init(state:Binding<PatternReadingState>){_state=state}
        func restore(_ s:UIScrollView,state:PatternReadingState){guard !restored else{return};restored=true;s.setZoomScale(CGFloat(state.zoomScale),animated:false);s.layoutIfNeeded();let x=max(0,s.contentSize.width-s.bounds.width)*state.offsetX;let y=max(0,s.contentSize.height-s.bounds.height)*state.offsetY;s.setContentOffset(CGPoint(x:x,y:y),animated:false)}
        func viewForZooming(in scrollView:UIScrollView)->UIView?{imageView}
        func scrollViewDidZoom(_ s:UIScrollView){state.zoomScale=Double(s.zoomScale)}
        func scrollViewDidScroll(_ s:UIScrollView){state.offsetX=Double(s.contentOffset.x/max(1,s.contentSize.width-s.bounds.width));state.offsetY=Double(s.contentOffset.y/max(1,s.contentSize.height-s.bounds.height))}
        @objc func reset(_ sender:UITapGestureRecognizer){guard let s=sender.view as? UIScrollView else{return};s.setZoomScale(1,animated:true);s.setContentOffset(.zero,animated:true)} }
}
#endif
