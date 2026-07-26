import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    #expect(try reloaded.item(id: item.id) == item)
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
    #expect(try harness.inbox.items().isEmpty)
}

@MainActor
@Test func inboxRejectsJPEGBytesClaimedAsPNG() throws {
    let harness = try PatternImportHarness()
    let url = harness.sourceRoot.appendingPathComponent("disguised.png")
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))

    #expect(throws: PatternFileError.invalidContent) {
        try harness.inbox.enqueue(source: url, origin: .library, targetProjectID: nil, now: .now)
    }
}

@MainActor
@Test func inboxRejectsSymbolicLinkSourceBeforeCopyingIt() throws {
    let harness = try PatternImportHarness()
    let target = try harness.makePDF(named: "target.pdf")
    let link = harness.sourceRoot.appendingPathComponent("linked.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: PatternFileError.invalidContent) {
        try harness.inbox.enqueue(source: link, origin: .library, targetProjectID: nil, now: .now)
    }
    #expect(try harness.inbox.items().isEmpty)
}

@MainActor
@Test func recoveryQuarantinesOwnedOrphanedStagedFileInsteadOfSilentlyIgnoringIt() throws {
    let harness = try PatternImportHarness()
    let orphanID = UUID()
    let staged = harness.inbox.root
        .appendingPathComponent("Items", isDirectory: true)
        .appendingPathComponent("\(orphanID.uuidString).pdf")
    try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contentsOf: try harness.makePDF(named: "source.pdf")).write(to: staged)

    let reloaded = PatternInboxFileService(root: harness.inbox.root)
    let report = try reloaded.recover()

    #expect(report.quarantinedItemIDs.contains(orphanID))
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(try reloaded.items().isEmpty)
}

@MainActor
@Test func recoveryRejectsAndRemovesAnOwnedStagedSymbolicLink() throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "target.pdf")
    let item = try harness.inbox.enqueue(source: source, origin: .library, targetProjectID: nil, now: .now)
    let staged = try harness.inbox.stagedURL(for: item)
    try FileManager.default.removeItem(at: staged)
    try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: source)

    let report = try harness.inbox.recover()

    #expect(report.quarantinedItemIDs.contains(item.id))
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(try harness.inbox.item(id: item.id) == nil)
}

@MainActor
@Test func recoveryUnlinksAnOwnedCandidateSymbolicLinkWithoutFollowingIt() throws {
    let harness = try PatternImportHarness()
    let source = try harness.makePDF(named: "target.pdf")
    let candidate = harness.inbox.root
        .appendingPathComponent(".Candidates", isDirectory: true)
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: source)

    let report = try harness.inbox.recover()

    #expect(!report.removedCandidateIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(FileManager.default.fileExists(atPath: source.path))
}
