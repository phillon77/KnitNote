import CryptoKit
import Foundation

enum SyncBootstrapOutputRole: String, CaseIterable, Hashable, Sendable {
    case original = "Original", staged = "Staged", attachments = "Attachments"
    case validationOriginal = "ValidationOriginal", validationMerged = "ValidationMerged"
}

struct SyncBootstrapOutputProof: Equatable, Sendable {
    let byteCount: Int64
    let sha256: Data
}

enum SyncBootstrapOutputWriteMode: Equatable, Sendable {
    case create(SyncBootstrapOutputProof)
    case replace(expected: SyncBootstrapOutputProof, new: SyncBootstrapOutputProof)
}

enum SyncBootstrapOutputAction: Equatable, Sendable {
    case directory(role: SyncBootstrapOutputRole, path: String)
    case write(role: SyncBootstrapOutputRole, path: String, mode: SyncBootstrapOutputWriteMode, temporaryID: UUID)
    case reuseExact(role: SyncBootstrapOutputRole, path: String, proof: SyncBootstrapOutputProof)
    case lock(role: SyncBootstrapOutputRole, path: String, expectedExisting: SyncBootstrapOutputProof?)
}

/// Accounting data only. No member is evidence that a path is owned or writable.
struct SyncBootstrapOutputPlan: Equatable, Sendable {
    struct Reservation: Equatable, Sendable {
        let maximumEntryCount: Int
        let reservedEncodedProofBytes: Int
    }
    let transactionID: UUID
    let actionCount: Int
    let potentialEntries: [SyncAccountRecoveryInventory.Entry]
    let reservations: [SyncBootstrapOutputRole: Reservation]
    let namespaceReservedEncodedProofBytes: Int
    let reservedEncodedEntryBytes: Int
}

enum SyncBootstrapOutputPlanner {
    enum Error: Swift.Error, Equatable {
        case invalidBinding, invalidPath, collision, missingParent, invalidTransition, invalidProof, tooLarge
    }
    private enum Node: Equatable {
        case directory
        case file(SyncBootstrapOutputProof)
    }
    private struct Potential {
        let role: SyncBootstrapOutputRole?
        let isDirectory: Bool
        var byteCount: Int64
    }

