import Foundation
import Testing

@Suite struct HighlightOverlayContractTests {
    @Test func overlayUsesPolicyMetricsAndKeepsBothAccessibleDragControls() throws {
        let source = try highlightSource()
        #expect(source.contains("PatternHighlightMetrics.horizontalVisibleThickness"))
        #expect(source.contains("PatternHighlightMetrics.verticalVisibleThickness"))
        #expect(source.contains("PatternHighlightMetrics.minimumDragThickness"))
        #expect(source.contains("Rectangle().fill(.pink)"))
        #expect(!source.contains(".fill(.pink.opacity(0.32))"))
        #expect(source.components(separatedBy: ".accessibilityAdjustableAction").count - 1 == 2)
    }

    @Test func overlayUsesAnOptionalContentRectAndCanvasCoordinateDragging() throws {
        let source = try highlightSource()
        #expect(source.contains("let contentRect: CGRect?"))
        #expect(source.contains("PatternHighlightGeometry.resolvedContentRect"))
        #expect(source.contains("PatternHighlightGeometry.coordinate"))
        #expect(source.contains("PatternHighlightGeometry.normalized"))
        #expect(source.contains("coordinateSpace: .named"))
    }

    private func highlightSource() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "KnitNote/Patterns/HighlightOverlay.swift"))
    }
}
