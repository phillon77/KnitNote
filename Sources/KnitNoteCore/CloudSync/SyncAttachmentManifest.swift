import CryptoKit
import Darwin
import Foundation

public enum SyncPublicationFileLimits {
    public static let maximumArchiveBytes = Int(KnitNoteBackupLimits.maximumArchiveBytes)
    public static let maximumAttachmentBytes = 100_000_000
}

public enum SyncAttachmentManifestError: Error, Equatable, Sendable {
    case corrupt
    case unsafeFile
    case unavailable
}

public struct SyncAttachmentManifestEntry: Codable, Equatable, Sendable {
    public let normalizedPath: String
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modificationNanoseconds: Int64
    public let contentSHA256: Data
    public let slot: SyncAttachmentSlot
    public let versionID: UUID

    public init(
        normalizedPath: String,
        device: UInt64,
        inode: UInt64,
        byteCount: Int64,
        modificationNanoseconds: Int64,
        contentSHA256: Data,
        slot: SyncAttachmentSlot,
        versionID: UUID
    ) {
        self.normalizedPath = normalizedPath
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.modificationNanoseconds = modificationNanoseconds
        self.contentSHA256 = contentSHA256
        self.slot = slot
        self.versionID = versionID
    }

    func validated() throws -> Self {
        let canonical = URL(fileURLWithPath: normalizedPath).standardizedFileURL.path
        guard normalizedPath.hasPrefix("/"),
              normalizedPath == canonical,
              normalizedPath.utf8.count <= 4_096,
              device > 0,
              inode > 0,
              byteCount >= 0,
              contentSHA256.count == SHA256.byteCount else {
            throw SyncAttachmentManifestError.corrupt
        }
        do {
            _ = try slot.validated()
        } catch {
            throw SyncAttachmentManifestError.corrupt
        }
        return self
    }
}

public enum SyncAttachmentManifestChange: Equatable, Sendable {
    case upsert(SyncAttachmentManifestEntry)
    case remove(String)
}

public protocol SyncAttachmentManifestStoring: Sendable {
    func load() throws -> [String: SyncAttachmentManifestEntry]
    func commit(_ entries: [String: SyncAttachmentManifestEntry]) throws
    func projection(
        for entries: [String: SyncAttachmentManifestEntry],
        changes: [SyncAttachmentManifestChange]
    ) throws -> [String: SyncAttachmentManifestEntry]
}

public final class SyncAttachmentManifestStore: SyncAttachmentManifestStoring, @unchecked Sendable {
    private static let currentVersion = 1
    private static let maximumEncodedBytes = 16 * 1_024 * 1_024

    private struct Envelope: Codable {
        let version: Int
        let entries: [SyncAttachmentManifestEntry]
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [String: SyncAttachmentManifestEntry] {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else { throw SyncAttachmentManifestError.unavailable }
            return [:]
        }
        guard Self.isRegularFile(status) else {
            throw SyncAttachmentManifestError.unsafeFile
        }
        let data: Data
        do {
            data = try SyncRegularFileReader().read(
                url,
                maximumBytes: Self.maximumEncodedBytes
            ).data
        } catch let error as SyncRegularFileReadError {
            throw Self.map(error)
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == Self.currentVersion else {
                throw SyncAttachmentManifestError.corrupt
            }
            return try Self.dictionary(from: envelope.entries)
        } catch let error as SyncAttachmentManifestError {
            throw error
        } catch {
            throw SyncAttachmentManifestError.corrupt
        }
    }

    public func commit(_ entries: [String: SyncAttachmentManifestEntry]) throws {
        let validated = try Self.validated(entries)
        let envelope = Envelope(
            version: Self.currentVersion,
            entries: try Self.orderedEntries(validated)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw SyncAttachmentManifestError.corrupt
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw SyncAttachmentManifestError.corrupt
        }

        do {
            try SyncDurableFile.withExclusiveFileLock(for: url) {
                var status = stat()
                let result = url.path.withCString { Darwin.lstat($0, &status) }
                if result == 0 {
                    guard Self.isRegularFile(status) else {
                        throw SyncAttachmentManifestError.unsafeFile
                    }
                    _ = try load()
                } else if errno != ENOENT {
                    throw SyncAttachmentManifestError.unavailable
                }
                try SyncDurableFile.write(data, to: url)
            }
        } catch let error as SyncAttachmentManifestError {
            throw error
        } catch let error as SyncDurableFileError {
            switch error {
            case .unsafeFile: throw SyncAttachmentManifestError.unsafeFile
            case .corrupt: throw SyncAttachmentManifestError.corrupt
            case .unavailable: throw SyncAttachmentManifestError.unavailable
            }
        } catch {
            throw SyncAttachmentManifestError.unavailable
        }
    }

    public func projection(
        for entries: [String: SyncAttachmentManifestEntry],
        changes: [SyncAttachmentManifestChange]
    ) throws -> [String: SyncAttachmentManifestEntry] {
        try Self.projection(for: entries, changes: changes)
    }

    static func projection(
        for entries: [String: SyncAttachmentManifestEntry],
        changes: [SyncAttachmentManifestChange]
    ) throws -> [String: SyncAttachmentManifestEntry] {
        var result = try Self.validated(entries)
        for change in changes {
            switch change {
            case let .upsert(entry):
                let entry = try entry.validated()
                result[try Self.key(for: entry)] = entry
            case let .remove(key):
                result.removeValue(forKey: key)
            }
        }
        return try Self.validated(result)
    }

    public static func key(for entry: SyncAttachmentManifestEntry) throws -> String {
        struct KeyPayload: Encodable {
            let normalizedPath: String
            let slot: SyncAttachmentSlot
        }
        let entry = try entry.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(KeyPayload(
            normalizedPath: entry.normalizedPath,
            slot: entry.slot
        )))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func orderedEntries(
        _ entries: [String: SyncAttachmentManifestEntry]
    ) throws -> [SyncAttachmentManifestEntry] {
        let validated = try validated(entries)
        return try validated.keys.sorted().map { key in
            guard let entry = validated[key] else {
                throw SyncAttachmentManifestError.corrupt
            }
            return entry
        }
    }

    static func dictionary(
        from entries: [SyncAttachmentManifestEntry]
    ) throws -> [String: SyncAttachmentManifestEntry] {
        var result: [String: SyncAttachmentManifestEntry] = [:]
        var slots: Set<SyncAttachmentSlot> = []
        var versionIDs: Set<UUID> = []
        for rawEntry in entries {
            let entry = try rawEntry.validated()
            let key = try key(for: entry)
            guard result[key] == nil,
                  slots.insert(entry.slot).inserted,
                  versionIDs.insert(entry.versionID).inserted else {
                throw SyncAttachmentManifestError.corrupt
            }
            result[key] = entry
        }
        return result
    }

    private static func validated(
        _ entries: [String: SyncAttachmentManifestEntry]
    ) throws -> [String: SyncAttachmentManifestEntry] {
        let rebuilt = try dictionary(from: Array(entries.values))
        guard rebuilt == entries else { throw SyncAttachmentManifestError.corrupt }
        return rebuilt
    }

    private static func map(_ error: SyncRegularFileReadError) -> SyncAttachmentManifestError {
        switch error {
        case .unsafeFile: .unsafeFile
        case .unavailable: .unavailable
        case .tooLarge, .replaced, .changed, .expectationMismatch: .corrupt
        }
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
    }
}
