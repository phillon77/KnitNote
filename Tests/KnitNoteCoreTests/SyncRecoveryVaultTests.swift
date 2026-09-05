import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncRecoveryVaultTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sealReopensExactPayloadWithoutPlaintextAndUsesDistinctKeys() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let bytes = Data("sole unsent journal and immutable attachment source".utf8)
        let first = try f.vault.seal(bytes, account: f.a, now: now)
        let second = try f.vault.seal(bytes, account: f.a, now: now)
        let reopened = SyncRecoveryVault(directory: f.root, keychain: f.keys)
        #expect(try reopened.restore(first, account: f.a, now: now) == bytes)
        #expect(first != second)
        #expect(Set(f.keys.values.values).count == 2)
        for url in try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: url).range(of: bytes) == nil)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func wrongAccountWrongKeyAndMissingKeyFailClosed() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let id = try f.vault.seal(Data("unsent".utf8), account: f.a, now: now)
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.b, now: now) }
        let saved = f.keys.values
        f.keys.values = saved.mapValues { _ in Data(repeating: 7, count: 32) }
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now) }
        f.keys.values = [:]
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now) }
        f.keys.values = saved
        #expect(try f.vault.restore(id, account: f.a, now: now) == Data("unsent".utf8))
    }

    @Test func rejectsCiphertextAndEveryAuthenticatedMetadataTamper() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let id = try f.vault.seal(Data("unsent".utf8), account: f.a, now: now)
        let url = f.root.appendingPathComponent(id.uuidString.lowercased() + ".vault")
        let original = try Data(contentsOf: url)
        let envelope = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        for field in ["accountIDHash", "createdAt", "expiresAt", "payloadHash", "formatVersion", "vaultID"] {
            var changed = envelope
            let encodedMetadata = try #require(changed["metadata"] as? String)
            let raw = try #require(Data(base64Encoded: encodedMetadata))
            var metadata = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            switch field {
            case "accountIDHash": metadata[field] = f.b.accountIDHash
            case "formatVersion": metadata[field] = 2
            case "vaultID": metadata[field] = UUID().uuidString
            case "payloadHash": metadata[field] = Data(repeating: 3, count: 32).base64EncodedString()
            default:
                // Keep dates internally valid: only AES authentication can reject
                // this pair, rather than a JSON type or lifetime-format check.
                let shift = field == "createdAt" ? -60.0 : 60.0
                metadata["createdAt"] = now.timeIntervalSince1970 + shift
                metadata["expiresAt"] = now.timeIntervalSince1970 + 2_592_000 + shift
            }
            changed["metadata"] = try JSONSerialization.data(withJSONObject: metadata).base64EncodedString()
            try JSONSerialization.data(withJSONObject: changed).write(to: url)
            #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now) }
        }
        var changed = envelope
        let encodedCiphertext = try #require(changed["ciphertext"] as? String)
        var ciphertext = try #require(Data(base64Encoded: encodedCiphertext))
        ciphertext[ciphertext.count - 1] ^= 1
        changed["ciphertext"] = ciphertext.base64EncodedString()
        try JSONSerialization.data(withJSONObject: changed).write(to: url)
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now) }
        try original.write(to: url)
        #expect(try f.vault.restore(id, account: f.a, now: now) == Data("unsent".utf8))
    }

    @Test func exactThirtyDayExpiryAndPurgeRequireAuthenticatedOriginalAccount() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let id = try f.vault.seal(Data([1, 2, 3]), account: f.a, now: now)
        let expiry = now.addingTimeInterval(2_592_000)
        #expect(try f.vault.restore(id, account: f.a, now: expiry.addingTimeInterval(-0.001)) == Data([1, 2, 3]))
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: expiry) }
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now.addingTimeInterval(-1)) }
        #expect(try f.vault.purgeExpired(account: f.a, now: now).isEmpty)
        #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.b, now: expiry) }
        #expect(f.keys.values.count == 1)
        #expect(try f.vault.purgeExpired(account: f.a, now: expiry) == [id])
        #expect(f.keys.values.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }

    @Test func failedKeyPersistenceNeverReturnsSealedVault() throws {
        let f = try VaultFixture(); defer { f.remove() }
        f.keys.dropWrites = true
        #expect(throws: (any Error).self) { try f.vault.seal(Data([1]), account: f.a, now: now) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }

    @Test func failedAuthenticatedReopenDoesNotReturnReceiptOrRemoveRecoveryKey() throws {
        let f = try VaultFixture(); defer { f.remove() }
        f.keys.failReadNumber = 2
        #expect(throws: (any Error).self) { try f.vault.seal(Data([4, 5]), account: f.a, now: now) }
        let id = try #require(f.keys.values.keys.first)
        f.keys.failReadNumber = nil
        #expect(try SyncRecoveryVault(directory: f.root, keychain: f.keys)
            .restore(id, account: f.a, now: now) == Data([4, 5]))
    }

    @Test func interruptedCiphertextSynchronizationDoesNotReturnReceiptOrDestroySources() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let original = Data("exact pending packet".utf8)
        let interrupted = SyncRecoveryVault(directory: f.root, keychain: f.keys, maximumPayloadBytes: 100_000_000,
            synchronize: { _ in throw VaultSynchronizationFailure() })
        #expect(throws: (any Error).self) { try interrupted.seal(original, account: f.a, now: now) }
        let id = try #require(f.keys.values.keys.first)
        #expect(try f.vault.restore(id, account: f.a, now: now) == original)
    }

    @Test func oversizedCiphertextAndInvalidClockAreRejected() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let bounded = SyncRecoveryVault(directory: f.root, keychain: f.keys, maximumPayloadBytes: 2)
        let id = try bounded.seal(Data([1, 2]), account: f.a, now: now)
        #expect(try bounded.restore(id, account: f.a, now: now) == Data([1, 2]))
        #expect(throws: (any Error).self) {
            try bounded.restore(id, account: f.a, now: Date(timeIntervalSince1970: .infinity))
        }
        #expect(throws: (any Error).self) {
            try bounded.seal(Data(), account: f.a, now: Date(timeIntervalSince1970: .nan))
        }
        let url = f.root.appendingPathComponent(id.uuidString.lowercased() + ".vault")
        try Data(repeating: 0, count: 9000).write(to: url)
        #expect(throws: (any Error).self) { try bounded.restore(id, account: f.a, now: now) }
        #expect(f.keys.values.count == 1)
    }

    @Test func refusesSymlinkDirectoryAndOversizedPayload() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        let unsafe = SyncRecoveryVault(directory: alias, keychain: f.keys)
        #expect(throws: (any Error).self) { try unsafe.seal(Data([1]), account: f.a, now: now) }
        let bounded = SyncRecoveryVault(directory: f.root, keychain: f.keys, maximumPayloadBytes: 2)
        #expect(throws: (any Error).self) { try bounded.seal(Data([1, 2, 3]), account: f.a, now: now) }
        #expect(f.keys.values.isEmpty)
    }

    @Test func purgeDoesNotTrustForgedExpiryOrDeleteBeforeAuthenticatingEntireInventory() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let a = try f.vault.seal(Data([1]), account: f.a, now: now)
        let b = try f.vault.seal(Data([2]), account: f.b, now: now)
        #expect(throws: (any Error).self) {
            try f.vault.purgeExpired(account: f.a, now: now.addingTimeInterval(2_592_000))
        }
        #expect(try f.vault.restore(a, account: f.a, now: now) == Data([1]))
        #expect(try f.vault.restore(b, account: f.b, now: now) == Data([2]))
        let url = f.root.appendingPathComponent(a.uuidString.lowercased() + ".vault")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encoded = try #require(envelope["metadata"] as? String)
        let bytes = try #require(Data(base64Encoded: encoded))
        var metadata = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        metadata["createdAt"] = now.timeIntervalSince1970 - 2_592_000
        metadata["expiresAt"] = now.timeIntervalSince1970
        envelope["metadata"] = try JSONSerialization.data(withJSONObject: metadata).base64EncodedString()
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.a, now: now) }
        #expect(f.keys.values.count == 2)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func renamedVaultAndSymlinkOrHardlinkCiphertextAreRejected() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let id = try f.vault.seal(Data([1, 2]), account: f.a, now: now)
        let url = f.root.appendingPathComponent(id.uuidString.lowercased() + ".vault")
        let other = UUID()
        let alternate = f.root.appendingPathComponent(other.uuidString.lowercased() + ".vault")
        try FileManager.default.copyItem(at: url, to: alternate)
        f.keys.values[other] = f.keys.values[id]
        #expect(throws: (any Error).self) { try f.vault.restore(other, account: f.a, now: now) }
        try FileManager.default.removeItem(at: alternate)
        try FileManager.default.linkItem(at: url, to: alternate)
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now) }
        try FileManager.default.removeItem(at: alternate)
        try FileManager.default.moveItem(at: url, to: alternate)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: alternate)
        #expect(throws: (any Error).self) { try f.vault.restore(id, account: f.a, now: now) }
    }

    @Test func interruptedPurgeRetriesKeyRemovalAndTerminalIntentCleanup() throws {
        for deleteBeforeFailure in [false, true] {
            let f = try VaultFixture(); defer { f.remove() }
            let id = try f.vault.seal(Data([1, 2]), account: f.a, now: now)
            f.keys.failRemoval = true
            f.keys.deleteBeforeRemovalFailure = deleteBeforeFailure
            let expiry = now.addingTimeInterval(2_592_000)
            #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.a, now: expiry) }
            #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(id.uuidString.lowercased() + ".vault").path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).count == 1)
            f.keys.failRemoval = false
            let reopened = SyncRecoveryVault(directory: f.root, keychain: f.keys)
            #expect(try reopened.purgeExpired(account: f.a, now: expiry) == [id])
            #expect(f.keys.values.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
        }
    }

    @Test func purgeIntentCannotCrossAccountOrBypassRemainingCiphertextOrTampering() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let id = try f.vault.seal(Data([1, 2]), account: f.a, now: now)
        let ciphertextURL = f.root.appendingPathComponent(id.uuidString.lowercased() + ".vault")
        let originalCiphertext = try Data(contentsOf: ciphertextURL)
        f.keys.failRemoval = true; f.keys.deleteBeforeRemovalFailure = true
        let expiry = now.addingTimeInterval(2_592_000)
        #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.a, now: expiry) }
        f.keys.failRemoval = false
        let urls = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
        let intentURL = try #require(urls.first)
        let originalIntent = try Data(contentsOf: intentURL)
        #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.b, now: expiry) }
        try originalCiphertext.write(to: ciphertextURL)
        #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.a, now: expiry) }
        #expect(try Data(contentsOf: ciphertextURL) == originalCiphertext)
        try FileManager.default.removeItem(at: ciphertextURL)
        var changed = originalIntent; changed[changed.count / 2] ^= 1
        try changed.write(to: intentURL)
        #expect(throws: (any Error).self) { try f.vault.purgeExpired(account: f.a, now: expiry) }
        #expect(FileManager.default.fileExists(atPath: intentURL.path))
        try originalIntent.write(to: intentURL)
        #expect(try f.vault.purgeExpired(account: f.a, now: expiry) == [id])
    }

    @Test func retryResynchronizesPreparedIntentBeforeDeletingOriginalCiphertext() throws {
        for point in [PurgeBarrierFault.Point.preparedFile, .preparedDirectory] {
            let f = try VaultFixture(); defer { f.remove() }
            let id = try f.vault.seal(Data([1, 2, 3]), account: f.a, now: now)
            let fault = PurgeBarrierFault(root: f.root, id: id, point: point)
            let expiry = now.addingTimeInterval(2_592_000)
            for _ in 0..<2 {
                let reopened = SyncRecoveryVault(directory: f.root, keychain: f.keys, maximumPayloadBytes: 100_000_000,
                    synchronize: { try fault.synchronize($0) })
                #expect(throws: VaultSynchronizationFailure.self) { try reopened.purgeExpired(account: f.a, now: expiry) }
                #expect(FileManager.default.fileExists(atPath: fault.ciphertext.path))
                #expect(f.keys.values[id] != nil)
            }
            #expect(try f.vault.restore(id, account: f.a, now: now) == Data([1, 2, 3]))
            #expect(try f.vault.purgeExpired(account: f.a, now: expiry) == [id])
            #expect(f.keys.values.isEmpty)
        }
    }

    @Test func retryResynchronizesRenamedTerminalIntentBeforeRemovingKey() throws {
        let f = try VaultFixture(); defer { f.remove() }
        let id = try f.vault.seal(Data([1, 2, 3]), account: f.a, now: now)
        let fault = PurgeBarrierFault(root: f.root, id: id, point: .terminalDirectory)
        let expiry = now.addingTimeInterval(2_592_000)
        for _ in 0..<2 {
            let reopened = SyncRecoveryVault(directory: f.root, keychain: f.keys, maximumPayloadBytes: 100_000_000,
                synchronize: { try fault.synchronize($0) })
            #expect(throws: VaultSynchronizationFailure.self) { try reopened.purgeExpired(account: f.a, now: expiry) }
            #expect(!FileManager.default.fileExists(atPath: fault.ciphertext.path))
            #expect(f.keys.values[id] != nil)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fault.intent)) as? [String: Any])
            #expect(object["phase"] as? String == "ciphertextRemoved")
        }
        #expect(try f.vault.purgeExpired(account: f.a, now: expiry) == [id])
        #expect(f.keys.values.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }
}