    static func plan(accountIDHash: String, livePathSHA256: String, transactionID: UUID,
                     actions: [SyncBootstrapOutputAction], maximumMetadataBytes: Int = 100_000_000) throws -> SyncBootstrapOutputPlan {
        func isHash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard isHash(accountIDHash), isHash(livePathSHA256) else { throw Error.invalidBinding }
        guard (0...100_000_000).contains(maximumMetadataBytes) else { throw Error.tooLarge }
        let parts = [".KnitNote-SyncBootstrap", accountIDHash, livePathSHA256, transactionID.uuidString]
        let root = parts.joined(separator: "/")
        var nodes: [String: Node] = [:]
        var potentials: [String: Potential] = [:]
        var aliases: [String: String] = [:]
        var temporaryPaths = Set<String>()
        var lockPaths = Set<String>()

        func validPath(_ path: String) throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count <= 128,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
                  !path.contains("\\"), !path.utf8.contains(0) else { throw Error.invalidPath }
        }
        func register(_ path: String, role: SyncBootstrapOutputRole?, directory: Bool, bytes: Int64) throws {
            try validPath(path)
            guard !directory || path.split(separator: "/").count < 128 else { throw Error.invalidPath }
            let alias = path.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let old = aliases[alias], Array(old.utf8) != Array(path.utf8) { throw Error.collision }
            aliases[alias] = path
            if var old = potentials[path] {
                guard old.role == role, old.isDirectory == directory else { throw Error.collision }
                old.byteCount = max(old.byteCount, bytes); potentials[path] = old
            } else {
                potentials[path] = .init(role: role, isDirectory: directory, byteCount: bytes)
            }
        }
        func requireParent(_ path: String) throws {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            guard let index = nodes.index(forKey: parent), nodes[index].value == .directory else {
                throw Error.missingParent
            }
            // Dictionary lookup treats canonically equivalent Swift strings as equal.
            // Children must retain the exact spelling of their declared parent.
            guard nodes[index].key.utf8.elementsEqual(parent.utf8) else { throw Error.collision }
        }
        func full(_ role: SyncBootstrapOutputRole, _ relative: String, directory: Bool = false) throws -> String {
            if relative.isEmpty {
                guard directory else { throw Error.invalidPath }
                return root + "/" + role.rawValue
            }
            try validPath(relative)
            return root + "/" + role.rawValue + "/" + relative
        }
        func proof(_ value: SyncBootstrapOutputProof) throws {
            guard (0...100_000_000).contains(value.byteCount), value.sha256.count == 32 else { throw Error.invalidProof }
        }
        for index in parts.indices {
            let path = parts[...index].joined(separator: "/")
            nodes[path] = .directory
            try register(path, role: nil, directory: true, bytes: 0)
        }
        let empty = SyncBootstrapOutputProof(byteCount: 0, sha256: Data(SHA256.hash(data: Data())))
        for action in actions {
            switch action {
            case let .directory(role, relative):
                let path = try full(role, relative, directory: true)
                try requireParent(path)
                guard nodes[path] == nil, !temporaryPaths.contains(path) else { throw Error.collision }
                try register(path, role: role, directory: true, bytes: 0)
                nodes[path] = .directory
            case let .write(role, relative, mode, temporaryID):
                let path = try full(role, relative)
                try requireParent(path)
                guard !temporaryPaths.contains(path), !lockPaths.contains(path) else { throw Error.collision }
                let result: SyncBootstrapOutputProof
                switch mode {
                case let .create(value):
                    try proof(value)
                    guard nodes[path] == nil else { throw Error.invalidTransition }
                    result = value
                case let .replace(expected, value):
                    try proof(expected); try proof(value)
                    guard nodes[path] == .file(expected) else { throw Error.invalidTransition }
                    result = value
                }
                let components = path.split(separator: "/").map(String.init)
                let temporary = (components.dropLast() + ["." + components.last! + "." + temporaryID.uuidString + ".tmp"]).joined(separator: "/")
                guard nodes[temporary] == nil, temporaryPaths.insert(temporary).inserted else { throw Error.collision }
                try register(temporary, role: role, directory: false, bytes: result.byteCount)
                try register(path, role: role, directory: false, bytes: result.byteCount)
                nodes[path] = .file(result)
            case let .reuseExact(role, relative, expected):
                let path = try full(role, relative)
                try proof(expected); try requireParent(path)
                guard !temporaryPaths.contains(path), !lockPaths.contains(path), nodes[path] == .file(expected) else { throw Error.invalidTransition }
                try register(path, role: role, directory: false, bytes: expected.byteCount)
            case let .lock(role, relative, expected):
                let path = try full(role, relative)
                try requireParent(path)
                guard !temporaryPaths.contains(path) else { throw Error.collision }
                if let expected {
                    try proof(expected)
                    guard expected == empty, nodes[path] == .file(expected) else { throw Error.invalidTransition }
                } else {
                    guard nodes[path] == nil else { throw Error.invalidTransition }
                }
                try register(path, role: role, directory: false, bytes: 0)
                nodes[path] = .file(empty); lockPaths.insert(path)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let storageEncoder = JSONEncoder() // current recoveryEntries accounting escapes slashes
        var roleCounts: [SyncBootstrapOutputRole: Int] = [:]
        var roleBytes: [SyncBootstrapOutputRole: Int] = [:]
        var namespaceBytes = 2 // conservative array brackets
        var entries: [SyncAccountRecoveryInventory.Entry] = []
        func add(_ left: Int, _ right: Int) throws -> Int {
            let value = left.addingReportingOverflow(right)
            guard !value.overflow, value.partialValue <= maximumMetadataBytes else { throw Error.tooLarge }
            return value.partialValue
        }
        for path in potentials.keys.sorted() {
            let value = potentials[path]!
            let entry = SyncAccountRecoveryInventory.Entry(relativePath: path, isDirectory: value.isDirectory,
                byteCount: value.byteCount, sha256: value.isDirectory ? Data() : Data(repeating: 255, count: 32),
                device: UInt64.max, inode: UInt64.max)
            let canonicalCost = try encoder.encode(entry).count
            let storageCost = try storageEncoder.encode(entry).count
            let cost = try add(max(canonicalCost, storageCost), 1) // conservative comma per entry
            if let role = value.role {
                roleCounts[role, default: 0] += 1
                roleBytes[role] = try add(roleBytes[role] ?? 2, cost)
            } else { namespaceBytes = try add(namespaceBytes, cost) }
            entries.append(entry)
        }
        var total = namespaceBytes
        var reservations: [SyncBootstrapOutputRole: SyncBootstrapOutputPlan.Reservation] = [:]
        for role in SyncBootstrapOutputRole.allCases {
            guard let bytes = roleBytes[role], let count = roleCounts[role] else { continue }
            total = try add(total, bytes)
            reservations[role] = .init(maximumEntryCount: count, reservedEncodedProofBytes: bytes)
        }
        return .init(transactionID: transactionID, actionCount: actions.count, potentialEntries: entries,
            reservations: reservations, namespaceReservedEncodedProofBytes: namespaceBytes,
            reservedEncodedEntryBytes: total)
    }
}
