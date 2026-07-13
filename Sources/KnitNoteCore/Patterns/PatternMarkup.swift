import Foundation

public enum MarkupColor: String, Codable, CaseIterable, Sendable {
    case black, red, blue, green
}

public struct PatternMarkupPoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }
}

public struct PatternMarkupStroke: Codable, Hashable, Sendable {
    public var points: [PatternMarkupPoint]
    public let color: MarkupColor
    public let width: Double
    public init(points: [PatternMarkupPoint], color: MarkupColor, width: Double) {
        self.points = points
        self.color = color
        self.width = min(0.05, max(0.001, width))
    }
}

public struct PatternMarkupDocument: Codable, Equatable, Sendable {
    public private(set) var strokes: [PatternMarkupStroke]
    public init(strokes: [PatternMarkupStroke] = []) { self.strokes = strokes }

    public mutating func append(_ stroke: PatternMarkupStroke) {
        guard !stroke.points.isEmpty else { return }
        strokes.append(stroke)
    }

    public mutating func append(_ point: PatternMarkupPoint, toStrokeAt index: Int) {
        guard strokes.indices.contains(index) else { return }
        strokes[index].points.append(point)
    }

    public mutating func undo() { _ = strokes.popLast() }
    public mutating func clear() { strokes.removeAll() }

    public mutating func erase(near point: PatternMarkupPoint, tolerance: Double) {
        let limit = max(0, tolerance * tolerance)
        strokes.removeAll { stroke in
            stroke.points.contains { candidate in
                let dx = candidate.x - point.x
                let dy = candidate.y - point.y
                return dx * dx + dy * dy <= limit
            }
        }
    }
}
