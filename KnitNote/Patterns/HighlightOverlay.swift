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
            ZStack {
                if mode == .horizontal || mode == .cross {
                    horizontalBand(in: rect)
                }
                if mode == .vertical || mode == .cross {
                    verticalBand(in: rect)
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
        }
        .allowsHitTesting(true)
    }

    private func horizontalBand(in rect: CGRect) -> some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.yellow.opacity(0.32))
                .frame(width: rect.width)
                .frame(height: PatternHighlightMetrics.horizontalVisibleThickness)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: rect.width)
                .frame(height: PatternHighlightMetrics.minimumDragThickness)
        }
        .frame(
            width: rect.width,
            height: PatternHighlightMetrics.minimumDragThickness
        )
        .position(
            x: rect.midX,
            y: PatternHighlightGeometry.coordinate(
                normalized: horizontalPosition,
                origin: rect.minY,
                length: rect.height
            )
        )
        .gesture(
            DragGesture(coordinateSpace: .named(coordinateSpaceName))
                .onChanged { value in
                    horizontalPosition = PatternHighlightGeometry.normalized(
                        coordinate: value.location.y,
                        origin: rect.minY,
                        length: rect.height
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

    private func verticalBand(in rect: CGRect) -> some View {
        ZStack {
            Rectangle().fill(.pink)
                .frame(width: PatternHighlightMetrics.verticalVisibleThickness)
                .frame(height: rect.height)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: PatternHighlightMetrics.minimumDragThickness)
                .frame(height: rect.height)
        }
        .frame(
            width: PatternHighlightMetrics.minimumDragThickness,
            height: rect.height
        )
        .position(
            x: PatternHighlightGeometry.coordinate(
                normalized: verticalPosition,
                origin: rect.minX,
                length: rect.width
            ),
            y: rect.midY
        )
        .gesture(
            DragGesture(coordinateSpace: .named(coordinateSpaceName))
                .onChanged { value in
                    verticalPosition = PatternHighlightGeometry.normalized(
                        coordinate: value.location.x,
                        origin: rect.minX,
                        length: rect.width
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
