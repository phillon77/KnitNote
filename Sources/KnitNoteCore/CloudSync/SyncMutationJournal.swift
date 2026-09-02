import CryptoKit
import Darwin
import Foundation

public enum SyncMutationIntent: String, Codable, Equatable, Sendable {
    case save
    case delete
}

public struct SyncMutationIdentity: Codable, Equatable, Hashable, Sendable {
    public let recordID: SyncEntityID
    public let mutationID: UUID

    public init(recordID: SyncEntityID, mutationID: UUID) {
        self.recordID = recordID
        self.mutationID = mutationID
    }
}

public struct SyncAttachmentSource: Codable, Equatable, Sendable {
    public let fileURL: URL
    public let contentSHA256: Data
    public let byteCount: Int64
    public let isJournalStaged: Bool

    public init(fileURL: URL, contentSHA256: Data, byteCount: Int64) throws {
        self.init(
            fileURL: fileURL,
            contentSHA256: contentSHA256,
            byteCount: byteCount,
            isJournalStaged: false
        )
        _ = try validated()
    }

    init(fileURL: URL, contentSHA256: Data, byteCount: Int64, isJournalStaged: Bool) {
        self.fileURL = fileURL
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.isJournalStaged = isJournalStaged
    }

    func validated() throws -> Self {
        guard fileURL.isFileURL,
              contentSHA256.count == SHA256.byteCount,
              byteCount >= 0 else {
            throw SyncMutationJournalError.invalidAttachment
        }
        return self
    }
}

public struct SyncSaveMutation: Codable, Equatable, Sendable {
    public let recordVersion: SyncRecordVersion
    public let attachmentSource: SyncAttachmentSource?
    public let mutationID: UUID

    public init(
        recordVersion: SyncRecordVersion,
        attachmentSource: SyncAttachmentSource? = nil,
        mutationID: UUID
    ) throws {
        self.recordVersion = try recordVersion.validated()
        self.attachmentSource = try attachmentSource?.validated()
        self.mutationID = mutationID
        try validateAttachmentBinding()
    }

    func replacingAttachmentSource(_ source: SyncAttachmentSource?) throws -> Self {
        try Self(
            recordVersion: recordVersion,
            attachmentSource: source,
            mutationID: mutationID
        )
    }

    func validated() throws -> Self {
        _ = try recordVersion.validated()
        _ = try attachmentSource?.validated()
        try validateAttachmentBinding()
        return self
    }

    func validatedForJournalLoad() throws -> Self {
        if recordVersion.record.id.kind == .knittingReminder {
            _ = try recordVersion.validatedForLegacyStandaloneReminderJournalMigration()
            _ = try attachmentSource?.validated()
            try validateAttachmentBinding()
            return self
        }
        return try validated()
    }

    private func validateAttachmentBinding() throws {
        let record = recordVersion.record
        if record.id.kind == .attachment {
            guard let attachment = try record.payload.attachment?.validated(),
                  record.id.uuid == attachment.versionID,
                  record.relationships.contains(where: {
                      $0.role == "owner" && $0.target == attachment.slot.owner
                  }),
                  let attachmentSource,
                  attachmentSource.contentSHA256 == attachment.contentSHA256,
                  attachmentSource.byteCount == attachment.byteCount else {
                throw SyncMutationJournalError.invalidAttachment
            }
        } else if record.payload.attachment != nil || attachmentSource != nil {
            throw SyncMutationJournalError.invalidAttachment
        }
    }
}

public struct SyncDeleteMutation: Codable, Equatable, Sendable {
    public let recordID: SyncEntityID
    public let mutationID: UUID

    public init(recordID: SyncEntityID, mutationID: UUID) {
        self.recordID = recordID
        self.mutationID = mutationID
    }
}

public enum SyncMutation: Codable, Equatable, Sendable {
    case save(SyncSaveMutation)
    case delete(SyncDeleteMutation)

    public static func save(
        recordVersion: SyncRecordVersion,
        attachmentSource: SyncAttachmentSource? = nil,
        mutationID: UUID
    ) throws -> Self {
        .save(try SyncSaveMutation(
            recordVersion: recordVersion,
            attachmentSource: attachmentSource,
            mutationID: mutationID
        ))
    }

    public static func delete(_ recordID: SyncEntityID, mutationID: UUID) -> Self {
        .delete(SyncDeleteMutation(recordID: recordID, mutationID: mutationID))
    }

    public var recordID: SyncEntityID {
        switch self {
        case let .save(save): save.recordVersion.record.id
        case let .delete(delete): delete.recordID
        }
    }

    public var mutationID: UUID {
        switch self {
        case let .save(save): save.mutationID
        case let .delete(delete): delete.mutationID
        }
    }

