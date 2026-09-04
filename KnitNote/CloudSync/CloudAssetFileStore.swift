import CryptoKit
import Darwin
import Foundation

enum CloudAssetFileStoreError: Error, Equatable {
    case invalidAccount
    case unsafeFile
    case tooLarge
    case contentMismatch
    case alreadyExists
    case unavailable
}

struct CloudAssetAccountDirectories {
    let account: Int32
    let uploads: Int32
    let installed: Int32
    let quarantine: Int32
}

struct CloudAssetOwnedFileBinding: Equatable, Sendable {
    let name: String
    let value: Data
}

enum CloudAssetAtomicReplacementBoundary: Hashable, Sendable {
    case replacementTemporaryBeforeRename
    case replacementBeforeDirectorySync
    case rollbackBeforeMutation
    case rollbackBeforeDirectorySync
    case recoveryTemporaryCleanupBeforeDirectorySync
    case transactionCleanupBeforeUnlink
    case transactionCleanupBeforeDirectorySync
}

/// Descriptor-scoped filesystem operations for one CloudKit account.
/// Directory descriptors are valid only for the duration of `withAccountLock`.
final class CloudAssetAccountFileStore: @unchecked Sendable {
    typealias DirectoryEntryReader = (
        UnsafeMutablePointer<DIR>?
    ) -> UnsafeMutablePointer<dirent>?

    private static let lockName = ".lock"
    private static let processLockRegistry = NSLock()
    private nonisolated(unsafe) static var processLocks: [Identity: ProcessLockEntry] = [:]

    private let rootURL: URL
    private let accountToken: String
    private let maximumAssetBytes: Int
    private let externalReader: any SyncRegularFileReading
    private let beforeReturn: (@Sendable () throws -> Void)?
    private let expectedLockOwnerID: uid_t
    private let beforeProcessLockAttempt: (@Sendable () -> Void)?
    private let afterLockDescriptorClose: (@Sendable () -> Void)?
    private let beforeAtomicReplacementDirectorySync: @Sendable () throws -> Void
    private let atomicReplacementFault: @Sendable (
        CloudAssetAtomicReplacementBoundary
    ) throws -> Void
    private let directoryEntryReader: DirectoryEntryReader
    private let activeDescriptorsLock = NSLock()
    private var activeDescriptors: Set<Int32> = []

    var stableAccountBinding: String { accountToken }

    init(
        rootURL: URL,
        accountIdentifier: String,
        maximumAssetBytes: Int = SyncPublicationFileLimits.maximumAttachmentBytes,
        externalReader: any SyncRegularFileReading = SyncRegularFileReader(),
        beforeReturn: (@Sendable () throws -> Void)? = nil,
        expectedLockOwnerID: uid_t = Darwin.geteuid(),
        beforeProcessLockAttempt: (@Sendable () -> Void)? = nil,
        afterLockDescriptorClose: (@Sendable () -> Void)? = nil,
        beforeAtomicReplacementDirectorySync: @escaping @Sendable () throws -> Void = {},
        atomicReplacementFault: @escaping @Sendable (
            CloudAssetAtomicReplacementBoundary
        ) throws -> Void = { _ in },
        directoryEntryReader: @escaping DirectoryEntryReader = Darwin.readdir
    ) throws {
        guard !accountIdentifier.isEmpty else { throw CloudAssetFileStoreError.invalidAccount }
        guard maximumAssetBytes >= 0 else { throw CloudAssetFileStoreError.tooLarge }
        self.rootURL = rootURL.standardizedFileURL
        accountToken = Self.hex(Data(SHA256.hash(data: Data(accountIdentifier.utf8))))
        self.maximumAssetBytes = maximumAssetBytes
        self.externalReader = externalReader
        self.beforeReturn = beforeReturn
        self.expectedLockOwnerID = expectedLockOwnerID
        self.beforeProcessLockAttempt = beforeProcessLockAttempt
        self.afterLockDescriptorClose = afterLockDescriptorClose
        self.beforeAtomicReplacementDirectorySync = beforeAtomicReplacementDirectorySync
        self.atomicReplacementFault = atomicReplacementFault
        self.directoryEntryReader = directoryEntryReader
    }

