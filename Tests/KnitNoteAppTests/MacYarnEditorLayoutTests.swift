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
            WindowRetainer.shared.windows.append(rendered.window)
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

    @Test func editYarnControlsRenderAsAReadableColumnAtMinimumWidth() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEditYarnEditorLayout-\(UUID().uuidString).json")
        let store = JSONProjectStore(url: storeURL)
        let yarn = try StoredYarn(name: "Editable Merino")
        try store.addYarn(
            yarn,
            photoData: nil,
            labelPhotos: [fixtureImageData()]
        )

        let rendered = renderEditYarn(store: store, yarnID: yarn.id)
        WindowRetainer.shared.windows.append(rendered.window)

        let scan = try #require(rendered.frames["macYarnEditor.scan"])
        let name = try #require(rendered.frames["macYarnEditor.name"])
        let linkedProjects = try #require(rendered.frames["macYarnEditor.linkedProjects"])
        let labelPhotos = try #require(rendered.frames["macYarnEditor.labelPhotos"])
        let photo = try #require(rendered.frames["macYarnEditor.photo"])
        let controls = [scan, name, linkedProjects, labelPhotos, photo]

        for frame in controls {
            #expect(frame.width > 0)
            #expect(frame.height > 0)
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= rendered.host.bounds.width)
            #expect(abs(frame.minX - scan.minX) <= 1)
        }
        #expect(Set(controls.map { Int($0.midY.rounded()) }).count == controls.count)
        for (upper, lower) in zip(controls, controls.dropFirst()) {
            #expect(upper.midY < lower.midY)
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

    private func waitForEditYarnFrames(
        _ collector: FrameCollector,
        in host: NSHostingView<AnyView>,
        required: Set<String>
    ) {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            host.window?.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while !required.isSubset(of: Set(collector.frames.keys)) && Date() < deadline
    }

    private func renderEditYarn(store: JSONProjectStore, yarnID: UUID) -> RenderedCreateYarn {
        let collector = FrameCollector()
        let root = EditYarnView(yarnID: yarnID)
            .environmentObject(store)
            .coordinateSpace(name: MacYarnEditorFieldFramePreferenceKey.coordinateSpaceName)
            .onPreferenceChange(MacYarnEditorFieldFramePreferenceKey.self) {
                collector.frames = $0
            }
        let host = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 520, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        waitForEditYarnFrames(
            collector,
            in: host,
            required: [
                "macYarnEditor.scan",
                "macYarnEditor.name",
                "macYarnEditor.linkedProjects",
                "macYarnEditor.labelPhotos",
                "macYarnEditor.photo",
            ]
        )
        return RenderedCreateYarn(window: window, host: host, frames: collector.frames)
    }

    private func fixtureImageData() -> Data {
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        image.setColor(NSColor.systemTeal, atX: 0, y: 0)
        return image.representation(using: .png, properties: [:])!
    }

    private final class FrameCollector {
        var frames: [String: NSRect] = [:]
    }

    @MainActor private final class WindowRetainer {
        static let shared = WindowRetainer()
        var windows: [NSWindow] = []
    }

    private struct RenderedCreateYarn {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let frames: [String: NSRect]
    }
}
