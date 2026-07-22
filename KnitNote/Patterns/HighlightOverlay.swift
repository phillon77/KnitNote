import SwiftUI

struct HighlightOverlay: View {
    let mode: HighlightMode
    @Binding var horizontalPosition: Double
    @Binding var verticalPosition: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if mode == .horizontal || mode == .cross {
                    horizontalBand(in: proxy.size)
                }
                if mode == .vertical || mode == .cross {
                    verticalBand(in: proxy.size)
                }
            }
        }.allowsHitTesting(true)
    }

    private func horizontalBand(in size: CGSize) -> some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.yellow.opacity(0.32))
                .frame(height: PatternHighlightMetrics.horizontalVisibleThickness)
            Color.clear
                .contentShape(Rectangle())
                .frame(height: PatternHighlightMetrics.minimumDragThickness)
        }
        .frame(height: PatternHighlightMetrics.minimumDragThickness)
        .position(
            x: size.width / 2,
            y: max(22, min(size.height - 22, size.height * horizontalPosition))
        )
        .gesture(DragGesture().onChanged { value in
            horizontalPosition = min(1, max(0, value.location.y / max(1, size.height)))
        })
        .accessibilityLabel(Text("patterns.highlight.horizontalControl"))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            horizontalPosition = min(1, max(0, horizontalPosition + delta))
        }
    }

    private func verticalBand(in size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(.pink)
                .frame(width: PatternHighlightMetrics.verticalVisibleThickness)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: PatternHighlightMetrics.minimumDragThickness)
        }
        .frame(width: PatternHighlightMetrics.minimumDragThickness)
        .position(
            x: max(22, min(size.width - 22, size.width * verticalPosition)),
            y: size.height / 2
        )
        .gesture(DragGesture().onChanged { value in
            verticalPosition = min(1, max(0, value.location.x / max(1, size.width)))
        })
        .accessibilityLabel(Text("patterns.highlight.verticalControl"))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            verticalPosition = min(1, max(0, verticalPosition + delta))
        }
    }
}
