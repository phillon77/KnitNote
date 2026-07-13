import Foundation
import Testing
@testable import KnitNoteCore

@Test func markupFilesRoundTripIndependentlyByPage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = PatternMarkupFileService(root: root)
    let projectID = UUID(), patternID = UUID()
    let first = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006)])
    let second = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.8, y: 0.9)], color: .blue, width: 0.012)])

    try service.save(first, projectID: projectID, patternID: patternID, pageIndex: 0)
    try service.save(second, projectID: projectID, patternID: patternID, pageIndex: 1)

    #expect(try service.load(projectID: projectID, patternID: patternID, pageIndex: 0) == first)
    #expect(try service.load(projectID: projectID, patternID: patternID, pageIndex: 1) == second)
    #expect(try service.load(projectID: projectID, patternID: patternID, pageIndex: 2).strokes.isEmpty)
}

@Test func savingEmptyMarkupDeletesPageFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = PatternMarkupFileService(root: root)
    let projectID = UUID(), patternID = UUID()
    let drawing = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], color: .black, width: 0.006)])
    try service.save(drawing, projectID: projectID, patternID: patternID, pageIndex: 4)
    try service.save(PatternMarkupDocument(), projectID: projectID, patternID: patternID, pageIndex: 4)
    #expect(try service.load(projectID: projectID, patternID: patternID, pageIndex: 4).strokes.isEmpty)
}