    public var identity: SyncMutationIdentity {
        SyncMutationIdentity(recordID: recordID, mutationID: mutationID)
    }

    public var intent: SyncMutationIntent {
        switch self {
        case .save: .save
        case .delete: .delete
        }
    }

    public var savedRecordVersion: SyncRecordVersion? {
        guard case let .save(save) = self else { return nil }
        return save.recordVersion
    }

    public var attachmentSource: SyncAttachmentSource? {
        guard case let .save(save) = self else { return nil }
        return save.attachmentSource
    }

    func replacingAttachmentSource(_ source: SyncAttachmentSource?) throws -> Self {
        guard case let .save(save) = self else { return self }
        return .save(try save.replacingAttachmentSource(source))
    }

    func validated() throws -> Self {
        switch self {
        case let .save(save): return .save(try save.validated())
        case .delete: return self
        }
    }

    func validatedForJournalLoad() throws -> Self {
        switch self {
        case let .save(save): return .save(try save.validatedForJournalLoad())
        case .delete: return self
        }
    }
}

public enum SyncMutationJournalError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
    case tooLarge
    case duplicateMutationID
    case invalidAttachment
}

public protocol SyncMutationJournalProtocol: Sendable {
    func enqueue(_ mutations: [SyncMutation]) throws
    func pending() throws -> [SyncMutation]
    func acknowledge(_ identities: Set<SyncMutationIdentity>) throws
}

public extension SyncMutationJournalProtocol {
    func enqueue(_ mutation: SyncMutation) throws {
        try enqueue([mutation])
    }

    func acknowledge(recordID: SyncEntityID, mutationID: UUID) throws {
        try acknowledge([SyncMutationIdentity(recordID: recordID, mutationID: mutationID)])
    }
}

public final class FileSyncMutationJournal: SyncMutationJournalProtocol, @unchecked Sendable {
    public static let maximumEncodedBytes = 64 * 1_024 * 1_024

    typealias AtomicWrite = @Sendable (Data, URL) throws -> Void
    typealias SynchronizeDirectory = @Sendable (URL) throws -> Void

    private let url: URL
    private let atomicWrite: AtomicWrite
    private let lock = NSLock()
    private var loadedMutations: [SyncMutation]?

