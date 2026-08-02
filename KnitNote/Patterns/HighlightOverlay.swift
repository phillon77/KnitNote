import SwiftUI

struct HighlightOverlay: View {
    let mode: HighlightMode
    @Binding var horizontalPosition: Double
    @Binding var verticalPosition: Double
    let contentRect: CGRect?
    var onPositionCommit: () -> Void = {}
    private let coordinateSpaceName = "patternHighlightCanvas"

    var body: some View {
        GeometryReader { proxy in
            let rect = PatternHighlightGeometry.resolvedContentRect(
                contentRect,
                canvasSize: proxy.size
            )
            let visibleRect = PatternHighlightGeometry.visibleDrawingRect(
                contentRect: rect,
                canvasSize: proxy.size
            )
            let centerInset = PatternHighlightGeometry.centerInset(contentRect: contentRect)
            ZStack {
                if mode == .horizontal || mode == .cross {
                    horizontalBand(in: rect, visibleRect: visibleRect, centerInset: centerInset)
                }
                if mode == .vertical || mode == .cross {
                    verticalBand(in: rect, visibleRect: visibleRect, centerInset: centerInset)
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
        }
        .allowsHitTesting(true)
    }

    private func horizontalBand(
        in rect: CGRect,
        visibleRect: CGRect,
        centerInset: CGFloat
    ) -> some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.yellow.opacity(0.32))
                .frame(width: visibleRect.width)
                .frame(height: PatternHighlightMetrics.horizontalVisibleThickness)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: visibleRect.width)
                .frame(height: PatternHighlightMetrics.minimumDragThickness)
        }
        .frame(
            width: visibleRect.width,
            height: PatternHighlightMetrics.minimumDragThickness
        )
        .position(
            x: visibleRect.midX,
            y: PatternHighlightGeometry.coordinate(
                normalized: horizontalPosition,
                origin: rect.minY,
                length: rect.height,
                centerInset: centerInset
            )
        )
        .gesture(
            DragGesture(coordinateSpace: .named(coordinateSpaceName))
                .onChanged { value in
                    horizontalPosition = PatternHighlightGeometry.normalized(
                        coordinate: value.location.y,
                        origin: rect.minY,
                        length: rect.height,
                        centerInset: centerInset
                    )
                }
                .onEnded { _ in
                    onPositionCommit()
                }
        )
        .accessibilityLabel(Text("patterns.highlight.horizontalControl"))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            horizontalPosition = min(1, max(0, horizontalPosition + delta))
            onPositionCommit()
        }
    }

    private func verticalBand(
        in rect: CGRect,
        visibleRect: CGRect,
        centerInset: CGFloat
    ) -> some View {
        ZStack {
            Rectangle().fill(.pink)
                .frame(width: PatternHighlightMetrics.verticalVisibleThickness)
                .frame(height: visibleRect.height)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: PatternHighlightMetrics.minimumDragThickness)
                .frame(height: visibleRect.height)
        }
        .frame(
            width: PatternHighlightMetrics.minimumDragThickness,
            height: visibleRect.height
        )
        .position(
            x: PatternHighlightGeometry.coordinate(
                normalized: verticalPosition,
                origin: rect.minX,
                length: rect.width,
                centerInset: centerInset
            ),
            y: visibleRect.midY
        )
        .gesture(
            DragGesture(coordinateSpace: .named(coordinateSpaceName))
                .onChanged { value in
                    verticalPosition = PatternHighlightGeometry.normalized(
                        coordinate: value.location.x,
                        origin: rect.minX,
                        length: rect.width,
                        centerInset: centerInset
                    )
                }
                .onEnded { _ in
                    onPositionCommit()
                }
        )
        .accessibilityLabel(Text("patterns.highlight.verticalControl"))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            verticalPosition = min(1, max(0, verticalPosition + delta))
            onPositionCommit()
        }
    }
}
