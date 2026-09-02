import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct JSONProjectStoreSyncPublicationTests {
    @Test func successfulMutationPublishesOnlyAfterArchiveCommit() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink(archiveURL: fixture.archiveURL)
        let store = fixture.store(sink: sink)

        try store.rename(id: fixture.projectID, to: "Committed")

        #expect(sink.archiveProjectNamesAtPublication == ["Committed"])
        #expect(sink.mutations.map(\.recordKind) == [.project])
        #expect(store.syncPublicationError == nil)
    }

    @Test func archiveFailurePublishesNothingAndClearsPreparedTransaction() throws {
        let fixture = try SyncPublicationFixture()
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(
            sink: sink,
            archiveWrite: { _, _ in throw SyncPublicationInjectedFailure() }
        )
        let archiveBefore = try Data(contentsOf: fixture.archiveURL)
        let filesBefore = try fixture.regularFiles()

        #expect(throws: ProjectStoreError.persistenceFailed) {
            try store.rename(id: fixture.projectID, to: "Rejected")
        }

        #expect(sink.mutations.isEmpty)
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBefore)
        #expect(try fixture.regularFiles() == filesBefore)
        #expect(store.syncPublicationError == nil)
    }

    @Test func unlinkPublishesOnlyLinkDeletionAndNeverYarnDeletion() throws {
        let fixture = try SyncPublicationFixture(linkYarn: true)
        let sink = RecordingSyncMutationSink()
        let store = fixture.store(sink: sink)

        try store.setYarnProjects(yarnID: fixture.yarnID, projectIDs: [])

        #expect(sink.mutations.count == 1)
        #expect(sink.mutations.map(\.operation) == [.delete])
        #expect(sink.mutations.map(\.recordKind) == [.projectYarnLink])
        #expect(store.yarn(id: fixture.yarnID) != nil)
        #expect(store.yarn(id: fixture.yarnID)?.linkedProjectIDs.isEmpty == true)
    }

    @Test func publicationFailurePreservesCommittedPhotoAndBlocksUntilRestartRepair() throws {
        let fixture = try SyncPublicationFixture()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let store = fixture.store(sink: failingSink)
        let project = try #require(store.project(id: fixture.projectID))

        try store.updateProject(
            id: project.id,
            name: "Committed with photo",
            toolType: project.toolType,
            toolSize: project.toolSize,
            toolNotes: project.toolNotes,
            photoChange: .replace(try makeSyncPublicationJPEG(red: 0.3))
        )

        #expect(store.syncPublicationError == .pendingRepair)
        let committed = try #require(store.project(id: fixture.projectID))
        let committedPhotoURL = try #require(store.photoURL(for: committed))
        #expect(FileManager.default.fileExists(atPath: committedPhotoURL.path))
        let persisted = try fixture.archive()
        #expect(persisted.projects.first?.name == "Committed with photo")
        #expect(persisted.projects.first?.photoFilename == committed.photoFilename)

        let archiveBeforeRejectedMutation = try Data(contentsOf: fixture.archiveURL)
        let photoFilesBeforeRejectedMutation = try fixture.projectPhotoFiles()
        #expect(throws: SyncPublicationError.pendingRepair) {
            try store.updateProject(
                id: committed.id,
                name: "Must not commit",
                toolType: committed.toolType,
                toolSize: committed.toolSize,
                toolNotes: committed.toolNotes,
                photoChange: .replace(try makeSyncPublicationJPEG(red: 0.8))
            )
        }
        #expect(try Data(contentsOf: fixture.archiveURL) == archiveBeforeRejectedMutation)
        #expect(try fixture.projectPhotoFiles() == photoFilesBeforeRejectedMutation)

        let exactFailedMutations = failingSink.mutations
        let repairSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: repairSink)
        #expect(restarted.syncPublicationError == .pendingRepair)
        #expect(restarted.project(id: fixture.projectID)?.name == "Committed with photo")
        #expect(FileManager.default.fileExists(atPath: committedPhotoURL.path))

        try restarted.repairSyncPublication()

        #expect(repairSink.mutations == exactFailedMutations)
        #expect(restarted.syncPublicationError == nil)
        try restarted.rename(id: fixture.projectID, to: "Unblocked")
        #expect(restarted.project(id: fixture.projectID)?.name == "Unblocked")
        #expect(restarted.syncPublicationError == nil)
    }

    @Test func restartDiscardsValidMarkerWhenArchiveDoesNotMatchExpectedCommit() throws {
        let fixture = try SyncPublicationFixture()
        let originalArchive = try Data(contentsOf: fixture.archiveURL)
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        try first.rename(id: fixture.projectID, to: "Committed only in newer archive")
        #expect(first.syncPublicationError == .pendingRepair)

        try originalArchive.write(to: fixture.archiveURL, options: .atomic)
        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == nil)
        #expect(restartedSink.mutations.isEmpty)
        #expect(restarted.project(id: fixture.projectID)?.name == "Original")
        try restarted.rename(id: fixture.projectID, to: "Fresh mutation")
        #expect(restartedSink.mutations.map(\.recordKind) == [.project])
    }

    @Test func corruptPublicationTransactionSurvivesAndFailsClosed() throws {
        let fixture = try SyncPublicationFixture()
        let filesBefore = try fixture.regularFiles()
        let failingSink = RecordingSyncMutationSink(shouldFail: true)
        let first = fixture.store(sink: failingSink)
        try first.rename(id: fixture.projectID, to: "Committed")
        let newRegularFile = try fixture.newRegularFile(comparedWith: filesBefore)
        let transactionURL = try #require(newRegularFile)
        let corruptBytes = Data("not a publication transaction".utf8)
        try corruptBytes.write(to: transactionURL, options: .atomic)

        let restartedSink = RecordingSyncMutationSink()
        let restarted = fixture.store(sink: restartedSink)

        #expect(restarted.syncPublicationError == .corruptTransaction)
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.rename(id: fixture.projectID, to: "Blocked")
        }
        #expect(throws: SyncPublicationError.corruptTransaction) {
            try restarted.repairSyncPublication()
        }
        #expect(restartedSink.mutations.isEmpty)
        #expect(try Data(contentsOf: transactionURL) == corruptBytes)
    }

    @Test func journalSinkSynchronouslyEnqueuesExactMutation() throws {
        let fixture = try SyncPublicationFixture()
        let journal = FileSyncMutationJournal(
            url: fixture.root.appendingPathComponent("sync-mutations.json")
        )
        let sink = JournalSyncMutationSink(journal: journal)
        let mutation = SyncMutation.save(
            SyncEntityID(kind: .project, uuid: fixture.projectID),
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        try sink.publish(mutation)

        #expect(try journal.pending() == [mutation])
    }
}

