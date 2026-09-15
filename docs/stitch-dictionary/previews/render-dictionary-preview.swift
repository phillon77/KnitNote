// Render the actual app Canvas from bundled vectors; macOS only.
// swiftc -parse-as-library Sources/KnitNoteCore/StitchDictionary/StitchDiagram.swift \
// Sources/KnitNoteCore/StitchDictionary/StitchDictionaryResources.swift \
// KnitNote/StitchDictionary/StitchDiagramView.swift \
// docs/stitch-dictionary/previews/render-dictionary-preview.swift -o /tmp/render-dictionary-preview
// /tmp/render-dictionary-preview <repository-root> <output-directory>
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct RenderDictionaryPreview {
    @MainActor static func main() throws {
        struct Envelope: Decodable { let diagrams: [StitchDiagram] }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/KnitNoteCore/Resources/stitch-diagrams-v1.json"))
        let diagrams = try JSONDecoder().decode(Envelope.self, from: data).diagrams
        let ids = ["knit", "purl", "slip-knitwise", "slip-purlwise", "yarn-over", "knit-front-back", "make-one-left", "make-one-right", "k2tog", "ssk", "skp", "p2tog", "centered-double-decrease", "cable-left-two", "cable-right-two"]
        for id in ids + ["symbols"] {
            let selected = diagrams.filter { id == "symbols" ? $0.id.contains(".symbol.") : $0.id.hasPrefix(id + ".step.") }
            for dark in [false, true] {
                let content = VStack(spacing: 10) {
                    Text(id).font(.title2.bold())
                    Text("Gray: left needle · Contrast: right needle · Purple: cable needle\nOchre dashed: old loop · Red: yarn · Teal: new loop · Thin dashed: motion")
                        .font(.caption).multilineTextAlignment(.center)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(280)), count: id == "knit" ? 4 : 3), spacing: 12) {
                        ForEach(selected) { diagram in
                            VStack {
                                StitchDiagramView(diagram: diagram, accessibilityText: diagram.id)
                                    .frame(width: 260, height: 260)
                                Text(diagram.id).font(.caption)
                            }
                            .padding(8)
                            .background(dark ? Color(white: 0.13) : Color(white: 0.96))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(20)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1.5
                guard let image = renderer.cgImage else { fatalError("Render failed: \(id)") }
                let name = id + (dark ? "-dark.png" : "-light.png")
                let url = output.appendingPathComponent(name)
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("PNG creation failed") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { fatalError("PNG write failed") }
                print(url.path)
            }
        }
    }
}
