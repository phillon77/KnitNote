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

@Test func copyingLegacyMarkupCopiesEveryAllowedPageIndependently() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = PatternMarkupFileService(root: root.appendingPathComponent("legacy", isDirectory: true))
    let destination = PatternMarkupFileService(root: root.appendingPathComponent("destination", isDirectory: true))
    let projectID = UUID(), patternID = UUID(), usageID = UUID()
    let first = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006)])
    let second = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.8, y: 0.9)], color: .blue, width: 0.012)])
    try source.save(first, projectID: projectID, patternID: patternID, pageIndex: 0)
    try source.save(second, projectID: projectID, patternID: patternID, pageIndex: 2)

    try destination.copyLegacyMarkup(
        from: source,
        projectID: projectID,
        patternID: patternID,
        usageID: usageID
    )

    #expect(try destination.load(usageID: usageID, pageIndex: 0) == first)
    #expect(try destination.load(usageID: usageID, pageIndex: 2) == second)
    #expect(try destination.load(usageID: usageID, pageIndex: 1).strokes.isEmpty)
}

@Test func copyingLegacyMarkupRejectsUnexpectedFilesAndLeavesNoUsageMarkup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceRoot = root.appendingPathComponent("legacy", isDirectory: true)
    let source = PatternMarkupFileService(root: sourceRoot)
    let destination = PatternMarkupFileService(root: root.appendingPathComponent("destination", isDirectory: true))
    let projectID = UUID(), patternID = UUID(), usageID = UUID()
    try source.save(
        PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.1, y: 0.2)], color: .red, width: 0.006)]),
        projectID: projectID,
        patternID: patternID,
        pageIndex: 0
    )
    let unexpected = sourceRoot.appendingPathComponent(
        "\(projectID.uuidString)/Markup/\(patternID.uuidString)/notes.txt"
    )
    try Data("unexpected".utf8).write(to: unexpected)

    #expect(throws: PatternMarkupFileError.unsafePath) {
        try destination.copyLegacyMarkup(
            from: source,
            projectID: projectID,
            patternID: patternID,
            usageID: usageID
        )
    }
    #expect(try destination.load(usageID: usageID, pageIndex: 0).strokes.isEmpty)
}

@Test func usageMarkupSymlinkRejectsEveryOperationWithoutTouchingItsTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let marker = outside.appendingPathComponent("marker.txt")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("outside bytes".utf8).write(to: marker)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("UsageMarkup", isDirectory: true),
        withDestinationURL: outside
    )
    let service = PatternMarkupFileService(root: root)
    let drawing = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], color: .red, width: 0.01)])
    let usageID = UUID()

    #expect(throws: PatternMarkupFileError.unsafePath) { try service.save(drawing, usageID: usageID, pageIndex: 0) }
    #expect(throws: PatternMarkupFileError.unsafePath) { _ = try service.load(usageID: usageID, pageIndex: 0) }
    #expect(throws: PatternMarkupFileError.unsafePath) { try service.deleteUsageMarkup(usageID: usageID) }

    #expect(try Data(contentsOf: marker) == Data("outside bytes".utf8))
    #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).sorted() == ["marker.txt"])
}

@Test func legacyMarkupSymlinkRejectsEveryOperationWithoutTouchingItsTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    let marker = outside.appendingPathComponent("marker.txt")
    let projectID = UUID(), patternID = UUID()
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("outside bytes".utf8).write(to: marker)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(projectID.uuidString, isDirectory: true),
        withDestinationURL: outside
    )
    let service = PatternMarkupFileService(root: root)
    let drawing = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], color: .blue, width: 0.01)])

    #expect(throws: PatternMarkupFileError.unsafePath) {
        try service.save(drawing, projectID: projectID, patternID: patternID, pageIndex: 0)
    }
    #expect(throws: PatternMarkupFileError.unsafePath) {
        _ = try service.load(projectID: projectID, patternID: patternID, pageIndex: 0)
    }
    #expect(throws: PatternMarkupFileError.unsafePath) {
        try service.deleteLegacyMarkup(projectID: projectID, patternID: patternID)
    }

    #expect(try Data(contentsOf: marker) == Data("outside bytes".utf8))
    #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).sorted() == ["marker.txt"])
}
