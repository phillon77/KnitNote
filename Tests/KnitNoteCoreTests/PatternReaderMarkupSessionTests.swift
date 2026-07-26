import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct PatternReaderMarkupSessionTests {
    @Test func failedCorruptMarkupLoadCannotOverwriteItsOriginalBytesDuringLifecycleSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PatternMarkupFileService(root: root)
        let usageID = UUID()
        try service.save(drawing, usageID: usageID, pageIndex: 0)
        let file = try onlyMarkupFile(in: root)
        let corruptBytes = Data("not a markup document".utf8)
        try corruptBytes.write(to: file, options: .atomic)

        var markup = PatternReaderMarkupSession()
        markup.beginLoading(readerGeneration: 4, pageIndex: 0)
        #expect(throws: DecodingError.self) { _ = try service.load(usageID: usageID, pageIndex: 0) }
        let didFail = markup.failLoading(for: 4, pageIndex: 0)
        #expect(didFail)

        #expect(!markup.canPersistMarkup(readerGeneration: 4, pageIndex: 0))
        #expect(try Data(contentsOf: file) == corruptBytes)
        let reopened = PatternMarkupFileService(root: root)
        #expect(throws: DecodingError.self) { _ = try reopened.load(usageID: usageID, pageIndex: 0) }
    }

    @Test func missingMarkupLoadsAsAConfirmedEmptyDocumentAndEditedDocumentPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PatternMarkupFileService(root: root)
        let usageID = UUID()
        let empty = try service.load(usageID: usageID, pageIndex: 3)
        var markup = PatternReaderMarkupSession()
        markup.beginLoading(readerGeneration: 9, pageIndex: 3)
        let didLoad = markup.finishLoading(empty, for: 9, pageIndex: 3)
        #expect(didLoad)
        markup.recordEdit(drawing)

        #expect(markup.canPersistMarkup(readerGeneration: 9, pageIndex: 3))
        try service.save(drawing, usageID: usageID, pageIndex: 3)
        markup.markPersisted(readerGeneration: 9, pageIndex: 3)
        #expect(try service.load(usageID: usageID, pageIndex: 3) == drawing)
    }

    @Test func validExistingMarkupRemainsUntouchedWhenNoEditOccursDuringLifecycleSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = PatternMarkupFileService(root: root)
        let usageID = UUID()
        try service.save(drawing, usageID: usageID, pageIndex: 2)
        let existing = try service.load(usageID: usageID, pageIndex: 2)
        var markup = PatternReaderMarkupSession()
        markup.beginLoading(readerGeneration: 3, pageIndex: 2)
        _ = markup.finishLoading(existing, for: 3, pageIndex: 2)

        #expect(!markup.canPersistMarkup(readerGeneration: 3, pageIndex: 2))
        #expect(try PatternMarkupFileService(root: root).load(usageID: usageID, pageIndex: 2) == drawing)
    }

    @Test func unsafeMarkupLoadFailureCannotTouchTheExternalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let marker = outside.appendingPathComponent("marker.txt")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("protected".utf8).write(to: marker)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("UsageMarkup", isDirectory: true),
            withDestinationURL: outside
        )
        let service = PatternMarkupFileService(root: root)
        var markup = PatternReaderMarkupSession()
        markup.beginLoading(readerGeneration: 7, pageIndex: 0)

        #expect(throws: PatternMarkupFileError.unsafePath) { _ = try service.load(usageID: UUID(), pageIndex: 0) }
        _ = markup.failLoading(for: 7, pageIndex: 0)
        #expect(!markup.canPersistMarkup(readerGeneration: 7, pageIndex: 0))
        #expect(try Data(contentsOf: marker) == Data("protected".utf8))
    }

    private var drawing: PatternMarkupDocument {
        PatternMarkupDocument(strokes: [
            .init(points: [.init(x: 0.2, y: 0.8)], color: .red, width: 0.008)
        ])
    }

    private func onlyMarkupFile(in root: URL) throws -> URL {
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".json") }
        return root.appendingPathComponent(try #require(files.first))
    }
}
