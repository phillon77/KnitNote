import Foundation

public struct DiagramPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum DiagramCommand: Codable, Equatable, Sendable {
    case move(DiagramPoint)
    case line(DiagramPoint)
    case curve(to: DiagramPoint, control1: DiagramPoint, control2: DiagramPoint)
    case close
}

public enum DiagramRole: String, Codable, CaseIterable, Sendable {
    case leftNeedle, rightNeedle, workingYarn, oldLoop, newLoop, arrow
}

public struct DiagramStroke: Codable, Equatable, Sendable {
    public let role: DiagramRole
    public let commands: [DiagramCommand]
    public init(role: DiagramRole, commands: [DiagramCommand]) {
        self.role = role
        self.commands = commands
    }
}

public enum StitchDiagramError: Error, Equatable, Sendable {
    case emptyDiagram
    case missingInitialMove
    case invalidPoint
    case missingResource
    case unsupportedVersion(Int)
}

public struct StitchDiagram: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let strokes: [DiagramStroke]
    public init(id: String, strokes: [DiagramStroke]) {
        self.id = id
        self.strokes = strokes
    }

    public func validate() throws {
        guard !strokes.isEmpty else { throw StitchDiagramError.emptyDiagram }
        for stroke in strokes {
            guard let first = stroke.commands.first, case .move = first else {
                throw StitchDiagramError.missingInitialMove
            }
            for command in stroke.commands {
                switch command {
                case let .move(point), let .line(point): try validate(point)
                case let .curve(to, control1, control2):
                    try validate(to)
                    try validate(control1)
                    try validate(control2)
                case .close: break
                }
            }
        }
    }

    private func validate(_ point: DiagramPoint) throws {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw StitchDiagramError.invalidPoint
        }
    }

    public static func loadBundled() throws -> [StitchDiagram] {
        struct Resource: Decodable {
            let schemaVersion: Int
            let diagrams: [StitchDiagram]
        }
        guard let url = StitchDictionaryResources.url(named: "stitch-diagrams-v1") else {
            throw StitchDiagramError.missingResource
        }
        let resource = try JSONDecoder().decode(Resource.self, from: Data(contentsOf: url))
        guard resource.schemaVersion == 1 else {
            throw StitchDiagramError.unsupportedVersion(resource.schemaVersion)
        }
        for diagram in resource.diagrams { try diagram.validate() }
        return resource.diagrams
    }
}
