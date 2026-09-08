import CryptoKit
import Darwin
import Foundation

/// Exactly the legacy v1 stored properties and synthesized wire encoding.
struct SyncAccountRecoveryIntent: Codable, Equatable, Sendable {
    let formatVersion: Int
    let accountIDHash: String
    let accountRoot: URL
    let archiveURL: URL
    let journalURL: URL
    let vaultID: UUID
    let captureID: UUID
    let envelopeSHA256: Data
    let packetSHA256: Data
    let inventoryFingerprint: Data
    var phase: SyncAccountRecoveryTransaction.Phase
}

enum SyncAccountRecoveryControl: Equatable, Sendable {
    case legacySelection(SyncAccountRecoveryIntent)
    case selectedRecovery(SyncAccountRecoveryIntent, predecessorSHA256: Data)
    case absentSource(SyncAccountSourceState)
    case sourceSpent(SyncAccountSourceState, transactionID: UUID, preparedManifestSHA256: Data)
}

struct SyncAccountControlObservation: Equatable, Sendable {
    let mainBytes: Data?
    let nextBytes: Data?
    let state: SyncAccountRecoveryControl?
}

/// Small descriptor-scoped control mechanism, never authentication authority.
struct SyncAccountRecoveryControlFile {
    private typealias Error = SyncAccountRecoveryTransaction.Error
    private let sync: @Sendable (Int32) throws -> Void
    private static let main = "intent.json"
    private static let next = "intent-next.json"
    enum Boundary { case beforeNextWrite, nextWritten, beforeRename, beforeReadback }
    private let boundary: @Sendable (Boundary) throws -> Void
    init(synchronize: @escaping @Sendable (Int32) throws -> Void,
         boundary: @escaping @Sendable (Boundary) throws -> Void = { _ in }) {
        sync = synchronize; self.boundary = boundary
    }