    private var attachmentsDirectory: URL {
        url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).attachments",
            isDirectory: true
        )
    }

    public convenience init(url: URL) {
        self.init(url: url, synchronizeDirectory: Self.defaultSynchronizeDirectory)
    }

    convenience init(url: URL, synchronizeDirectory: @escaping SynchronizeDirectory) {
        self.init(
            url: url,
            atomicWrite: { data, destination in
                try Self.defaultAtomicWrite(
                    data,
                    to: destination,
                    synchronizeDirectory: synchronizeDirectory
                )
            }
        )
    }

    init(url: URL, atomicWrite: @escaping AtomicWrite) {
        self.url = url
        self.atomicWrite = atomicWrite
    }

    public func enqueue(_ mutations: [SyncMutation]) throws {
        guard !mutations.isEmpty else { return }
        try lock.withLock {
            let current = try mutationsLocked()
            var byMutationID = Dictionary(uniqueKeysWithValues: current.map { ($0.mutationID, $0) })
            var candidate = current
            for requested in mutations {
                let requested = try requested.validated()
                if let existing = byMutationID[requested.mutationID] {
                    guard Self.hasSameImmutableIdentity(existing, requested) else {
                        throw SyncMutationJournalError.duplicateMutationID
                    }
                    continue
                }
                let staged = try stageAttachmentIfNeeded(for: requested)
                byMutationID[staged.mutationID] = staged
                candidate.append(staged)
            }

            // Re-persist even when every identity already exists. This repairs
            // ambiguous post-rename durability without appending duplicates.
            try persistReconcilingMemoryLocked(candidate)
        }
    }

    private static func hasSameImmutableIdentity(
        _ lhs: SyncMutation,
        _ rhs: SyncMutation
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.delete(left), .delete(right)):
            return left == right
        case let (.save(left), .save(right)):
            guard left.mutationID == right.mutationID,
                  left.recordVersion == right.recordVersion else { return false }
            switch (left.attachmentSource, right.attachmentSource) {
            case (nil, nil):
                return true
            case let (.some(leftSource), .some(rightSource)):
                return leftSource.contentSHA256 == rightSource.contentSHA256
                    && leftSource.byteCount == rightSource.byteCount
            default:
                return false
            }
        default:
            return false
        }
    }

    public func pending() throws -> [SyncMutation] {
        try lock.withLock { try mutationsLocked() }
    }

    public func acknowledge(_ identities: Set<SyncMutationIdentity>) throws {
        guard !identities.isEmpty else { return }
        try lock.withLock {
            let current = try mutationsLocked()
            let removed = current.filter { identities.contains($0.identity) }
            guard !removed.isEmpty else { return }
            let candidate = current.filter { !identities.contains($0.identity) }
            try persistReconcilingMemoryLocked(candidate)
            for mutation in removed {
                removeStagedAttachmentIfUnreferenced(mutation, remaining: candidate)
            }
        }
    }

    private func mutationsLocked() throws -> [SyncMutation] {
        if let loadedMutations { return loadedMutations }
        let mutations = try readLiveMutationsLocked()
        loadedMutations = mutations
        return mutations
    }

    private func readLiveMutationsLocked() throws -> [SyncMutation] {
        guard let data = try readDataFromRegularFile() else { return [] }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SyncMutationJournalError.corrupt
        }
        guard envelope.version == Envelope.currentVersion else {
            throw SyncMutationJournalError.corrupt
        }
        var seenMutationIDs = Set<UUID>()
        return try envelope.mutations.map { mutation in
            let validated = try mutation.validatedForJournalLoad()
            guard seenMutationIDs.insert(validated.mutationID).inserted else {
                throw SyncMutationJournalError.corrupt
            }
            try validatePersistedAttachmentSource(in: validated)
            return validated
        }
    }

    private func persistReconcilingMemoryLocked(_ mutations: [SyncMutation]) throws {
        do {
            try persistLocked(mutations)
            loadedMutations = mutations
        } catch {
            let persistenceError = error
            do {
                loadedMutations = try readLiveMutationsLocked()
            } catch {
                loadedMutations = nil
            }
            throw persistenceError
        }
    }

    private func persistLocked(_ mutations: [SyncMutation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[.encodeLegacyStandaloneReminderForMigration] = true
        let data = try encoder.encode(Envelope(mutations: mutations))
        guard data.count <= Self.maximumEncodedBytes else {
            throw SyncMutationJournalError.tooLarge
        }
        try atomicWrite(data, url)
    }

    private struct Envelope: Codable {
        static let currentVersion = 2
        let version: Int
        let mutations: [SyncMutation]

        init(mutations: [SyncMutation]) {
            version = Self.currentVersion
            self.mutations = mutations
        }
    }

    private func readDataFromRegularFile() throws -> Data? {
        var pathStatus = stat()
        let pathResult = url.path.withCString { Darwin.lstat($0, &pathStatus) }
        if pathResult != 0 {
            guard errno == ENOENT else { throw currentPOSIXError() }
            return nil
        }
        do {
            return try SyncRegularFileReader().read(
                url,
                maximumBytes: Self.maximumEncodedBytes
            ).data
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile:
                throw SyncMutationJournalError.unsafeFile
            case .tooLarge:
                throw SyncMutationJournalError.tooLarge
            case .unavailable, .replaced, .changed, .expectationMismatch:
                throw SyncMutationJournalError.corrupt
            }
        }
    }

    private func stageAttachmentIfNeeded(for mutation: SyncMutation) throws -> SyncMutation {
        guard let source = mutation.attachmentSource else { return mutation }
        if source.isJournalStaged {
            try validatePersistedAttachmentSource(in: mutation)
            return mutation
        }

        try ensureSafeAttachmentsDirectory()
        let versionID = try requiredAttachmentVersionID(in: mutation)
        let destination = attachmentsDirectory.appendingPathComponent(
            "\(mutation.mutationID.uuidString)-\(versionID.uuidString).asset",
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try verifyRegularFile(
                at: destination,
                expectedByteCount: source.byteCount,
                expectedSHA256: source.contentSHA256
            )
        } else {
            try copyAttachmentAtomically(from: source, to: destination)
        }
        let staged = SyncAttachmentSource(
            fileURL: destination,
            contentSHA256: source.contentSHA256,
            byteCount: source.byteCount,
            isJournalStaged: true
        )
        return try mutation.replacingAttachmentSource(staged)
    }

    private func requiredAttachmentVersionID(in mutation: SyncMutation) throws -> UUID {
        guard let version = mutation.savedRecordVersion?.record.payload.attachment else {
            throw SyncMutationJournalError.invalidAttachment
        }
        return version.versionID
    }

    private func validatePersistedAttachmentSource(in mutation: SyncMutation) throws {
        guard let source = mutation.attachmentSource else { return }
        guard source.isJournalStaged else {
            throw SyncMutationJournalError.invalidAttachment
        }
        let root = attachmentsDirectory.standardizedFileURL
        let file = source.fileURL.standardizedFileURL
        guard file.deletingLastPathComponent().path == root.path,
              file.path.hasPrefix(root.path + "/"),
              file.resolvingSymlinksInPath().path == file.path else {
            throw SyncMutationJournalError.unsafeFile
        }
        try verifyRegularFile(
            at: file,
            expectedByteCount: source.byteCount,
            expectedSHA256: source.contentSHA256
        )
    }

    private func ensureSafeAttachmentsDirectory() throws {
        let parent = attachmentsDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var status = stat()
        let result = attachmentsDirectory.path.withCString { Darwin.lstat($0, &status) }
        if result == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR else {
                throw SyncMutationJournalError.unsafeFile
            }
            return
        }
        guard errno == ENOENT else { throw currentPOSIXError() }
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: false)
        try Self.defaultSynchronizeDirectory(parent)
    }

    private func copyAttachmentAtomically(
        from source: SyncAttachmentSource,
        to destination: URL
    ) throws {
        let sourceData = try readVerifiedAttachment(
            at: source.fileURL,
            expectedByteCount: source.byteCount,
            expectedSHA256: source.contentSHA256
        )

        let temporary = attachmentsDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let destinationDescriptor = try Self.openNewFile(at: temporary)
        var temporaryExists = true
        defer {
            Darwin.close(destinationDescriptor)
            if temporaryExists { _ = temporary.path.withCString { Darwin.unlink($0) } }
        }

        try Self.write(sourceData, to: destinationDescriptor)
        guard Darwin.fsync(destinationDescriptor) == 0 else { throw currentPOSIXError() }
        guard temporary.path.withCString({ sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }) == 0 else {
            throw currentPOSIXError()
        }
        temporaryExists = false
        try Self.defaultSynchronizeDirectory(attachmentsDirectory)
    }

    private func verifyRegularFile(
        at file: URL,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws {
        _ = try readVerifiedAttachment(
            at: file,
            expectedByteCount: expectedByteCount,
            expectedSHA256: expectedSHA256
        )
    }

    private func readVerifiedAttachment(
        at file: URL,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws -> Data {
        guard expectedByteCount >= 0,
              expectedByteCount <= Int64(Int.max) else {
            throw SyncMutationJournalError.invalidAttachment
        }
        do {
            return try SyncRegularFileReader().read(
                file,
                maximumBytes: Int(expectedByteCount),
                expected: .init(byteCount: expectedByteCount, sha256: expectedSHA256)
            ).data
        } catch let error as SyncRegularFileReadError {
            switch error {
            case .unsafeFile:
                throw SyncMutationJournalError.unsafeFile
            case .unavailable, .tooLarge, .replaced, .changed, .expectationMismatch:
                throw SyncMutationJournalError.invalidAttachment
            }
        }
    }

    private func removeStagedAttachmentIfUnreferenced(
        _ mutation: SyncMutation,
        remaining: [SyncMutation]
    ) {
        guard let source = mutation.attachmentSource,
              source.isJournalStaged,
              !remaining.contains(where: { $0.attachmentSource?.fileURL == source.fileURL }) else {
            return
        }
        var status = stat()
        guard source.fileURL.path.withCString({ Darwin.lstat($0, &status) }) == 0,
              Self.isRegularFile(status) else { return }
        if source.fileURL.path.withCString({ Darwin.unlink($0) }) == 0 {
            try? Self.defaultSynchronizeDirectory(attachmentsDirectory)
        }
    }

    private static func defaultAtomicWrite(
        _ data: Data,
        to destination: URL,
        synchronizeDirectory: SynchronizeDirectory
    ) throws {
        guard data.count <= maximumEncodedBytes else {
            throw SyncMutationJournalError.tooLarge
        }
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        var liveStatus = stat()
        let liveResult = destination.path.withCString { Darwin.lstat($0, &liveStatus) }
        if liveResult == 0, !isRegularFile(liveStatus) {
            throw SyncMutationJournalError.unsafeFile
        }
        if liveResult != 0, errno != ENOENT { throw currentPOSIXError() }

        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var temporaryExists = false
        defer { if temporaryExists { try? fileManager.removeItem(at: temporary) } }

        let descriptor = try openNewFile(at: temporary)
        temporaryExists = true
        do {
            defer { Darwin.close(descriptor) }
            try write(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
        }

        let renameResult = temporary.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else { throw currentPOSIXError() }
        temporaryExists = false
        try synchronizeDirectory(parent)
    }

    private static func openNewFile(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        return descriptor
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var writtenByteCount = 0
            while writtenByteCount < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    bytes.count - writtenByteCount
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw currentPOSIXError() }
                writtenByteCount += result
            }
        }
    }

    private static func defaultSynchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }

    private func currentPOSIXError() -> POSIXError { Self.currentPOSIXError() }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