    func withAccountLock<T>(_ body: (CloudAssetAccountDirectories) throws -> T) throws -> T {
        let tree = try openTree()
        defer { tree.close() }
        try validateTree(tree)
        let accountIdentity = try Self.directoryIdentity(tree.account)
        let processLock = Self.retainProcessLock(for: accountIdentity)
        beforeProcessLockAttempt?()
        processLock.lock.lock()
        defer {
            processLock.lock.unlock()
            Self.releaseProcessLock(processLock, for: accountIdentity)
        }

        let lockDescriptor = try openOrCreateLock(in: tree.account)
        defer {
            Darwin.close(lockDescriptor)
            afterLockDescriptorClose?()
        }
        try validateTree(tree)
        try validateLock(lockDescriptor, in: tree.account)

        try Self.setLock(lockDescriptor, type: Int16(F_WRLCK))
        try validateTree(tree)
        try validateLock(lockDescriptor, in: tree.account)

        let directories = CloudAssetAccountDirectories(
            account: tree.account,
            uploads: tree.uploads,
            installed: tree.installed,
            quarantine: tree.quarantine
        )
        register(directories)
        defer { unregister(directories) }
        let result: Result<T, Error>
        do { result = .success(try body(directories)) }
        catch { result = .failure(error) }
        try beforeReturn?()
        try validateTree(tree)
        try validateLock(lockDescriptor, in: tree.account)
        return try result.get()
    }

    func readExternal(
        _ url: URL,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws -> Data {
        try validateExpectation(byteCount: expectedByteCount, sha256: expectedSHA256)
        do {
            return try externalReader.read(
                url,
                maximumBytes: maximumAssetBytes,
                expected: .init(byteCount: expectedByteCount, sha256: expectedSHA256)
            ).data
        } catch let error as SyncRegularFileReadError {
            throw Self.map(error)
        }
    }

    /// Reads one external descriptor with a caller-selected bound and returns
    /// the observed identity and digest. Download staging uses this to classify
    /// a mismatch without reopening the external pathname for quarantine.
    func readExternalObserved(
        _ url: URL,
        declaredByteCount: Int64
    ) throws -> SyncRegularFileObservation {
        guard declaredByteCount >= 0,
              declaredByteCount <= Int64(maximumAssetBytes)
        else {
            throw CloudAssetFileStoreError.tooLarge
        }
        do {
            return try externalReader.observe(
                url,
                declaredByteCount: declaredByteCount,
                maximumBytes: maximumAssetBytes
            )
        } catch let error as SyncRegularFileReadError {
            throw Self.map(error)
        }
    }

    func readOwned(
        named name: String,
        in directory: Int32,
        expectedByteCount: Int64,
        expectedSHA256: Data,
        expectedBinding: CloudAssetOwnedFileBinding? = nil
    ) throws -> Data {
        try requireActive(directory)
        try Self.validateName(name)
        try validateExpectation(byteCount: expectedByteCount, sha256: expectedSHA256)
        let descriptor = name.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ELOOP { throw CloudAssetFileStoreError.unsafeFile }
            throw errno == ENOENT
                ? CloudAssetFileStoreError.unavailable
                : CloudAssetFileStoreError.unsafeFile
        }
        defer { Darwin.close(descriptor) }
        try validateOwnedFile(descriptor, named: name, in: directory)
        let data = try readDescriptor(
            descriptor,
            expectedByteCount: expectedByteCount,
            expectedSHA256: expectedSHA256
        )
        if let expectedBinding {
            try validateExtendedAttribute(expectedBinding, descriptor: descriptor)
        }
        try validateOwnedFile(descriptor, named: name, in: directory)
        return data
    }

