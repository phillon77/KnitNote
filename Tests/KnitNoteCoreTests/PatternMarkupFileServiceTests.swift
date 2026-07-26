import Foundation
import Testing
@testable import KnitNoteCore

@Test func markupFilesRoundTripIndependentlyByUsageAndPage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = PatternMarkupFileService(root: root)
    let firstUsageID = UUID(), secondUsageID = UUID()
    let first = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006)])
    let second = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.8, y: 0.9)], color: .blue, width: 0.012)])

    try service.save(first, usageID: firstUsageID, pageIndex: 0)
    try service.save(second, usageID: secondUsageID, pageIndex: 0)

    #expect(try service.load(usageID: firstUsageID, pageIndex: 0) == first)
    #expect(try service.load(usageID: secondUsageID, pageIndex: 0) == second)
    #expect(try service.load(usageID: firstUsageID, pageIndex: 2).strokes.isEmpty)
}

@Test func savingEmptyMarkupDeletesPageFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = PatternMarkupFileService(root: root)
    let usageID = UUID()
    let drawing = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], color: .black, width: 0.006)])
    try service.save(drawing, usageID: usageID, pageIndex: 4)
    try service.save(PatternMarkupDocument(), usageID: usageID, pageIndex: 4)
    #expect(try service.load(usageID: usageID, pageIndex: 4).strokes.isEmpty)
}

@Test func deletingUsageMarkupDoesNotTouchAnotherUsage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = PatternMarkupFileService(root: root)
    let firstUsageID = UUID(), secondUsageID = UUID()
    let drawing = PatternMarkupDocument(strokes: [.init(
        points: [.init(x: 0.5, y: 0.5)], color: .black, width: 0.006
    )])

    try service.save(drawing, usageID: firstUsageID, pageIndex: 0)
    try service.save(drawing, usageID: secondUsageID, pageIndex: 0)
    try service.deleteUsageMarkup(usageID: firstUsageID)

    #expect(try service.load(usageID: firstUsageID, pageIndex: 0).strokes.isEmpty)
    #expect(try service.load(usageID: secondUsageID, pageIndex: 0) == drawing)
}