private struct SyncPublicationInjectedFailure: Error {}

private final class RecordingSyncMutationSink: SyncMutationSink, @unchecked Sendable {
    private let lock = NSLock()
    private let archiveURL: URL?
    private let shouldFail: Bool
    private var recordedMutations: [SyncMutation] = []
    private var recordedArchiveProjectNames: [String] = []

    init(shouldFail: Bool = false, archiveURL: URL? = nil) {
        self.shouldFail = shouldFail
        self.archiveURL = archiveURL
    }

    func publish(_ mutation: SyncMutation) throws {
        let archiveName: String? = try archiveURL.map { url in
            let archive = try JSONDecoder().decode(
                ProjectArchive.self,
                from: Data(contentsOf: url)
            )
            return try #require(archive.projects.first?.name)
        }
        lock.lock()
        recordedMutations.append(mutation)
        if let archiveName {
            recordedArchiveProjectNames.append(archiveName)
        }
        lock.unlock()
        if shouldFail {
            throw SyncPublicationInjectedFailure()
        }
    }

    var mutations: [SyncMutation] {
        lock.withLock { recordedMutations }
    }

    var archiveProjectNamesAtPublication: [String] {
        lock.withLock { recordedArchiveProjectNames }
    }
}

private extension SyncMutation {
    enum TestOperation: Equatable {
        case save
        case delete
    }

    var recordKind: SyncEntityKind {
        switch self {
        case let .save(id, _), let .delete(id, _):
            id.kind
        }
    }

    var operation: TestOperation {
        switch self {
        case .save: .save
        case .delete: .delete
        }
    }
}

@MainActor private final class SyncPublicationFixture {
    let root: URL
    let liveRoot: URL
    let archiveURL: URL
    let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let yarnID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!

    init(linkYarn: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "json-project-store-sync-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        liveRoot = root.appendingPathComponent("KnitNote", isDirectory: true)
        archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let project = try StoredProject(id: projectID, name: "Original")
        var yarn = try StoredYarn(id: yarnID, name: "Merino")
        if linkYarn {
            yarn.setLinkedProjectIDs([projectID])
        }
        try JSONEncoder().encode(ProjectArchive(
            version: ProjectArchive.currentVersion,
            projects: [project],
            yarns: [yarn]
        )).write(to: archiveURL, options: .atomic)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func store(
        sink: any SyncMutationSink,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) -> JSONProjectStore {
        JSONProjectStore(
            url: archiveURL,
            backupService: KnitNoteBackupService(
                liveRoot: liveRoot,
                workRoot: root.appendingPathComponent("BackupWork", isDirectory: true)
            ),
            archiveWrite: archiveWrite,
            syncMutationSink: sink
        )
    }

    func archive() throws -> ProjectArchive {
        try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: archiveURL))
    }

    func regularFiles() throws -> Set<URL> {
        let children = try FileManager.default.contentsOfDirectory(
            at: liveRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        return try Set(children.filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        })
    }

    func newRegularFile(comparedWith original: Set<URL>) throws -> URL? {
        let candidates = try regularFiles().subtracting(original).filter { $0 != archiveURL }
        return candidates.count == 1 ? candidates.first : nil
    }

    func projectPhotoFiles() throws -> Set<String> {
        let directory = liveRoot.appendingPathComponent("ProjectPhotos", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}

private func makeSyncPublicationJPEG(red: CGFloat) throws -> Data {
    let context = try #require(CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}