    /// Reads service-owned metadata when its checksum and exact byte count are
    /// stored inside that metadata rather than known by the caller.
    func readOwned(
        named name: String,
        in directory: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        try requireActive(directory)
        try Self.validateName(name)
        guard maximumByteCount >= 0 else {
            throw CloudAssetFileStoreError.tooLarge
        }
        let descriptor = name.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ELOOP { throw CloudAssetFileStoreError.unsafeFile }
            throw errno == ENOENT
                ? CloudAssetFileStoreError.unavailable
                : CloudAssetFileStoreError.unsafeFile
        }
        defer { Darwin.close(descriptor) }
        try validateOwnedFile(descriptor, named: name, in: directory)
        let data = try readDescriptor(descriptor, maximumByteCount: maximumByteCount)
        try validateOwnedFile(descriptor, named: name, in: directory)
        return data
    }

    func publishNoClobber(
        _ data: Data,
        named name: String,
        in directory: Int32,
        binding: CloudAssetOwnedFileBinding? = nil,
        afterTemporaryFileSync: @Sendable () throws -> Void = {}
    ) throws {
        try requireActive(directory)
        try Self.validateName(name)
        try validatePayload(data)
        if try destinationIdentityIfPresent(named: name, in: directory) != nil {
            throw CloudAssetFileStoreError.alreadyExists
        }
        let temporary = ".tmp-\(UUID().uuidString.lowercased())"
        let descriptor = try createTemporary(named: temporary, in: directory)
        defer { Darwin.close(descriptor) }
        var removeTemporary = true
        defer {
            if removeTemporary { _ = temporary.withCString { Darwin.unlinkat(directory, $0, 0) } }
        }
        try Self.writeAll(data, descriptor: descriptor)
        if let binding {
            try writeExtendedAttribute(binding, descriptor: descriptor)
        }
        guard Darwin.fsync(descriptor) == 0 else { throw CloudAssetFileStoreError.unavailable }
        let identity = try ownedIdentity(descriptor)
        try validatePath(named: temporary, in: directory, equals: identity)
        do {
            try afterTemporaryFileSync()
        } catch {
            // Fault injection models process death after durable temp creation.
            // Reconciliation owns cleanup on the next service start.
            removeTemporary = false
            throw error
        }
        let result = temporary.withCString { source in
            name.withCString { destination in
                Darwin.renameatx_np(
                    directory, source, directory, destination, UInt32(RENAME_EXCL)
                )
            }
        }
        if result != 0 {
            if errno == EEXIST { throw CloudAssetFileStoreError.alreadyExists }
            throw CloudAssetFileStoreError.unavailable
        }
        removeTemporary = false
        try validatePath(named: name, in: directory, equals: identity)
        try synchronize(directory)
    }

    func replaceAtomically(
        _ data: Data,
        named name: String,
        in directory: Int32,
        transactionDomain: String = "knitnote.cloud-asset.file-replacement.v1"
    ) throws {
        try requireActive(directory)
        try Self.validateName(name)
        try validatePayload(data)
        guard !transactionDomain.isEmpty else { throw CloudAssetFileStoreError.unsafeFile }
        try recoverAtomicReplacement(
            named: name,
            in: directory,
            transactionDomain: transactionDomain
        )

        let priorData: Data?
        if try ownedFileExists(named: name, in: directory) {
            priorData = try readOwned(
                named: name,
                in: directory,
                maximumByteCount: maximumAssetBytes
            )
        } else {
            priorData = nil
        }
        let transaction = AtomicReplacementTransaction(
            schemaVersion: 1,
            accountBinding: stableAccountBinding,
            destination: name,
            replacementTemporary: ".tmp-\(UUID().uuidString.lowercased())",
            priorData: priorData,
            replacementByteCount: Int64(data.count),
            replacementSHA256: Data(SHA256.hash(data: data))
        )
        let marker = try encodeTransaction(
            transaction,
            domain: transactionDomain
        )
        try publishTransactionMarker(
            marker,
            named: transactionMarkerName(for: name),
            in: directory
        )

        do {
            try publishReplacement(
                data,
                temporary: transaction.replacementTemporary,
                destination: name,
                destinationExisted: priorData != nil,
                directory: directory,
                injectBeforeRename: true
            )
            try beforeAtomicReplacementDirectorySync()
            try atomicReplacementFault(.replacementBeforeDirectorySync)
            try synchronize(directory)
            try cleanupTransactionMarker(
                named: name,
                in: directory,
                injectFaults: true
            )
        } catch {
            do {
                try restoreAtomicReplacement(
                    transaction,
                    markerData: marker,
                    in: directory,
                    transactionDomain: transactionDomain,
                    injectFaults: true
                )
            } catch {
                throw CloudAssetFileStoreError.unavailable
            }
            throw error
        }
    }

    func recoverAtomicReplacement(
        named name: String,
        in directory: Int32,
        transactionDomain: String
    ) throws {
        try requireActive(directory)
        try Self.validateName(name)
        guard !transactionDomain.isEmpty else { throw CloudAssetFileStoreError.unsafeFile }
        let markerName = transactionMarkerName(for: name)
        let markerTemporary = transactionMarkerTemporaryName(for: name)
        if !(try ownedFileExists(named: markerName, in: directory)) {
            if try removeIfPresent(named: markerTemporary, in: directory) {
                try synchronize(directory)
            }
            if try removeIfPresent(named: recoveryTemporaryName(for: name), in: directory) {
                try synchronize(directory)
            }
            return
        }
        let markerData = try readOwned(
            named: markerName,
            in: directory,
            maximumByteCount: maximumTransactionBytes
        )
        let transaction = try decodeTransaction(
            markerData,
            expectedDestination: name,
            domain: transactionDomain
        )
        try restoreAtomicReplacement(
            transaction,
            markerData: markerData,
            in: directory,
            transactionDomain: transactionDomain,
            injectFaults: true
        )
    }

    private struct AtomicReplacementTransaction: Codable, Equatable {
        let schemaVersion: Int
        let accountBinding: String
        let destination: String
        let replacementTemporary: String
        let priorData: Data?
        let replacementByteCount: Int64
        let replacementSHA256: Data
    }

    private struct AtomicReplacementEnvelope: Codable, Equatable {
        let checksum: Data
        let payload: Data
    }

    private var maximumTransactionBytes: Int {
        let overhead = 1_048_576
        guard maximumAssetBytes <= (Int.max - overhead) / 2 else { return Int.max }
        return maximumAssetBytes * 2 + overhead
    }

    private func transactionMarkerName(for destination: String) -> String {
        ".\(destination).replace-transaction"
    }

    private func transactionMarkerTemporaryName(for destination: String) -> String {
        ".\(destination).replace-transaction.tmp"
    }

    private func recoveryTemporaryName(for destination: String) -> String {
        ".\(destination).replace-recovery.tmp"
    }

    private func encodeTransaction(
        _ transaction: AtomicReplacementTransaction,
        domain: String
    ) throws -> Data {
        let payload = try Self.canonicalEncoder().encode(transaction)
        let envelope = AtomicReplacementEnvelope(
            checksum: Self.transactionChecksum(domain: domain, payload: payload),
            payload: payload
        )
        let data = try Self.canonicalEncoder().encode(envelope)
        guard data.count <= maximumTransactionBytes else {
            throw CloudAssetFileStoreError.tooLarge
        }
        return data
    }

    private func decodeTransaction(
        _ data: Data,
        expectedDestination: String,
        domain: String
    ) throws -> AtomicReplacementTransaction {
        do {
            let envelope = try JSONDecoder().decode(AtomicReplacementEnvelope.self, from: data)
            guard envelope.checksum.count == SHA256.byteCount,
                  envelope.checksum == Self.transactionChecksum(
                      domain: domain,
                      payload: envelope.payload
                  ),
                  try Self.canonicalEncoder().encode(envelope) == data
            else { throw CloudAssetFileStoreError.unsafeFile }
            let transaction = try JSONDecoder().decode(
                AtomicReplacementTransaction.self,
                from: envelope.payload
            )
            guard try Self.canonicalEncoder().encode(transaction) == envelope.payload,
                  transaction.schemaVersion == 1,
                  transaction.accountBinding == stableAccountBinding,
                  transaction.destination == expectedDestination,
                  transaction.replacementByteCount >= 0,
                  transaction.replacementByteCount <= Int64(maximumAssetBytes),
                  transaction.replacementSHA256.count == SHA256.byteCount,
                  Self.isReplacementTemporaryName(transaction.replacementTemporary),
                  transaction.priorData?.count ?? 0 <= maximumAssetBytes
            else { throw CloudAssetFileStoreError.unsafeFile }
            return transaction
        } catch let error as CloudAssetFileStoreError {
            throw error
        } catch {
            throw CloudAssetFileStoreError.unsafeFile
        }
    }

    private func publishTransactionMarker(
        _ data: Data,
        named marker: String,
        in directory: Int32
    ) throws {
        let markerTemporary = "\(marker).tmp"
        if try removeIfPresent(named: markerTemporary, in: directory) {
            try synchronize(directory)
        }
        let descriptor = try createTemporary(named: markerTemporary, in: directory)
        defer { Darwin.close(descriptor) }
        var removeTemporary = true
        defer {
            if removeTemporary {
                _ = markerTemporary.withCString { Darwin.unlinkat(directory, $0, 0) }
            }
        }
        try Self.writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw CloudAssetFileStoreError.unavailable }
        let identity = try ownedIdentity(descriptor)
        try validatePath(named: markerTemporary, in: directory, equals: identity)
        let published = markerTemporary.withCString { source in
            marker.withCString { destination in
                Darwin.renameatx_np(
                    directory, source, directory, destination, UInt32(RENAME_EXCL)
                )
            }
        }
        guard published == 0 else { throw CloudAssetFileStoreError.unavailable }
        removeTemporary = false
        try validatePath(named: marker, in: directory, equals: identity)
        try synchronize(directory)
    }

    private func publishReplacement(
        _ data: Data,
        temporary: String,
        destination: String,
        destinationExisted: Bool,
        directory: Int32,
        injectBeforeRename: Bool = false
    ) throws {
        if try removeIfPresent(named: temporary, in: directory) {
            try synchronize(directory)
        }
        let descriptor = try createTemporary(named: temporary, in: directory)
        defer { Darwin.close(descriptor) }
        var removeTemporary = true
        defer {
            if removeTemporary { _ = temporary.withCString { Darwin.unlinkat(directory, $0, 0) } }
        }
        try Self.writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw CloudAssetFileStoreError.unavailable }
        let identity = try ownedIdentity(descriptor)
        try validatePath(named: temporary, in: directory, equals: identity)
        if injectBeforeRename {
            try atomicReplacementFault(.replacementTemporaryBeforeRename)
        }
        let renamed = temporary.withCString { source in
            destination.withCString { target in
                destinationExisted
                    ? Darwin.renameat(directory, source, directory, target)
                    : Darwin.renameatx_np(
                        directory, source, directory, target, UInt32(RENAME_EXCL)
                    )
            }
        }
        guard renamed == 0 else { throw CloudAssetFileStoreError.unavailable }
        removeTemporary = false
        try validatePath(named: destination, in: directory, equals: identity)
    }

    private func restoreAtomicReplacement(
        _ transaction: AtomicReplacementTransaction,
        markerData: Data,
        in directory: Int32,
        transactionDomain: String,
        injectFaults: Bool
    ) throws {
        let markerName = transactionMarkerName(for: transaction.destination)
        if !(try ownedFileExists(named: markerName, in: directory)) {
            try publishTransactionMarker(markerData, named: markerName, in: directory)
        }
        if injectFaults { try atomicReplacementFault(.rollbackBeforeMutation) }

        if let priorData = transaction.priorData {
            try publishReplacement(
                priorData,
                temporary: recoveryTemporaryName(for: transaction.destination),
                destination: transaction.destination,
                destinationExisted: try ownedFileExists(
                    named: transaction.destination,
                    in: directory
                ),
                directory: directory
            )
        } else if try ownedFileExists(named: transaction.destination, in: directory) {
            _ = try readOwned(
                named: transaction.destination,
                in: directory,
                expectedByteCount: transaction.replacementByteCount,
                expectedSHA256: transaction.replacementSHA256
            )
            guard transaction.destination.withCString({ Darwin.unlinkat(directory, $0, 0) }) == 0
            else { throw CloudAssetFileStoreError.unavailable }
        }

        if injectFaults { try atomicReplacementFault(.rollbackBeforeDirectorySync) }
        try synchronize(directory)
        _ = try removeIfPresent(named: transaction.replacementTemporary, in: directory)
        _ = try removeIfPresent(named: recoveryTemporaryName(for: transaction.destination), in: directory)
        if injectFaults {
            try atomicReplacementFault(.recoveryTemporaryCleanupBeforeDirectorySync)
        }
        // Make removal of every recorded/support temporary durable while the
        // prepared marker still exists. A crash before the next phase can
        // therefore replay recovery without losing its authority record.
        try synchronize(directory)
        try cleanupTransactionMarker(
            named: transaction.destination,
            in: directory,
            injectFaults: injectFaults
        )
    }

    private func cleanupTransactionMarker(
        named destination: String,
        in directory: Int32,
        injectFaults: Bool
    ) throws {
        let marker = transactionMarkerName(for: destination)
        if injectFaults { try atomicReplacementFault(.transactionCleanupBeforeUnlink) }
        guard try removeIfPresent(named: marker, in: directory) else {
            throw CloudAssetFileStoreError.unavailable
        }
        if injectFaults {
            try atomicReplacementFault(.transactionCleanupBeforeDirectorySync)
        }
        try synchronize(directory)
    }

    private func removeIfPresent(named name: String, in directory: Int32) throws -> Bool {
        guard try ownedFileExists(named: name, in: directory) else { return false }
        guard name.withCString({ Darwin.unlinkat(directory, $0, 0) }) == 0 else {
            throw CloudAssetFileStoreError.unavailable
        }
        return true
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func transactionChecksum(domain: String, payload: Data) -> Data {
        var material = Data(domain.utf8)
        material.append(0)
        material.append(payload)
        return Data(SHA256.hash(data: material))
    }

    private static func isReplacementTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(".tmp-"), name.count == ".tmp-".count + 36 else { return false }
        let id = String(name.dropFirst(".tmp-".count))
        return UUID(uuidString: id) != nil && id == id.lowercased()
    }

    func removeOwned(named name: String, in directory: Int32) throws {
        try requireActive(directory)
        try Self.validateName(name)
        let descriptor = name.withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw CloudAssetFileStoreError.unsafeFile }
            throw CloudAssetFileStoreError.unavailable
        }
        defer { Darwin.close(descriptor) }
        try validateOwnedFile(descriptor, named: name, in: directory)
        guard name.withCString({ Darwin.unlinkat(directory, $0, 0) }) == 0 else {
            throw CloudAssetFileStoreError.unavailable
        }
        try synchronize(directory)
    }

    func listOwned(in directory: Int32) throws -> [String] {
        try requireActive(directory)
        let duplicate = Darwin.dup(directory)
        guard duplicate >= 0,
              Darwin.lseek(duplicate, 0, SEEK_SET) >= 0,
              let stream = Darwin.fdopendir(duplicate)
        else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw CloudAssetFileStoreError.unavailable
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = directoryEntryReader(stream) else {
                guard errno == 0 else { throw CloudAssetFileStoreError.unavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            try Self.validateName(name)
            let descriptor = name.withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw CloudAssetFileStoreError.unsafeFile }
            do {
                defer { Darwin.close(descriptor) }
                try validateOwnedFile(descriptor, named: name, in: directory)
            }
            names.append(name)
        }
        return names.sorted()
    }

    func ownedFileExists(named name: String, in directory: Int32) throws -> Bool {
        try requireActive(directory)
        try Self.validateName(name)
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw CloudAssetFileStoreError.unavailable
        }
        guard Self.isOwnedRegularFile(status, ownerID: Darwin.geteuid()) else {
            throw CloudAssetFileStoreError.unsafeFile
        }
        return true
    }

    func synchronize(_ directory: Int32) throws {
        try requireActive(directory)
        guard Darwin.fsync(directory) == 0 else { throw CloudAssetFileStoreError.unavailable }
    }

    private struct OpenTree {
        let rootPath: OpenDirectoryPath
        let accounts: Int32
        let account: Int32
        let uploads: Int32
        let installed: Int32
        let quarantine: Int32

        var root: Int32 { rootPath.root }

        func close() {
            Darwin.close(quarantine); Darwin.close(installed); Darwin.close(uploads)
            Darwin.close(account); Darwin.close(accounts); rootPath.close()
        }
    }

    private struct OpenDirectoryPath {
        let descriptors: [Int32]
        let childNames: [String]

        var root: Int32 { descriptors[descriptors.count - 1] }

        func validate() throws {
            for index in childNames.indices {
                try CloudAssetAccountFileStore.validateDirectory(
                    descriptors[index + 1],
                    named: childNames[index],
                    in: descriptors[index]
                )
            }
        }

        func close() {
            for descriptor in descriptors.reversed() { Darwin.close(descriptor) }
        }
    }

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private final class ProcessLockEntry: @unchecked Sendable {
        let lock = NSLock()
        var retainCount = 0
    }

    private func openTree() throws -> OpenTree {
        let rootPath = try Self.openRootPath(at: rootURL)
        var accounts: Int32 = -1, account: Int32 = -1, uploads: Int32 = -1
        var installed: Int32 = -1, quarantine: Int32 = -1
        var transferred = false
        defer {
            if !transferred {
                if quarantine >= 0 { Darwin.close(quarantine) }
                if installed >= 0 { Darwin.close(installed) }
                if uploads >= 0 { Darwin.close(uploads) }
                if account >= 0 { Darwin.close(account) }
                if accounts >= 0 { Darwin.close(accounts) }
                rootPath.close()
            }
        }
        accounts = try Self.openOrCreateDirectory(named: "Accounts", in: rootPath.root)
        account = try Self.openOrCreateDirectory(named: accountToken, in: accounts)
        uploads = try Self.openOrCreateDirectory(named: "Uploads", in: account)
        installed = try Self.openOrCreateDirectory(named: "Installed", in: account)
        quarantine = try Self.openOrCreateDirectory(named: "Quarantine", in: account)
        transferred = true
        return OpenTree(
            rootPath: rootPath, accounts: accounts, account: account,
            uploads: uploads, installed: installed, quarantine: quarantine
        )
    }

    private func validateTree(_ tree: OpenTree) throws {
        try tree.rootPath.validate()
        try Self.validateDirectory(tree.accounts, named: "Accounts", in: tree.root)
        try Self.validateDirectory(tree.account, named: accountToken, in: tree.accounts)
        try Self.validateDirectory(tree.uploads, named: "Uploads", in: tree.account)
        try Self.validateDirectory(tree.installed, named: "Installed", in: tree.account)
        try Self.validateDirectory(tree.quarantine, named: "Quarantine", in: tree.account)
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw CloudAssetFileStoreError.unsafeFile }
            throw CloudAssetFileStoreError.unavailable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0, isOwnedDirectory(status) else {
            Darwin.close(descriptor)
            throw CloudAssetFileStoreError.unsafeFile
        }
        return descriptor
    }

    private static func openRootPath(at rootURL: URL) throws -> OpenDirectoryPath {
        let trustedParent = try trustedParent(for: rootURL)
        let parentComponents = trustedParent.pathComponents
        let rootComponents = rootURL.pathComponents
        guard rootComponents.count > parentComponents.count,
              Array(rootComponents.prefix(parentComponents.count)) == parentComponents
        else {
            throw CloudAssetFileStoreError.unsafeFile
        }
        let childNames = Array(rootComponents.dropFirst(parentComponents.count))
        let parent = try openDirectory(at: trustedParent)
        var descriptors = [parent]
        do {
            for name in childNames {
                let child = try openOrCreateDirectory(named: name, in: descriptors.last!)
                do {
                    try validateDirectory(child, named: name, in: descriptors.last!)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                descriptors.append(child)
            }
            return OpenDirectoryPath(descriptors: descriptors, childNames: childNames)
        } catch {
            for descriptor in descriptors.reversed() { Darwin.close(descriptor) }
            throw error
        }
    }

    private static func trustedParent(for rootURL: URL) throws -> URL {
        let rootComponents = rootURL.pathComponents
        let candidates = [
            FileManager.default.temporaryDirectory.standardizedFileURL,
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL,
        ].filter { candidate in
            let components = candidate.pathComponents
            return rootComponents.count > components.count
                && Array(rootComponents.prefix(components.count)) == components
        }
        guard let parent = candidates.max(by: {
            $0.pathComponents.count < $1.pathComponents.count
        }) else {
            throw CloudAssetFileStoreError.unsafeFile
        }
        return parent
    }

    private static func openOrCreateDirectory(named name: String, in parent: Int32) throws -> Int32 {
        try validateName(name)
        var descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT {
            let result = name.withCString { Darwin.mkdirat(parent, $0, S_IRWXU) }
            if result != 0, errno != EEXIST { throw CloudAssetFileStoreError.unavailable }
            guard Darwin.fsync(parent) == 0 else { throw CloudAssetFileStoreError.unavailable }
            descriptor = name.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw CloudAssetFileStoreError.unsafeFile }
            throw CloudAssetFileStoreError.unavailable
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0, isOwnedDirectory(status) else {
            Darwin.close(descriptor)
            throw CloudAssetFileStoreError.unsafeFile
        }
        return descriptor
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        named name: String,
        in parent: Int32
    ) throws {
        var status = stat()
        guard name.withCString({ Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0,
              isOwnedDirectory(status),
              try directoryIdentity(descriptor) == Identity(device: status.st_dev, inode: status.st_ino)
        else { throw CloudAssetFileStoreError.unsafeFile }
    }

    private func openOrCreateLock(in account: Int32) throws -> Int32 {
        let descriptor = Self.lockName.withCString {
            Darwin.openat(
                account, $0,
                O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            var status = stat()
            if Self.lockName.withCString({
                Darwin.fstatat(account, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0 {
                throw CloudAssetFileStoreError.unsafeFile
            }
            throw CloudAssetFileStoreError.unavailable
        }
        do { try validateLockDescriptor(descriptor); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }

    private func validateLock(_ descriptor: Int32, in account: Int32) throws {
        try validateLockDescriptor(descriptor)
        let identity = try ownedIdentity(descriptor, expectedOwnerID: expectedLockOwnerID)
        try validatePath(
            named: Self.lockName,
            in: account,
            equals: identity,
            expectedOwnerID: expectedLockOwnerID
        )
    }

    private func validateLockDescriptor(_ descriptor: Int32) throws {
        _ = try ownedIdentity(descriptor, expectedOwnerID: expectedLockOwnerID)
    }

    private func validateOwnedFile(_ descriptor: Int32, named name: String, in directory: Int32) throws {
        try validatePath(named: name, in: directory, equals: try ownedIdentity(descriptor))
    }

    private func ownedIdentity(
        _ descriptor: Int32,
        expectedOwnerID: uid_t = Darwin.geteuid()
    ) throws -> Identity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              Self.isOwnedRegularFile(status, ownerID: expectedOwnerID)
        else { throw CloudAssetFileStoreError.unsafeFile }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    private func validatePath(
        named name: String,
        in directory: Int32,
        equals identity: Identity,
        expectedOwnerID: uid_t = Darwin.geteuid()
    ) throws {
        var status = stat()
        guard name.withCString({ Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0,
              Self.isOwnedRegularFile(status, ownerID: expectedOwnerID),
              identity == Identity(device: status.st_dev, inode: status.st_ino)
        else { throw CloudAssetFileStoreError.unsafeFile }
    }

    private func destinationIdentityIfPresent(named name: String, in directory: Int32) throws
        -> Identity?
    {
        var status = stat()
        let result = name.withCString { Darwin.fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw CloudAssetFileStoreError.unavailable
        }
        guard Self.isOwnedRegularFile(status, ownerID: Darwin.geteuid()) else {
            throw CloudAssetFileStoreError.unsafeFile
        }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    private func createTemporary(named name: String, in directory: Int32) throws -> Int32 {
        let descriptor = name.withCString {
            Darwin.openat(
                directory, $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw CloudAssetFileStoreError.unavailable }
        do { _ = try ownedIdentity(descriptor); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }

    private func readDescriptor(
        _ descriptor: Int32,
        expectedByteCount: Int64,
        expectedSHA256: Data
    ) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isOwnedRegularFile(before, ownerID: Darwin.geteuid()),
              before.st_size >= 0,
              Int64(before.st_size) == expectedByteCount
        else { throw CloudAssetFileStoreError.contentMismatch }
        let readLimit = Int(expectedByteCount)
        var data = Data()
        data.reserveCapacity(readLimit)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = readLimit - data.count
            let requestedCount = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requestedCount) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CloudAssetFileStoreError.unavailable }
            guard count > 0 else { break }
            guard count <= remaining else { throw CloudAssetFileStoreError.contentMismatch }
            data.append(buffer, count: count)
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.isOwnedRegularFile(after, ownerID: Darwin.geteuid()),
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(before.st_size),
              Data(hasher.finalize()) == expectedSHA256
        else { throw CloudAssetFileStoreError.contentMismatch }
        return data
    }

    private func readDescriptor(_ descriptor: Int32, maximumByteCount: Int) throws -> Data {
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.isOwnedRegularFile(before, ownerID: Darwin.geteuid()),
              before.st_size >= 0
        else { throw CloudAssetFileStoreError.unsafeFile }
        guard before.st_size <= maximumByteCount else { throw CloudAssetFileStoreError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = maximumByteCount - data.count
            let requestedCount = min(buffer.count, remaining + 1)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requestedCount)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CloudAssetFileStoreError.unavailable }
            guard count > 0 else { break }
            guard count <= remaining else { throw CloudAssetFileStoreError.tooLarge }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.isOwnedRegularFile(after, ownerID: Darwin.geteuid()),
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(before.st_size)
        else { throw CloudAssetFileStoreError.contentMismatch }
        return data
    }

    private func validateExpectation(byteCount: Int64, sha256: Data) throws {
        guard byteCount >= 0, byteCount <= Int64(maximumAssetBytes) else {
            throw CloudAssetFileStoreError.tooLarge
        }
        guard sha256.count == SHA256.byteCount else { throw CloudAssetFileStoreError.contentMismatch }
    }

    private func validatePayload(_ data: Data) throws {
        guard data.count <= maximumAssetBytes else { throw CloudAssetFileStoreError.tooLarge }
    }

    private func register(_ directories: CloudAssetAccountDirectories) {
        activeDescriptorsLock.withLock {
            activeDescriptors.formUnion([
                directories.account, directories.uploads,
                directories.installed, directories.quarantine,
            ])
        }
    }

    private func unregister(_ directories: CloudAssetAccountDirectories) {
        activeDescriptorsLock.withLock {
            activeDescriptors.subtract([
                directories.account, directories.uploads,
                directories.installed, directories.quarantine,
            ])
        }
    }

    private func requireActive(_ descriptor: Int32) throws {
        guard activeDescriptorsLock.withLock({ activeDescriptors.contains(descriptor) }) else {
            throw CloudAssetFileStoreError.unsafeFile
        }
    }

    private static func retainProcessLock(for identity: Identity) -> ProcessLockEntry {
        processLockRegistry.withLock {
            let entry = processLocks[identity] ?? ProcessLockEntry()
            entry.retainCount += 1
            processLocks[identity] = entry
            return entry
        }
    }

    private static func releaseProcessLock(_ entry: ProcessLockEntry, for identity: Identity) {
        processLockRegistry.withLock {
            guard processLocks[identity] === entry else { return }
            entry.retainCount -= 1
            if entry.retainCount == 0 {
                processLocks.removeValue(forKey: identity)
            }
        }
    }

    private static func setLock(_ descriptor: Int32, type: Int16) throws {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        while true {
            if Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 { return }
            if errno == EINTR { continue }
            throw CloudAssetFileStoreError.unavailable
        }
    }

    private static func directoryIdentity(_ descriptor: Int32) throws -> Identity {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0, isOwnedDirectory(status) else {
            throw CloudAssetFileStoreError.unsafeFile
        }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    private static func isOwnedDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR && status.st_uid == Darwin.geteuid()
    }

    private static func isOwnedRegularFile(_ status: stat, ownerID: uid_t) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG && status.st_uid == ownerID && status.st_nlink == 1
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.utf8.contains(0)
        else { throw CloudAssetFileStoreError.unsafeFile }
    }

    private func writeExtendedAttribute(
        _ binding: CloudAssetOwnedFileBinding,
        descriptor: Int32
    ) throws {
        guard !binding.name.isEmpty,
              !binding.name.contains("/"),
              binding.value.count == SHA256.byteCount
        else { throw CloudAssetFileStoreError.unsafeFile }
        let result = binding.value.withUnsafeBytes { bytes in
            binding.name.withCString { name in
                Darwin.fsetxattr(
                    descriptor,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard result == 0 else { throw CloudAssetFileStoreError.unavailable }
    }

    private func validateExtendedAttribute(
        _ binding: CloudAssetOwnedFileBinding,
        descriptor: Int32
    ) throws {
        guard !binding.name.isEmpty,
              !binding.name.contains("/"),
              binding.value.count == SHA256.byteCount
        else { throw CloudAssetFileStoreError.unsafeFile }
        let size = binding.name.withCString {
            Darwin.fgetxattr(descriptor, $0, nil, 0, 0, 0)
        }
        guard size == binding.value.count else {
            throw CloudAssetFileStoreError.contentMismatch
        }
        var observed = Data(count: binding.value.count)
        let read = observed.withUnsafeMutableBytes { bytes in
            binding.name.withCString { name in
                Darwin.fgetxattr(
                    descriptor,
                    name,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
        guard read == binding.value.count, observed == binding.value else {
            throw CloudAssetFileStoreError.contentMismatch
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CloudAssetFileStoreError.unavailable }
                offset += count
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func map(_ error: SyncRegularFileReadError) -> CloudAssetFileStoreError {
        switch error {
        case .unsafeFile: .unsafeFile
        case .tooLarge: .tooLarge
        case .expectationMismatch, .changed, .replaced: .contentMismatch
        case .unavailable: .unavailable
        }
    }
}
