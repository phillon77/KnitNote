// Reproduce with:
// swiftc -parse-as-library Sources/KnitNoteCore/StitchDictionary/StitchDiagram.swift \
//   Sources/KnitNoteCore/StitchDictionary/StitchDictionaryResources.swift \
//   KnitNote/StitchDictionary/StitchDiagramView.swift \
//   docs/stitch-dictionary/previews/render-knit-preview.swift -o /tmp/render-knit-preview
// /tmp/render-knit-preview Sources/KnitNoteCore/Resources/stitch-diagrams-v1.json docs/stitch-dictionary/previews
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct RenderKnitPreview {
    @MainActor static func main() throws {
        struct Envelope: Decodable { let diagrams: [StitchDiagram] }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let diagrams = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: input)).diagrams
        let captions = ["1 · Insert through old loop", "2 · Wrap working yarn",
                        "3 · Draw new loop through", "4 · Release old loop"]
        for dark in [false, true] {
            let content = VStack(spacing: 12) {
                Text("Knit · Right-hand yarn").font(.title2.bold())
                Text("Gray: left needle · Contrasting: right needle · Dashed ochre: old loop\nRed: working yarn · Teal: new loop · Thin dashed: motion")
                    .font(.caption).multilineTextAlignment(.center)
                LazyVGrid(columns: [.init(.fixed(320)), .init(.fixed(320))], spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        VStack(spacing: 4) {
                            StitchDiagramView(diagram: diagrams.first { $0.id == "knit.step.\(index + 1)" }!,
                                              accessibilityText: captions[index])
                                .frame(width: 300, height: 300)
                            Text(captions[index]).font(.headline)
                        }
                        .padding(10)
                        .background(dark ? Color(white: 0.14) : Color(white: 0.96))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(24)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("SwiftUI preview failed to render") }
            let destinationURL = output.appendingPathComponent(dark ? "knit-steps-dark.png" : "knit-steps-light.png")
            guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else { fatalError("PNG destination unavailable") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("PNG encoding failed") }
            print(destinationURL.path)
        }
    }
}
