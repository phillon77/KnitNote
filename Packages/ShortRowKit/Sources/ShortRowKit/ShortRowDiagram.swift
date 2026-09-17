import SwiftUI

struct ShortRowDiagram: View {
    let plan: ShortRowPlan
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ShortRowStrings.text("diagram", locale: locale)).font(.headline)
            Canvas { context, size in
                let margin: CGFloat = 8
                let width = size.width - margin * 2
                let bottom = size.height - margin
                let scale = (size.height - margin * 2) / CGFloat(plan.shapingRows + 2)
                var shape = Path()
                shape.move(to: CGPoint(x: margin, y: bottom))
                var x = margin
                for (index, stitches) in plan.segments.reversed().enumerated() {
                    let height = CGFloat(plan.shapingRows - index * 2 + 1) * scale
                    shape.addLine(to: CGPoint(x: x, y: bottom - height))
                    x += width * CGFloat(stitches) / CGFloat(plan.stitches)
                    shape.addLine(to: CGPoint(x: x, y: bottom - height))
                }
                shape.addLine(to: CGPoint(x: x, y: bottom))
                shape.closeSubpath()
                context.fill(shape, with: .color(.accentColor.opacity(0.18)))
                context.stroke(shape, with: .color(.accentColor), lineWidth: 2)
            }
            .frame(height: 160)
            .accessibilityHidden(true)
            HStack {
                Text(ShortRowStrings.text("neck", locale: locale))
                Spacer()
                Text(ShortRowStrings.text("armhole", locale: locale))
            }
            .font(.caption.weight(.semibold))
            Text(ShortRowStrings.text("schematic", locale: locale))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
