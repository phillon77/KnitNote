import Foundation
import Testing
@testable import KnitNoteCore

struct StitchDictionaryContentTests {
    private let ids = ["knit", "purl", "slip-knitwise", "slip-purlwise", "yarn-over", "knit-front-back", "make-one-left", "make-one-right", "k2tog", "ssk", "skp", "p2tog", "centered-double-decrease", "cable-left-two", "cable-right-two"]

    @Test func shipsFifteenReviewedOperations() throws {
        let catalog = try StitchCatalog.bundled()
        #expect(catalog.entries.map(\.id) == ids)
        #expect(Set(catalog.entries.map(\.id)).count == 15)
        #expect(catalog.entry(id: "ssk")?.id != catalog.entry(id: "skp")?.id)
    }

    @Test func stitchCountsMatchOperations() throws {
        let catalog = try StitchCatalog.bundled()
        for id in ids {
            let entry = try #require(catalog.entry(id: id))
            let expected: (Int, Int)
            switch id {
            case "yarn-over", "make-one-left", "make-one-right": expected = (0, 1)
            case "knit-front-back": expected = (1, 2)
            case "k2tog", "ssk", "skp", "p2tog": expected = (2, 1)
            case "centered-double-decrease": expected = (3, 1)
            case "cable-left-two", "cable-right-two": expected = (2, 2)
            default: expected = (1, 1)
            }
            #expect(entry.consumes == expected.0)
            #expect(entry.produces == expected.1)
        }
    }

    @Test func everyOperationHasIndependentInstructionDiagrams() throws {
        let catalog = try StitchCatalog.bundled()
        let diagrams = try StitchDiagram.loadBundled()
        #expect(Set(diagrams.map(\.id)).count == diagrams.count)
        for entry in catalog.entries {
            #expect(entry.steps.count >= 2)
            for step in entry.steps {
                let diagram = try #require(diagrams.first { $0.id == step.diagramID })
                #expect(diagram.id.hasPrefix(entry.id + ".step."))
                #expect(diagram.strokes.contains { $0.role == .leftNeedle })
                #expect(diagram.strokes.contains { $0.role == .rightNeedle })
                #expect(diagram.strokes.contains { $0.role == .workingYarn })
                try diagram.validate()
            }
        }
        #expect(catalog.entry(id: "slip-knitwise")?.symbols.isEmpty == true)
        #expect(catalog.entry(id: "skp")?.symbols.isEmpty == true)
        #expect(catalog.entry(id: "knit")?.symbols.contains { $0.sourceIDs.contains("knitter-academy-legend") } == true)
        #expect(catalog.entry(id: "purl")?.symbols.contains { $0.sourceIDs.contains("knitter-academy-legend") } == true)
    }

    @Test func newLoopsJoinContinuingYarnInsteadOfFloating() throws {
        for diagram in try StitchDiagram.loadBundled() {
            let threads = diagram.strokes.filter { $0.role == .workingYarn || $0.role == .newLoop }
            for (index, thread) in threads.enumerated() where thread.role == .newLoop {
                let ends = endpoints(thread)
                let otherEnds = threads.enumerated().filter { $0.offset != index }.flatMap { endpoints($0.element) }
                #expect(ends.count == 2)
                for end in ends {
                    #expect(otherEnds.contains { distance($0, end) < 0.000_01 }, "Disconnected new-loop end in \(diagram.id)")
                }
            }
        }
    }

    @Test func knittedLoopsMeetTheirParentFabric() throws {
        for diagram in try StitchDiagram.loadBundled() where diagram.id.contains(".step.") && !diagram.id.hasPrefix("yarn-over") {
            let new = diagram.strokes.filter { $0.role == .newLoop }.flatMap(samples)
            let old = diagram.strokes.filter { $0.role == .oldLoop }.flatMap(samples)
            guard !new.isEmpty else { continue }
            #expect(new.contains { n in old.contains { distance(n, $0) < 0.03 } }, "New stitch floats away from old fabric in \(diagram.id)")
        }
    }

    @Test func cableHoldingNeedleIsPresentAndSlipMakesNoNewLoop() throws {
        let diagrams = try StitchDiagram.loadBundled()
        for id in ["cable-left-two", "cable-right-two"] {
            for step in 1...3 {
                let diagram = try #require(diagrams.first { $0.id == "\(id).step.\(step)" })
                #expect(diagram.strokes.contains { $0.role == .cableNeedle })
            }
        }
        for diagram in diagrams where diagram.id.hasPrefix("slip-") && diagram.id.contains(".step.") {
            #expect(!diagram.strokes.contains { $0.role == .newLoop })
        }
    }

    private func endpoints(_ stroke: DiagramStroke) -> [DiagramPoint] {
        guard case let .move(start)? = stroke.commands.first else { return [] }
        switch stroke.commands.last {
        case let .line(end)?, let .curve(end, _, _)?: return [start, end]
        default: return []
        }
    }

    private func distance(_ a: DiagramPoint, _ b: DiagramPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Sample cubic paths to detect detached fabric, without pinning exact drawing coordinates.
    private func samples(_ stroke: DiagramStroke) -> [DiagramPoint] {
        var points: [DiagramPoint] = []
        var previous = DiagramPoint(x: 0, y: 0)
        for command in stroke.commands {
            switch command {
            case let .move(p): previous = p; points.append(p)
            case let .line(p):
                for index in 1...40 {
                    let t = Double(index) / 40
                    points.append(DiagramPoint(x: previous.x + t * (p.x - previous.x), y: previous.y + t * (p.y - previous.y)))
                }
                previous = p
            case let .curve(p, a, b):
                for index in 1...60 {
                    let t = Double(index) / 60, u = 1 - t
                    let x = u * u * u * previous.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * p.x
                    let y = u * u * u * previous.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * p.y
                    points.append(DiagramPoint(x: x, y: y))
                }
                previous = p
            case .close: break
            }
        }
        return points
    }
}
