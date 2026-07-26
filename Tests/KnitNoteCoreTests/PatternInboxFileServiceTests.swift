import Foundation
import Testing
@testable import KnitNoteCore

@MainActor
@Test func inboxPreservesValidatedSourceBytesAcrossRestart() throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "Original.pdf")
    let expected = try Data(contentsOf: source)

    let item = try harness.inbox.enqueue(
        source: source,
        origin: .shareExtension,
        targetProjectID: nil,
        now: Date(timeIntervalSince1970: 42)
    )
    let reloaded = PatternInboxFileService(root: harness.inbox.root)

    #expect(reloaded.item(id: item.id) == item)
    #expect(try Data(contentsOf: reloaded.stagedURL(for: item)) == expected)
}

@MainActor
@Test func inboxRejectsEmptyAndDisguisedFilesBeforePublishingAnItem() throws {
    let harness = try PatternImportHarness()
    let empty = try harness.writeFile(named: "Empty.pdf", bytes: Data())
    let disguised = try harness.writeFile(named: "Pretend.pdf", bytes: Data("not a PDF".utf8))

    #expect(throws: PatternFileError.empty) {
        try harness.inbox.enqueue(source: empty, origin: .library, targetProjectID: nil, now: .now)
    }
    #expect(throws: PatternFileError.invalidContent) {
        try harness.inbox.enqueue(source: disguised, origin: .library, targetProjectID: nil, now: .now)
    }
    #expect(harness.inbox.items().isEmpty)
}
