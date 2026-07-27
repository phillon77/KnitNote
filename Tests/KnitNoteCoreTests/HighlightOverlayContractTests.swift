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

    @Test func editingControlsCommitPositionsOnlyAfterEachDragEnds() throws {
        let source = try highlightSource()
        let horizontal = try #require(horizontalBandSource(from: source))
        let vertical = try #require(verticalBandSource(from: source))
        let horizontalDrag = try #require(sourceSection(horizontal, from: ".onChanged", to: ".accessibilityLabel"))
        let verticalDrag = try #require(sourceSection(vertical, from: ".onChanged", to: ".accessibilityLabel"))

        #expect(source.contains("var onPositionCommit: () -> Void = {}"))
        #expect(horizontalDrag.components(separatedBy: ".onEnded").count - 1 == 1)
        #expect(horizontalDrag.components(separatedBy: "onPositionCommit()").count - 1 == 1)
        #expect(verticalDrag.components(separatedBy: ".onEnded").count - 1 == 1)
        #expect(verticalDrag.components(separatedBy: "onPositionCommit()").count - 1 == 1)
        #expect(!horizontalDrag.contains(".onChanged { value in\n                    onPositionCommit()"))
        #expect(!verticalDrag.contains(".onChanged { value in\n                    onPositionCommit()"))
    }

    @Test func accessibilityAdjustmentsCommitEachChangedPosition() throws {
        let source = try highlightSource()
        let horizontal = try #require(horizontalBandSource(from: source))
        let vertical = try #require(verticalBandSource(from: source))
        let horizontalAdjustment = try #require(horizontal.range(of: ".accessibilityAdjustableAction"))
        let verticalAdjustment = try #require(vertical.range(of: ".accessibilityAdjustableAction"))
        let horizontalAccessibility = horizontal[horizontalAdjustment.lowerBound...]
        let verticalAccessibility = vertical[verticalAdjustment.lowerBound...]
        let horizontalMutation = try #require(horizontalAccessibility.range(of: "horizontalPosition ="))
        let verticalMutation = try #require(verticalAccessibility.range(of: "verticalPosition ="))
        let horizontalCommit = try #require(horizontalAccessibility.range(of: "onPositionCommit()"))
        let verticalCommit = try #require(verticalAccessibility.range(of: "onPositionCommit()"))

        #expect(horizontalAccessibility.components(separatedBy: "onPositionCommit()").count - 1 == 1)
        #expect(verticalAccessibility.components(separatedBy: "onPositionCommit()").count - 1 == 1)
        #expect(horizontalMutation.lowerBound < horizontalCommit.lowerBound)
        #expect(verticalMutation.lowerBound < verticalCommit.lowerBound)
    }

    private func highlightSource() throws -> String {
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "KnitNote/Patterns/HighlightOverlay.swift"))
    }

    private func horizontalBandSource(from source: String) -> Substring? {
        guard let start = source.range(of: "private func horizontalBand"),
              let end = source.range(of: "private func verticalBand", range: start.upperBound..<source.endIndex) else {
            return nil
        }
        return source[start.lowerBound..<end.lowerBound]
    }

    private func verticalBandSource(from source: String) -> Substring? {
        guard let start = source.range(of: "private func verticalBand") else {
            return nil
        }
        return source[start.lowerBound...]
    }

    private func sourceSection(_ source: Substring, from start: String, to end: String) -> Substring? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
