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

    @Test func fullCanvasCenterInsetFeedsBothHorizontalAndVerticalGeometry() throws {
        let source = try highlightSource()
        let horizontal = try #require(horizontalBandSource(from: source))
        let vertical = try #require(verticalBandSource(from: source))

        #expect(source.contains(
            "let centerInset = PatternHighlightGeometry.centerInset(contentRect: contentRect)"
        ))
        #expect(horizontal.components(separatedBy: "centerInset: centerInset").count - 1 == 2)
        #expect(vertical.components(separatedBy: "centerInset: centerInset").count - 1 == 2)
    }

    @Test func editingControlsCommitPositionsOnlyAfterEachDragEnds() throws {
        let source = try highlightSource()
        let horizontal = try #require(horizontalBandSource(from: source))
        let vertical = try #require(verticalBandSource(from: source))
        let horizontalChange = try #require(closureBody(after: ".onChanged", in: horizontal))
        let horizontalEnd = try #require(closureBody(after: ".onEnded", in: horizontal))
        let verticalChange = try #require(closureBody(after: ".onChanged", in: vertical))
        let verticalEnd = try #require(closureBody(after: ".onEnded", in: vertical))

        #expect(source.contains("var onPositionCommit: () -> Void = {}"))
        #expect(!horizontalChange.contains("onPositionCommit()"))
        #expect(horizontalEnd.components(separatedBy: "onPositionCommit()").count - 1 == 1)
        #expect(!verticalChange.contains("onPositionCommit()"))
        #expect(verticalEnd.components(separatedBy: "onPositionCommit()").count - 1 == 1)
    }

    @Test func accessibilityAdjustmentsCommitEachChangedPosition() throws {
        let source = try highlightSource()
        let horizontal = try #require(horizontalBandSource(from: source))
        let vertical = try #require(verticalBandSource(from: source))
        let horizontalAccessibility = try #require(
            closureBody(after: ".accessibilityAdjustableAction", in: horizontal)
        )
        let verticalAccessibility = try #require(
            closureBody(after: ".accessibilityAdjustableAction", in: vertical)
        )
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

    private func closureBody(after marker: String, in source: Substring) -> Substring? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source[source.index(after: openingBrace)..<index]
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
