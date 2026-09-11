import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct JournalShareTemporaryExportServiceTests {
    @Test func exportWritesJPEGOnlyInsideOwnedRoot() throws {
        let fixture = try TemporaryExportFixture()
        defer { fixture.remove() }
        let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let entryID = UUID()

        let url = try fixture.service.exportJPEG(data, entryID: entryID)

        #expect(url.pathExtension == "jpg")
        #expect(url.deletingLastPathComponent() == fixture.root)
        #expect(url.lastPathComponent.hasPrefix(entryID.uuidString + "-"))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func repeatedExportsUseUnpredictableNames() throws {
        let fixture = try TemporaryExportFixture()
        defer { fixture.remove() }
        let entryID = UUID()

        let first = try fixture.service.exportJPEG(Data([1]), entryID: entryID)
        let second = try fixture.service.exportJPEG(Data([2]), entryID: entryID)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(try Data(contentsOf: second) == Data([2]))
    }

    @Test func canonicalSystemTemporaryParentAliasIsAccepted() throws {
        let physicalTemporaryDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard physicalTemporaryDirectory.path.hasPrefix("/private/var/") else { return }
        let aliasPath = "/var/" + physicalTemporaryDirectory.path.dropFirst("/private/var/".count)
        let aliasRoot = URL(fileURLWithPath: aliasPath, isDirectory: true)
            .appendingPathComponent("journal-share-alias-\(UUID())", isDirectory: true)
        let service = JournalShareTemporaryExportService(root: aliasRoot)
        defer { try? FileManager.default.removeItem(at: aliasRoot.resolvingSymlinksInPath()) }

        let result = try service.exportJPEG(Data([1]), entryID: UUID())

        #expect(result.deletingLastPathComponent().path.hasPrefix("/private/var/"))
        #expect(FileManager.default.fileExists(atPath: result.path))
    }

    @Test func removeRejectsOutsideTarget() throws {
        let fixture = try TemporaryExportFixture()
        defer { fixture.remove() }
        let outside = fixture.container.appendingPathComponent("keep.jpg")
        try Data([1]).write(to: outside)

        #expect(throws: JournalShareTemporaryExportError.unsafeURL) {
            try fixture.service.removeExport(at: outside)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func removeRejectsSymlinkTarget() throws {
        let fixture = try TemporaryExportFixture()
        defer { fixture.remove() }
        let outside = fixture.container.appendingPathComponent("keep.jpg")
        try Data([1]).write(to: outside)
        let link = fixture.root.appendingPathComponent(TemporaryExportFixture.ownedFilename())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: JournalShareTemporaryExportError.unsafeURL) {
            try fixture.service.removeExport(at: link)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func removeRejectsNonownedFilenameInsideRoot() throws {
        let fixture = try TemporaryExportFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("keep.jpg")
        try Data([1]).write(to: file)

        #expect(throws: JournalShareTemporaryExportError.unsafeURL) {
            try fixture.service.removeExport(at: file)
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func symlinkedOwnedRootIsRejectedWithoutTouchingDestination() throws {
        let fixture = try TemporaryExportFixture(createRoot: false)
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: destination)
        let service = JournalShareTemporaryExportService(root: fixture.root)

        #expect(throws: JournalShareTemporaryExportError.unsafeURL) {
            try service.exportJPEG(Data([1]), entryID: UUID())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func staleCleanupBeforeFirstExportIsANoOp() throws {
        let fixture = try TemporaryExportFixture(createRoot: false)
        defer { fixture.remove() }

        let removed = try fixture.service.removeStaleExports(olderThan: 60)

        #expect(removed == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func retargetedParentAliasCannotMoveOwnershipBoundary() throws {
        let fixture = try TemporaryExportFixture(createRoot: false)
        defer { fixture.remove() }
        let firstParent = fixture.container.appendingPathComponent("first", isDirectory: true)
        let secondParent = fixture.container.appendingPathComponent("second", isDirectory: true)
        let aliasParent = fixture.container.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: firstParent)
        let aliasRoot = aliasParent.appendingPathComponent("owned", isDirectory: true)
        let service = JournalShareTemporaryExportService(root: aliasRoot)
        _ = try service.exportJPEG(Data([1]), entryID: UUID())
        try FileManager.default.removeItem(at: aliasParent)
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: secondParent)
        let secondRoot = secondParent.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        let protected = secondRoot.appendingPathComponent(TemporaryExportFixture.ownedFilename())
        try Data([2]).write(to: protected)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: protected.path
        )

        #expect(throws: JournalShareTemporaryExportError.unsafeURL) {
            try service.removeStaleExports(olderThan: 60, now: Date(timeIntervalSince1970: 120))
        }
        #expect(FileManager.default.fileExists(atPath: protected.path))
    }

    @Test func staleCleanupIsBoundedKeepsRecentAndIgnoresUnsafeChildren() throws {
        let fixture = try TemporaryExportFixture()
        defer { fixture.remove() }
        let firstOld = try fixture.service.exportJPEG(Data([1]), entryID: UUID())
        let secondOld = try fixture.service.exportJPEG(Data([2]), entryID: UUID())
        let recent = try fixture.service.exportJPEG(Data([3]), entryID: UUID())
        let nonowned = fixture.root.appendingPathComponent("keep.jpg")
        try Data([4]).write(to: nonowned)
        let outside = fixture.container.appendingPathComponent("outside.jpg")
        try Data([5]).write(to: outside)
        let symlink = fixture.root.appendingPathComponent(TemporaryExportFixture.ownedFilename())
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        for url in [firstOld, secondOld, nonowned] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 0)],
                ofItemAtPath: url.path
            )
        }

        let removed = try fixture.service.removeStaleExports(
            olderThan: 60,
            now: Date(timeIntervalSince1970: 120),
            maximumRemovals: 1
        )

        #expect(removed == 1)
        #expect([firstOld, secondOld].filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: nonowned.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}

private struct TemporaryExportFixture {
    let container: URL
    let root: URL
    let service: JournalShareTemporaryExportService

    init(createRoot: Bool = true) throws {
        container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("journal-share-tests-\(UUID())", isDirectory: true)
        root = container.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        if createRoot {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        service = JournalShareTemporaryExportService(root: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }

    static func ownedFilename(entryID: UUID = UUID(), nonce: UUID = UUID()) -> String {
        "\(entryID.uuidString)-\(nonce.uuidString).jpg"
    }
}
