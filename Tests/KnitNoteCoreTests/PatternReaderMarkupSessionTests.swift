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
