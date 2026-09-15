import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct StitchDiagramTests {
    @Test(arguments: [-0.01, 1.01, Double.nan, Double.infinity, -Double.infinity])
    func rejectsInvalidCoordinateInEveryCommandPosition(value: Double) throws {
        let bad = DiagramPoint(x: value, y: 0.5)
        let good = DiagramPoint(x: 0.5, y: 0.5)
        let commands: [DiagramCommand] = [
            .move(bad), .line(bad),
            .curve(to: bad, control1: good, control2: good),
            .curve(to: good, control1: bad, control2: good),
            .curve(to: good, control1: good, control2: bad)
        ]
        for command in commands {
            let diagram = StitchDiagram(id: "bad", strokes: [
                DiagramStroke(role: .workingYarn, commands: [.move(good), command])
            ])
            #expect(throws: (any Error).self) { try diagram.validate() }
        }
        let invalidY = StitchDiagram(id: "bad-y", strokes: [
            DiagramStroke(role: .oldLoop, commands: [.move(.init(x: 0.5, y: value))])
        ])
        #expect(throws: (any Error).self) { try invalidY.validate() }
    }

    @Test func rejectsEmptyDiagram() throws {
        #expect(throws: (any Error).self) { try StitchDiagram(id: "empty", strokes: []).validate() }
    }

    @Test func rejectsMissingInitialMove() throws {
        let point = DiagramPoint(x: 0.5, y: 0.5)
        let invalidCommands: [[DiagramCommand]] = [[], [.line(point)], [.close],
            [.curve(to: point, control1: point, control2: point)]]
        for commands in invalidCommands {
            let diagram = StitchDiagram(id: "bad", strokes: [DiagramStroke(role: .arrow, commands: commands)])
            #expect(throws: (any Error).self) { try diagram.validate() }
        }
    }

    @Test func acceptsBoundaryPointsAndClosedBezierPath() throws {
        let diagram = StitchDiagram(id: "valid", strokes: [
            DiagramStroke(role: .newLoop, commands: [
                .move(.init(x: 0, y: 0)), .line(.init(x: 1, y: 1)),
                .curve(to: .init(x: 0, y: 1), control1: .init(x: 1, y: 0), control2: .init(x: 0, y: 0)),
                .close
            ])
        ])
        try diagram.validate()
        #expect(try JSONDecoder().decode(StitchDiagram.self, from: JSONEncoder().encode(diagram)) == diagram)
    }

    @Test func bundledKnitStepsResolveToDistinctValidatedDiagrams() throws {
        struct Envelope: Decodable { let entries: [StitchEntry] }
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "stitch-dictionary-v1", withExtension: "json")))
        let knit = try #require(JSONDecoder().decode(Envelope.self, from: data).entries.first { $0.id == "knit" })
        let diagrams = try StitchDiagram.loadBundled()
        #expect(knit.steps.count == 4)
        #expect(knit.consumes == 1)
        #expect(knit.produces == 1)
        for step in knit.steps {
            let diagram = try #require(diagrams.first { $0.id == step.diagramID })
            try diagram.validate()
            #expect(diagram.strokes.contains { $0.role == .leftNeedle })
            #expect(diagram.strokes.contains { $0.role == .rightNeedle })
            #expect(diagram.strokes.contains { $0.role == .oldLoop })
            #expect(diagram.strokes.contains { $0.role == .workingYarn })
        }
        #expect(Set(knit.steps.map(\.diagramID)).count == 4)
        for symbol in knit.symbols {
            #expect(diagrams.contains { $0.id == symbol.diagramID })
        }
    }

    @Test func newLoopJoinsWorkingYarnAtBothEnds() throws {
        func endpoints(of stroke: DiagramStroke) -> [DiagramPoint] {
            guard case let .move(start)? = stroke.commands.first else { return [] }
            switch stroke.commands.last {
            case let .move(end)?, let .line(end)?: return [start, end]
            case let .curve(end, _, _)?: return [start, end]
            default: return []
            }
        }
        let diagrams = try StitchDiagram.loadBundled()
        for id in ["knit.step.3", "knit.step.4"] {
            let diagram = try #require(diagrams.first { $0.id == id })
            let loop = try #require(diagram.strokes.first { $0.role == .newLoop })
            let yarnEnds = diagram.strokes.filter { $0.role == .workingYarn }.flatMap { endpoints(of: $0) }
            let loopEnds = endpoints(of: loop)
            #expect(loopEnds.count == 2)
            for end in loopEnds {
                #expect(yarnEnds.contains(end), "New loop in \(id) must join the continuing yarn at each end")
            }
        }
    }
}
