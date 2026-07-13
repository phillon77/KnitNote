import SwiftUI

struct PatternMarkupToolbar: View {
    @Binding var document: PatternMarkupDocument
    @Binding var tool: PatternMarkupTool
    @Binding var color: MarkupColor
    @Binding var width: Double
    let onClear: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            Button("patterns.markup.pen", systemImage: "pencil.tip") { tool = .pen }
                .buttonStyle(.bordered).tint(tool == .pen ? .accentColor : .secondary)
            Button("patterns.markup.eraser", systemImage: "eraser") { tool = .eraser }
                .buttonStyle(.bordered).tint(tool == .eraser ? .accentColor : .secondary)
            Menu("patterns.markup.color", systemImage: "paintpalette") {
                ForEach(MarkupColor.allCases, id: \.self) { value in
                    Button(String(localized: "patterns.markup.color.\(value.rawValue)")) { color = value; tool = .pen }
                }
            }
            Menu("patterns.markup.width", systemImage: "lineweight") {
                Button("patterns.markup.width.thin") { width = 0.004 }
                Button("patterns.markup.width.medium") { width = 0.008 }
                Button("patterns.markup.width.thick") { width = 0.016 }
            }
            Button("patterns.markup.undo", systemImage: "arrow.uturn.backward") { document.undo() }
                .disabled(document.strokes.isEmpty)
            Button("patterns.markup.clear", systemImage: "trash", role: .destructive, action: onClear)
                .disabled(document.strokes.isEmpty)
            Spacer()
            Button("common.ok", action: onDone).buttonStyle(.borderedProminent)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}
