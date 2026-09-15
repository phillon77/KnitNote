import SwiftUI
import KnittingCalculatorCore

/// Original normalized vector drawings. Text stays outside the drawing so translations
/// cannot move needles or change loop geometry.
struct StitchDiagramView: View {
    @Environment(\.colorScheme) private var colorScheme
    let diagram: StitchDiagram
    let accessibilityText: String

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            for stroke in diagram.strokes {
                let path = Path { path in
                    for command in stroke.commands {
                        switch command {
                        case let .move(point): path.move(to: position(point, side: side, origin: origin))
                        case let .line(point): path.addLine(to: position(point, side: side, origin: origin))
                        case let .curve(to, control1, control2):
                            path.addCurve(to: position(to, side: side, origin: origin),
                                          control1: position(control1, side: side, origin: origin),
                                          control2: position(control2, side: side, origin: origin))
                        case .close: path.closeSubpath()
                        }
                    }
                }
                let style = appearance(for: stroke.role, side: side)
                let isNeedle = stroke.role == .leftNeedle || stroke.role == .rightNeedle || stroke.role == .cableNeedle
                if isNeedle, stroke.commands.last == .close {
                    context.fill(path, with: .color(style.color))
                } else {
                    context.stroke(path, with: .color(style.color), style: style.stroke)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private func position(_ point: DiagramPoint, side: CGFloat, origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x * side, y: origin.y + point.y * side)
    }

    private func appearance(for role: DiagramRole, side: CGFloat) -> (color: Color, stroke: StrokeStyle) {
        let scale = side / 300
        let color: Color
        let width: CGFloat
        let dash: [CGFloat]
        switch role {
        case .leftNeedle: color = .gray; width = 10; dash = []
        case .rightNeedle:
            color = colorScheme == .dark ? Color(white: 0.9) : Color(white: 0.12)
            width = 8; dash = []
        case .cableNeedle:
            color = colorScheme == .dark ? Color(red: 0.76, green: 0.60, blue: 0.98) : Color(red: 0.43, green: 0.25, blue: 0.63)
            width = 9; dash = []
        case .workingYarn:
            color = colorScheme == .dark ? Color(red: 0.98, green: 0.44, blue: 0.34) : Color(red: 0.78, green: 0.24, blue: 0.18)
            width = 5; dash = []
        case .oldLoop:
            color = colorScheme == .dark ? Color(red: 0.95, green: 0.69, blue: 0.24) : Color(red: 0.65, green: 0.43, blue: 0.08)
            width = 5; dash = [8, 5]
        case .newLoop:
            color = colorScheme == .dark ? Color(red: 0.28, green: 0.82, blue: 0.74) : Color(red: 0.05, green: 0.48, blue: 0.45)
            width = 6; dash = []
        case .arrow: color = .secondary; width = 2; dash = [3, 3]
        }
        return (color, StrokeStyle(lineWidth: width * scale, lineCap: .round,
                                  lineJoin: .round, dash: dash.map { $0 * scale }))
    }
}
