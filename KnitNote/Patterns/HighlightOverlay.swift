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
            RoundedRectangle(cornerRadius: 6)
                .fill(.yellow.opacity(0.32))
                .frame(height: 44)
                .overlay(alignment: .trailing) { Image(systemName: "line.3.horizontal").padding().foregroundStyle(.secondary) }
                .position(x: size.width / 2, y: max(22, min(size.height - 22, size.height * horizontalPosition)))
                .gesture(DragGesture().onChanged { value in horizontalPosition = min(1, max(0, value.location.y / max(1, size.height))) })
                .accessibilityLabel(Text("patterns.highlight.horizontalControl"))
                .accessibilityAdjustableAction { direction in
                    let delta = direction == .increment ? 0.05 : -0.05
                    horizontalPosition = min(1, max(0, horizontalPosition + delta))
                }
    }

    private func verticalBand(in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.pink.opacity(0.32))
            .frame(width: 44)
            .overlay(alignment: .bottom) { Image(systemName: "line.3.horizontal").rotationEffect(.degrees(90)).padding().foregroundStyle(.secondary) }
            .position(x: max(22, min(size.width - 22, size.width * verticalPosition)), y: size.height / 2)
            .gesture(DragGesture().onChanged { value in verticalPosition = min(1, max(0, value.location.x / max(1, size.width))) })
            .accessibilityLabel(Text("patterns.highlight.verticalControl"))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                verticalPosition = min(1, max(0, verticalPosition + delta))
            }
    }
}