private struct PurgeBarrierFault: Sendable {
    enum Point: Sendable { case preparedFile, preparedDirectory, terminalDirectory }
    let root: URL
    let id: UUID
    let point: Point
    var ciphertext: URL { root.appendingPathComponent(id.uuidString.lowercased() + ".vault") }
    var intent: URL { root.appendingPathComponent(id.uuidString.lowercased() + ".purge") }

    func synchronize(_ fd: Int32) throws {
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0 else { throw VaultSynchronizationFailure() }
        if let bytes = try? Data(contentsOf: intent),
           let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            let phase = object["phase"] as? String
            let isDirectory = opened.st_mode & S_IFMT == S_IFDIR
            let isIntent = lstat(intent.path, &named) == 0
                && named.st_ino == opened.st_ino && named.st_dev == opened.st_dev
            switch point {
            case .preparedFile where phase == "prepared" && isIntent:
                throw VaultSynchronizationFailure()
            case .preparedDirectory where phase == "prepared" && isDirectory
                && FileManager.default.fileExists(atPath: ciphertext.path):
                throw VaultSynchronizationFailure()
            case .terminalDirectory where phase == "ciphertextRemoved" && isDirectory:
                throw VaultSynchronizationFailure()
            default: break
            }
        }
        guard fsync(fd) == 0 else { throw VaultSynchronizationFailure() }
    }
}

// Each fixture is private to a test; vault operations serialize access.
private final class MemoryVaultKeys: SyncRecoveryVaultKeychain, @unchecked Sendable {
    var values: [UUID: Data] = [:]
    var dropWrites = false
    var failReadNumber: Int?
    var failRemoval = false
    var deleteBeforeRemovalFailure = false
    private var readCount = 0
    func insert(_ key: Data, for vaultID: UUID) throws { if !dropWrites { values[vaultID] = key } }
    func key(for vaultID: UUID) throws -> Data? {
        readCount += 1
        if failReadNumber == readCount { throw SyncRecoveryVaultError.unavailable }
        return values[vaultID]
    }
    func remove(for vaultID: UUID) throws {
        if failRemoval {
            if deleteBeforeRemovalFailure { values.removeValue(forKey: vaultID) }
            throw SyncRecoveryVaultError.unavailable
        }
        values.removeValue(forKey: vaultID)
    }
}

private struct VaultSynchronizationFailure: Error {}

private struct VaultFixture {
    let root: URL
    let keys = MemoryVaultKeys()
    let a = try! SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "A")
    let b = try! SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "B")
    var vault: SyncRecoveryVault { .init(directory: root, keychain: keys) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
