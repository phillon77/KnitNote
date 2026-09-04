import CryptoKit
import Darwin
import Dispatch
import Foundation
import Testing

@testable import KnitNote

@Suite(.serialized) struct CloudAssetFileStoreTests {
    @Test(.timeLimit(.minutes(1)))
    func cooperatingProcessesSerializeOneAccount() throws {
        let fixture = try CloudAssetFileStoreFixture()
        let account = "shared-account"
        let sharedStore = try fixture.store(account: account)
        let secondSharedStore = try fixture.store(account: account)
        let isolatedStore = try fixture.store(account: "other-account")
        try sharedStore.withAccountLock { _ in }

        let lockURL = fixture.accountURL(account).appendingPathComponent(".lock")
        let releaseURL = fixture.root.appendingPathComponent("release-child-lock")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, os, sys, time
            handle = open(sys.argv[1], "r+b", buffering=0)
            fcntl.lockf(handle, fcntl.LOCK_EX)
            sys.stdout.write("READY")
            sys.stdout.flush()
            while not os.path.exists(sys.argv[2]):
                time.sleep(0.01)
            """,
            lockURL.path,
            releaseURL.path,
        ]
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("READY".utf8))

        try isolatedStore.withAccountLock { _ in
            #expect(!FileManager.default.fileExists(atPath: releaseURL.path))
        }

        Task.detached {
            try await Task.sleep(for: .milliseconds(250))
            try Data().write(to: releaseURL)
        }
        try secondSharedStore.withAccountLock { _ in
            #expect(FileManager.default.fileExists(atPath: releaseURL.path))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sameProcessEquivalentRootAliasesSerializeOneAccount() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-asset-equivalent-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false
        )
        let directRoot = container.appendingPathComponent("SharedRoot", isDirectory: true)
        let equivalentRoot = container.appendingPathComponent("sharedroot", isDirectory: true)
        try FileManager.default.createDirectory(at: directRoot, withIntermediateDirectories: false)
        var directStatus = stat()
        var aliasStatus = stat()
        try #require(directRoot.path.withCString { Darwin.lstat($0, &directStatus) } == 0)
        try #require(equivalentRoot.path.withCString { Darwin.lstat($0, &aliasStatus) } == 0)
        try #require(directStatus.st_dev == aliasStatus.st_dev)
        try #require(directStatus.st_ino == aliasStatus.st_ino)
        let directStore = try CloudAssetAccountFileStore(
            rootURL: directRoot,
            accountIdentifier: "same-process",
            maximumAssetBytes: 1_024
        )
        let aliasStore = try CloudAssetAccountFileStore(
            rootURL: equivalentRoot,
            accountIdentifier: "same-process",
            maximumAssetBytes: 1_024
        )
        try directStore.withAccountLock { _ in }

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { firstFinished.signal() }
            try? directStore.withAccountLock { _ in
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        #expect(firstEntered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            defer { secondFinished.signal() }
            _ = try? aliasStore.withAccountLock { _ in secondEntered.signal() }
        }

        let enteredBeforeRelease = secondEntered.wait(timeout: .now() + 0.2)
        releaseFirst.signal()
        #expect(enteredBeforeRelease == .timedOut)
        #expect(secondEntered.wait(timeout: .now() + 2) == .success)
        #expect(firstFinished.wait(timeout: .now() + 2) == .success)
        #expect(secondFinished.wait(timeout: .now() + 2) == .success)
    }

    @Test func nestedServiceRootIsCreatedBelowTrustedTempContainer() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-asset-nested-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let nestedRoot = container
            .appendingPathComponent("level-one", isDirectory: true)
            .appendingPathComponent("level-two", isDirectory: true)
            .appendingPathComponent("CloudAssetStaging", isDirectory: true)
        let store = try CloudAssetAccountFileStore(
            rootURL: nestedRoot,
            accountIdentifier: "nested-account",
            maximumAssetBytes: 1_024
        )

        try store.withAccountLock { _ in }

        var status = stat()
        #expect(nestedRoot.path.withCString { Darwin.lstat($0, &status) } == 0)
        #expect((status.st_mode & S_IFMT) == S_IFDIR)
    }

    @Test func serviceRootAncestorSymlinkFailsClosed() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-asset-symlink-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let target = container.appendingPathComponent("target", isDirectory: true)
        let alias = container.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let unsafeRoot = alias
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("CloudAssetStaging", isDirectory: true)
        let store = try CloudAssetAccountFileStore(
            rootURL: unsafeRoot,
            accountIdentifier: "symlink-ancestor",
            maximumAssetBytes: 1_024
        )

        #expect(throws: CloudAssetFileStoreError.unsafeFile) {
            _ = try store.withAccountLock { _ in }
        }
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent("nested").path
        ))
    }

    @Test func listOwnedPropagatesDirectoryEnumerationError() throws {
        let fixture = try CloudAssetFileStoreFixture()
        let store = try fixture.store(
            account: "readdir-error",
            directoryEntryReader: { _ in
                errno = EIO
                return nil
            }
        )

        _ = try store.withAccountLock { directories in
            #expect(throws: CloudAssetFileStoreError.unavailable) {
                _ = try store.listOwned(in: directories.uploads)
            }
        }
    }

    @Test func accountTokensAreOpaqueAndIsolated() throws {
        let fixture = try CloudAssetFileStoreFixture()
        let firstAccount = "person@example.com/../../private"
        let secondAccount = "person@example.com"
        let first = try fixture.store(account: firstAccount)
        let second = try fixture.store(account: secondAccount)
        let firstBytes = Data("first account".utf8)
        let secondBytes = Data("second account".utf8)

        try first.withAccountLock { directories in
            try first.publishNoClobber(firstBytes, named: "same.asset", in: directories.uploads)
        }
        try second.withAccountLock { directories in
            try second.publishNoClobber(secondBytes, named: "same.asset", in: directories.uploads)
        }

        let firstRead = try first.withAccountLock { directories in
            try first.readOwned(
                named: "same.asset",
                in: directories.uploads,
                expectedByteCount: Int64(firstBytes.count),
                expectedSHA256: Data(SHA256.hash(data: firstBytes))
            )
        }
        let secondRead = try second.withAccountLock { directories in
            try second.readOwned(
                named: "same.asset",
                in: directories.uploads,
                expectedByteCount: Int64(secondBytes.count),
                expectedSHA256: Data(SHA256.hash(data: secondBytes))
            )
        }
        #expect(firstRead == firstBytes)
        #expect(secondRead == secondBytes)

        let accountNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.appendingPathComponent("Accounts").path
        )
        #expect(Set(accountNames) == Set([
            fixture.accountToken(firstAccount),
            fixture.accountToken(secondAccount),
        ]))
        #expect(accountNames.allSatisfy { !$0.contains("person") && !$0.contains("/") })
    }

    @Test(.timeLimit(.minutes(1)))
    func unsafeObjectsAndTraversalFailClosed() throws {
        let symlinkFixture = try CloudAssetFileStoreFixture()
        let symlinkStore = try symlinkFixture.store(account: "symlink")
        try symlinkStore.withAccountLock { directories in
            let target = symlinkFixture.root.appendingPathComponent("target")
            try Data("bytes".utf8).write(to: target)
            let link = symlinkFixture.uploadsURL("symlink").appendingPathComponent("link.asset")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: (any Error).self) {
                _ = try symlinkStore.readOwned(
                    named: "link.asset",
                    in: directories.uploads,
                    expectedByteCount: 5,
                    expectedSHA256: Data(SHA256.hash(data: Data("bytes".utf8)))
                )
            }
        }

        let hardLinkFixture = try CloudAssetFileStoreFixture()
        let hardLinkStore = try hardLinkFixture.store(account: "hard-link")
        try hardLinkStore.withAccountLock { directories in
            let original = hardLinkFixture.uploadsURL("hard-link").appendingPathComponent("one.asset")
            let alias = hardLinkFixture.uploadsURL("hard-link").appendingPathComponent("two.asset")
            try Data("bytes".utf8).write(to: original)
            #expect(original.path.withCString { source in
                alias.path.withCString { Darwin.link(source, $0) }
            } == 0)
            #expect(throws: (any Error).self) {
                _ = try hardLinkStore.listOwned(in: directories.uploads)
            }
        }

        let fifoFixture = try CloudAssetFileStoreFixture()
        let fifoStore = try fifoFixture.store(account: "fifo")
        try fifoStore.withAccountLock { directories in
            let fifo = fifoFixture.uploadsURL("fifo").appendingPathComponent("pipe.asset")
            #expect(fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) } == 0)
            #expect(throws: (any Error).self) {
                _ = try fifoStore.readOwned(
                    named: "pipe.asset",
                    in: directories.uploads,
                    expectedByteCount: 0,
                    expectedSHA256: Data(SHA256.hash(data: Data()))
                )
            }
        }

        let traversalFixture = try CloudAssetFileStoreFixture()
        let traversalStore = try traversalFixture.store(account: "traversal")
        _ = try traversalStore.withAccountLock { directories in
            #expect(throws: (any Error).self) {
                _ = try traversalStore.readOwned(
                    named: "../secret.asset",
                    in: directories.uploads,
                    expectedByteCount: 0,
                    expectedSHA256: Data(SHA256.hash(data: Data()))
                )
            }
        }

        let lockFixture = try CloudAssetFileStoreFixture()
        try lockFixture.seedAccountDirectories(account: "bad-lock")
        try FileManager.default.createDirectory(
            at: lockFixture.accountURL("bad-lock").appendingPathComponent(".lock"),
            withIntermediateDirectories: false
        )
        #expect(throws: (any Error).self) {
            _ = try lockFixture.store(account: "bad-lock").withAccountLock { _ in }
        }

        let ownerFixture = try CloudAssetFileStoreFixture()
        let ownerStore = try ownerFixture.store(
            account: "wrong-owner",
            expectedLockOwnerID: Darwin.geteuid() &+ 1
        )
        #expect(throws: (any Error).self) {
            _ = try ownerStore.withAccountLock { _ in }
        }
    }

    @Test func declaredReadUsesOnlyOneOverrunByte() throws {
        let fixture = try CloudAssetFileStoreFixture()
        let source = fixture.root.appendingPathComponent("growing.asset")
        let original = Data("safe".utf8)
        try original.write(to: source)
        let counters = SyncRegularFileReaderIOCounters()
        let reader = SyncRegularFileReader(
            beforeRead: {
                let handle = try FileHandle(forWritingTo: source)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x41, count: 1_000_000))
                try handle.close()
            },
            ioCounters: counters
        )
        let store = try fixture.store(account: "growth", externalReader: reader)

        #expect(throws: (any Error).self) {
            _ = try store.readExternal(
                source,
                expectedByteCount: Int64(original.count),
                expectedSHA256: Data(SHA256.hash(data: original))
            )
        }
        #expect(counters.bytesRead == original.count + 1)
    }

    @Test func accountTreeReplacementBeforeReturnFailsClosed() throws {
        let fixture = try CloudAssetFileStoreFixture()
        let account = "replace-account"
        try fixture.store(account: account).withAccountLock { _ in }
        let originalAccountURL = fixture.accountURL(account)
        let displacedURL = originalAccountURL
            .deletingLastPathComponent()
            .appendingPathComponent("displaced-(UUID().uuidString)")
        let replacingStore = try fixture.store(account: account, beforeReturn: {
            try FileManager.default.moveItem(at: originalAccountURL, to: displacedURL)
            try FileManager.default.createDirectory(
                at: originalAccountURL,
                withIntermediateDirectories: false
            )
            for name in ["Uploads", "Installed", "Quarantine"] {
                try FileManager.default.createDirectory(
                    at: originalAccountURL.appendingPathComponent(name),
                    withIntermediateDirectories: false
                )
            }
        })

        #expect(throws: (any Error).self) {
            _ = try replacingStore.withAccountLock { _ in "must not return" }
        }
    }
}

private final class CloudAssetFileStoreFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cloud-asset-file-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func store(
        account: String,
        externalReader: any SyncRegularFileReading = SyncRegularFileReader(),
        beforeReturn: (@Sendable () throws -> Void)? = nil,
        expectedLockOwnerID: uid_t = Darwin.geteuid(),
        directoryEntryReader: @escaping (
            UnsafeMutablePointer<DIR>?
        ) -> UnsafeMutablePointer<dirent>? = Darwin.readdir
    ) throws -> CloudAssetAccountFileStore {
        try CloudAssetAccountFileStore(
            rootURL: root,
            accountIdentifier: account,
            maximumAssetBytes: 1_024,
            externalReader: externalReader,
            beforeReturn: beforeReturn,
            expectedLockOwnerID: expectedLockOwnerID,
            directoryEntryReader: directoryEntryReader
        )
    }

    func accountToken(_ account: String) -> String {
        Data(SHA256.hash(data: Data(account.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    func accountURL(_ account: String) -> URL {
        root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(accountToken(account), isDirectory: true)
    }

    func uploadsURL(_ account: String) -> URL {
        accountURL(account).appendingPathComponent("Uploads", isDirectory: true)
    }

    func seedAccountDirectories(account: String) throws {
        let accountURL = accountURL(account)
        try FileManager.default.createDirectory(at: accountURL, withIntermediateDirectories: true)
        for name in ["Uploads", "Installed", "Quarantine"] {
            try FileManager.default.createDirectory(
                at: accountURL.appendingPathComponent(name),
                withIntermediateDirectories: false
            )
        }
    }
}
