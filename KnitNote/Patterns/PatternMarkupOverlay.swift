import SwiftUI

enum PatternMarkupTool { case pen, eraser }

struct PatternMarkupOverlay: View {
    @Binding var document: PatternMarkupDocument
    let tool: PatternMarkupTool
    let color: MarkupColor
    let width: Double
    @State private var activeStrokeIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                for stroke in document.strokes {
                    var path = Path()
                    guard let first = stroke.points.first else { continue }
                    path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                    for point in stroke.points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                    }
                    context.stroke(path, with: .color(stroke.color.swiftUIColor), style: StrokeStyle(lineWidth: max(1, stroke.width * min(size.width, size.height)), lineCap: .round, lineJoin: .round))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in update(at: value.location, size: proxy.size) }
                .onEnded { _ in activeStrokeIndex = nil })
        }
    }

    private func update(at location: CGPoint, size: CGSize) {
        let point = PatternMarkupPoint(x: location.x / max(1, size.width), y: location.y / max(1, size.height))
        if tool == .eraser {
            document.erase(near: point, tolerance: 0.035)
        } else if let index = activeStrokeIndex {
            document.append(point, toStrokeAt: index)
        } else {
            document.append(PatternMarkupStroke(points: [point], color: color, width: width))
            activeStrokeIndex = document.strokes.count - 1
        }
    }
}

private extension MarkupColor {
    var swiftUIColor: Color {
        switch self { case .black: .black; case .red: .red; case .blue: .blue; case .green: .green }
    }
}