    private struct PredecessorPayload: Codable {
        let predecessorSHA256: Data?
        let payload: Data
        enum CodingKeys: String, CodingKey { case predecessorSHA256, payload }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(predecessorSHA256, forKey: .predecessorSHA256)
            try c.encode(payload, forKey: .payload)
        }
    }
    private struct Wire: Codable {
        let formatVersion: Int
        let predecessorSHA256: Data?
        let payload: Data
        let checksum: Data
        enum CodingKeys: String, CodingKey { case formatVersion, predecessorSHA256, payload, checksum }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(predecessorSHA256, forKey: .predecessorSHA256)
            try c.encode(payload, forKey: .payload); try c.encode(checksum, forKey: .checksum)
        }
    }
    private struct Payload: Codable {
        let kind: String
        var intent: SyncAccountRecoveryIntent? = nil
        var predecessorSHA256: Data? = nil
        var source: SyncAccountSourceState? = nil
        var transactionID: UUID? = nil
        var preparedManifestSHA256: Data? = nil
    }

    static func encode(_ state: SyncAccountRecoveryControl, predecessorSHA256: Data?) throws -> Data {
        if case .legacySelection(let intent) = state {
            guard predecessorSHA256 == nil, intent.formatVersion == 1 else { throw Error.invalidAuthority }
            return try bounded(canonical(intent))
        }
        guard predecessorSHA256 == nil || predecessorSHA256?.count == 32 else { throw Error.invalidAuthority }
        let payload: Payload
        switch state {
        case .legacySelection: throw Error.invalidAuthority
        case .selectedRecovery(let intent, let predecessor):
            guard predecessor.count == 32, predecessor == predecessorSHA256, intent.formatVersion == 1 else { throw Error.invalidAuthority }
            payload = .init(kind: "selectedRecovery", intent: intent, predecessorSHA256: predecessor)
        case .absentSource(let source):
            try validate(source)
            if predecessorSHA256 == nil {
                guard case .freshAllocation = source.origin else { throw Error.invalidAuthority }
            }
            payload = .init(kind: "absentSource", source: source)
        case .sourceSpent(let source, let transactionID, let manifest):
            try validate(source)
            guard predecessorSHA256 != nil, manifest.count == 32 else { throw Error.invalidAuthority }
            payload = .init(kind: "sourceSpent", source: source, transactionID: transactionID, preparedManifestSHA256: manifest)
        }
        let bytes = try canonical(payload)
        let checksum = Data(SHA256.hash(data: try canonical(PredecessorPayload(predecessorSHA256: predecessorSHA256, payload: bytes))))
        return try bounded(canonical(Wire(formatVersion: 2, predecessorSHA256: predecessorSHA256, payload: bytes, checksum: checksum)))
    }

    static func decode(_ bytes: Data) throws -> SyncAccountRecoveryControl {
        _ = try bounded(bytes)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = object["formatVersion"] as? Int else { throw Error.invalidAuthority }
        if version == 1 {
            return .legacySelection(try JSONDecoder().decode(SyncAccountRecoveryIntent.self, from: bytes))
        }
        guard version == 2, Set(object.keys) == ["formatVersion", "predecessorSHA256", "payload", "checksum"] else { throw Error.invalidAuthority }
        let wire = try JSONDecoder().decode(Wire.self, from: bytes)
        guard wire.predecessorSHA256 == nil || wire.predecessorSHA256?.count == 32,
              wire.checksum == Data(SHA256.hash(data: try canonical(PredecessorPayload(predecessorSHA256: wire.predecessorSHA256, payload: wire.payload)))) else { throw Error.invalidAuthority }
        let payload = try JSONDecoder().decode(Payload.self, from: wire.payload)
        // Compare full JSON topology, including nested source/origin/intent keys.
        // Synthesis would otherwise silently drop unknown, mixed or null fields.
        guard try normalizedJSON(wire.payload) == normalizedJSON(canonical(payload)) else { throw Error.invalidAuthority }
        let state: SyncAccountRecoveryControl
        switch payload.kind {
        case "selectedRecovery":
            guard let intent = payload.intent, let predecessor = payload.predecessorSHA256,
                  payload.source == nil, payload.transactionID == nil, payload.preparedManifestSHA256 == nil,
                  predecessor == wire.predecessorSHA256 else { throw Error.invalidAuthority }
            state = .selectedRecovery(intent, predecessorSHA256: predecessor)
        case "absentSource":
            guard let source = payload.source, payload.intent == nil, payload.predecessorSHA256 == nil,
                  payload.transactionID == nil, payload.preparedManifestSHA256 == nil else { throw Error.invalidAuthority }
            state = .absentSource(source)
        case "sourceSpent":
            guard let source = payload.source, let transaction = payload.transactionID, let manifest = payload.preparedManifestSHA256,
                  payload.intent == nil, payload.predecessorSHA256 == nil else { throw Error.invalidAuthority }
            state = .sourceSpent(source, transactionID: transaction, preparedManifestSHA256: manifest)
        default: throw Error.invalidAuthority
        }
        _ = try encode(state, predecessorSHA256: wire.predecessorSHA256)
        return state
    }

    func observe(access: SyncAccountStorage.RecoveryAccess) throws -> SyncAccountControlObservation {
        try access.validate()
        guard let control = access.controlDescriptor else { return .init(mainBytes: nil, nextBytes: nil, state: nil) }
        let main = try read(Self.main, at: control), next = try read(Self.next, at: control)
        let result = try Self.observation(mainBytes: main, nextBytes: next)
        try access.validate()
        return result
    }

    static func observation(mainBytes main: Data?, nextBytes next: Data?) throws -> SyncAccountControlObservation {
        let state = try main.map(Self.decode)
        if let next {
            guard let main else { throw Error.invalidAuthority }
            if !Self.isRoutingOnlyLegacyDerivative(next, mainState: state) {
                _ = try Self.decode(next)
                guard let wire = try? JSONDecoder().decode(Wire.self, from: next), wire.formatVersion == 2,
                      wire.predecessorSHA256 == Data(SHA256.hash(data: main)) else { throw Error.invalidAuthority }
            }
        }
        return .init(mainBytes: main, nextBytes: next, state: state)
    }

    func synchronize(_ observation: SyncAccountControlObservation, access: SyncAccountStorage.RecoveryAccess) throws {
        guard try observe(access: access) == observation else { throw Error.changedInventory }
        if let control = access.controlDescriptor {
            for (name, bytes) in [(Self.main, observation.mainBytes), (Self.next, observation.nextBytes)] where bytes != nil {
                let fd = openat(control, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Error.invalidAuthority }
                defer { Darwin.close(fd) }
                try validateFile(fd, name: name, at: control)
                try sync(fd)
                try validateFile(fd, name: name, at: control)
            }
            try sync(control)
        }
        try sync(access.accountDescriptor)
        guard try observe(access: access) == observation else { throw Error.changedInventory }
    }

    func replace(_ observation: SyncAccountControlObservation, with state: SyncAccountRecoveryControl,
                 access: SyncAccountStorage.RecoveryAccess, validateSource: () throws -> Void) throws -> SyncAccountControlObservation {
        guard let control = access.controlDescriptor, let main = observation.mainBytes,
              try observe(access: access) == observation else { throw Error.changedInventory }
        if let next = observation.nextBytes,
           Self.isRoutingOnlyLegacyDerivative(next, mainState: observation.state) {
            // Observation is only a route to the existing authenticated owner.
            // It must synchronize/authenticate main and rebuild this derivative.
            throw Error.invalidAuthority
        }
        let bytes = try Self.encode(state, predecessorSHA256: Data(SHA256.hash(data: main)))
        try synchronize(observation, access: access)
        try validateSource()
        guard try observe(access: access) == observation else { throw Error.changedInventory }
        if observation.nextBytes != nil {
            guard unlinkat(control, Self.next, 0) == 0 else { throw Error.unavailable }
        }
        try boundary(.beforeNextWrite)
        try write(bytes, name: Self.next, at: control)
        let prepared = SyncAccountControlObservation(mainBytes: main, nextBytes: bytes, state: observation.state)
        guard try observe(access: access) == prepared else { throw Error.changedInventory }
        try validateSource()
        guard try observe(access: access) == prepared else { throw Error.changedInventory }
        try boundary(.beforeRename)
        guard renameat(control, Self.next, control, Self.main) == 0 else { throw Error.unavailable }
        try sync(control); try sync(access.accountDescriptor)
        try boundary(.beforeReadback)
        let committed = try observe(access: access)
        guard committed.mainBytes == bytes, committed.nextBytes == nil, committed.state == state else { throw Error.changedInventory }
        return committed
    }

    private static func isRoutingOnlyLegacyDerivative(_ bytes: Data, mainState: SyncAccountRecoveryControl?) -> Bool {
        guard case .legacySelection = mainState else { return false }
        // The v1 transition can leave any bounded prefix before its next-file
        // fsync. Those bytes have no state/cleanup authority. A recognizable v2
        // derivative still requires the normal checksum and predecessor checks.
        let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        return object?["formatVersion"] as? Int != 2
    }

    /// Called only by the storage owner after an actual mkdir and scaffold proof.
    func initializeFresh(_ source: SyncAccountSourceState, access: SyncAccountStorage.RecoveryAccess) throws {
        guard let control = access.controlDescriptor,
              try observe(access: access) == .init(mainBytes: nil, nextBytes: nil, state: nil),
              case .freshAllocation = source.origin else { throw Error.invalidAuthority }
        let bytes = try Self.encode(.absentSource(source), predecessorSHA256: nil)
        try write(bytes, name: Self.main, at: control)
        try synchronize(.init(mainBytes: bytes, nextBytes: nil, state: .absentSource(source)), access: access)
    }

    private func validateFile(_ fd: Int32, name: String, at root: Int32) throws {
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & S_IFMT == S_IFREG, named.st_mode & S_IFMT == S_IFREG,
              opened.st_nlink == 1, named.st_nlink == 1, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_size >= 0, opened.st_size <= 8192 else { throw Error.invalidAuthority }
    }
    private func read(_ name: String, at root: Int32) throws -> Data? {
        let fd = openat(root, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { guard errno == ENOENT else { throw Error.invalidAuthority }; return nil }
        defer { Darwin.close(fd) }
        try validateFile(fd, name: name, at: root)
        var before = stat(); guard fstat(fd, &before) == 0 else { throw Error.invalidAuthority }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Error.unavailable }; offset += count
            }
        }
        try validateFile(fd, name: name, at: root)
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Error.invalidAuthority }
        return bytes
    }
    private func write(_ bytes: Data, name: String, at root: Int32) throws {
        _ = try Self.bounded(bytes)
        let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Error.unavailable }
        defer { Darwin.close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Error.unavailable }; offset += count
            }
        }
        try validateFile(fd, name: name, at: root)
        if name == Self.next { try boundary(.nextWritten) }
        try sync(fd); try sync(root)
        try validateFile(fd, name: name, at: root)
    }
    static func validate(_ source: SyncAccountSourceState) throws {
        guard source.accountIDHash.count == 64, source.accountIDHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              source.accountRoot.isFileURL, source.archiveURL.isFileURL, source.journalURL.isFileURL,
              source.archiveURL.path == source.accountRoot.appendingPathComponent("working-set/projects-v1.json").path,
              source.journalURL.path.hasPrefix(source.accountRoot.path + "/"), source.baselineSHA256.count == 32 else { throw Error.invalidAuthority }
        switch source.origin {
        case .freshAllocation: break
        case .restoredSelection(_, _, let envelope, let packet, let deletion):
            guard envelope.count == 32, packet.count == 32, deletion == nil || deletion?.count == 32 else { throw Error.invalidAuthority }
        case .bootstrapRollback(_, let path, let envelope):
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  !path.utf8.contains(0), envelope.count == 32 else { throw Error.invalidAuthority }
        }
    }
    private static func bounded(_ bytes: Data) throws -> Data {
        guard bytes.count <= 8192 else { throw Error.tooLarge }; return bytes
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func normalizedJSON(_ bytes: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: bytes), options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
