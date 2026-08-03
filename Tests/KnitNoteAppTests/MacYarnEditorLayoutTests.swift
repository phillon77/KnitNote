import AppKit
import SwiftUI
import Testing
@testable import KnitNote

@MainActor
@Suite struct MacYarnEditorLayoutTests {
    private let fieldIdentifiers = [
        "macYarnEditor.name",
        "macYarnEditor.brand",
        "macYarnEditor.series",
        "macYarnEditor.color",
        "macYarnEditor.colorCode",
        "macYarnEditor.dyeLot",
        "macYarnEditor.ballWeightGrams",
        "macYarnEditor.lengthMeters",
        "macYarnEditor.fiberContent",
        "macYarnEditor.needleLower",
        "macYarnEditor.needleUpper",
        "macYarnEditor.hookLower",
        "macYarnEditor.hookUpper",
        "macYarnEditor.remainingBalls",
        "macYarnEditor.remainingGrams",
        "macYarnEditor.storageLocation",
        "macYarnEditor.notes",
    ]

    private let singleColumnFieldIdentifiers = [
        "macYarnEditor.name",
        "macYarnEditor.brand",
        "macYarnEditor.series",
        "macYarnEditor.color",
        "macYarnEditor.colorCode",
        "macYarnEditor.dyeLot",
        "macYarnEditor.ballWeightGrams",
        "macYarnEditor.lengthMeters",
        "macYarnEditor.fiberContent",
        "macYarnEditor.remainingBalls",
        "macYarnEditor.remainingGrams",
        "macYarnEditor.storageLocation",
        "macYarnEditor.notes",
    ]

    @Test func createYarnFieldsRenderAsAReadableColumnAtMinimumAndIdealWidths() throws {
        for width in [CGFloat(520), 620] {
            let rendered = renderCreateYarn(width: width)
            defer { rendered.window.close() }
            let fields = rendered.frames

            for identifier in fieldIdentifiers {
                let frame = try #require(fields[identifier])
                #expect(frame.width > 0)
                #expect(frame.height > 0)
                #expect(rendered.host.bounds.contains(frame))
            }

            let leadingEdges = try singleColumnFieldIdentifiers.map {
                try #require(fields[$0]).minX
            }
            let expectedLeadingEdge = try #require(leadingEdges.first)
            for leadingEdge in leadingEdges {
                #expect(abs(leadingEdge - expectedLeadingEdge) <= 1)
            }

            let verticalMidpoints = try singleColumnFieldIdentifiers.map {
                try #require(fields[$0]).midY
            }
            #expect(Set(verticalMidpoints.map { Int($0.rounded()) }).count == verticalMidpoints.count)
        }
    }

    private func renderCreateYarn(width: CGFloat) -> RenderedCreateYarn {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacYarnEditorLayout-\(UUID().uuidString).json")
        let store = JSONProjectStore(url: storeURL)
        let collector = FrameCollector()
        let root = CreateYarnView()
            .environmentObject(store)
            .coordinateSpace(name: MacYarnEditorFieldFramePreferenceKey.coordinateSpaceName)
            .onPreferenceChange(MacYarnEditorFieldFramePreferenceKey.self) {
                collector.frames = $0
            }
        let host = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1_600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return RenderedCreateYarn(window: window, host: host, frames: collector.frames)
    }

    private final class FrameCollector {
        var frames: [String: NSRect] = [:]
    }

    private struct RenderedCreateYarn {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let frames: [String: NSRect]
    }
}
