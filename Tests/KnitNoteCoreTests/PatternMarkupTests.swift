import Foundation
import Testing
@testable import KnitNoteCore

@Test func markupPointsAndWidthClampToSafeRanges() {
    let point = PatternMarkupPoint(x: -1, y: 2)
    let stroke = PatternMarkupStroke(points: [point], color: .red, width: 1)
    #expect(point.x == 0)
    #expect(point.y == 1)
    #expect(stroke.width == 0.05)
}

@Test func markupUndoAndEraserAffectOnlyExpectedStroke() {
    let left = PatternMarkupStroke(points: [.init(x: 0.1, y: 0.1)], color: .black, width: 0.006)
    let right = PatternMarkupStroke(points: [.init(x: 0.9, y: 0.9)], color: .blue, width: 0.006)
    var document = PatternMarkupDocument(strokes: [left, right])

    document.erase(near: .init(x: 0.12, y: 0.1), tolerance: 0.05)
    #expect(document.strokes == [right])
    document.undo()
    #expect(document.strokes.isEmpty)
}

@Test func markupDocumentSurvivesCodableRoundTrip() throws {
    let expected = PatternMarkupDocument(strokes: [
        PatternMarkupStroke(points: [.init(x: 0.25, y: 0.75), .init(x: 0.5, y: 0.5)], color: .green, width: 0.012)
    ])
    let actual = try JSONDecoder().decode(PatternMarkupDocument.self, from: JSONEncoder().encode(expected))
    #expect(actual == expected)
}
