import Foundation

public enum PatternInboxEnqueueCancellationResult: Equatable, Sendable {
    case cancelled
    case alreadyCancelled
    case committed
}

public final class PatternInboxEnqueueCancellationToken: @unchecked Sendable {
    private enum State {
        case active
        case cancelled
        case committed
    }

    private let lock = NSLock()
    private var state = State.active

    public init() {}

    public func requestCancellation() -> PatternInboxEnqueueCancellationResult {
        lock.withLock {
            switch state {
            case .active:
                state = .cancelled
                return .cancelled
            case .cancelled:
                return .alreadyCancelled
            case .committed:
                return .committed
            }
        }
    }

    public func checkCancellation() throws {
        try lock.withLock {
            if state == .cancelled {
                throw CancellationError()
            }
        }
    }

    public func performCommit<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try lock.withLock {
            guard state == .active else {
                throw CancellationError()
            }
            let value = try operation()
            state = .committed
            return value
        }
    }
}

public struct PatternInboxRecoveryReport: Sendable, Equatable {
    public var removedCandidateIDs: Set<UUID> = []
    public var quarantinedItemIDs: Set<UUID> = []
    public var cleanedCommittedIDs: Set<UUID> = []

    public init() {}
}

private enum PatternInboxManifestState: String, Codable, Sendable {
    case staged
    case committed
}

private struct PatternInboxManifest: Codable, Sendable {
    let version: Int
    let item: PatternInboxItem
    let state: PatternInboxManifestState
}

struct PatternInboxJournalVerification: Sendable {
    let item: PatternInboxItem
    let metadata: PatternFileMetadata?
    let isCommitted: Bool
}

public struct PatternInboxFileService: Sendable {
    public let root: URL
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private let moveItem: @Sendable (URL, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(root: URL) {
        self.init(
            root: root,
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            writeData: { try $0.write(to: $1, options: .atomic) }
        )
    }

    init(
        root: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.copyItem(at: $0, to: $1)
        },
        moveItem: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        },
        removeItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        writeData: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.root = root
        self.copyItem = copyItem
        self.moveItem = moveItem
        self.removeItem = removeItem
        self.writeData = writeData
    }

    public func enqueue(
        source: URL,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        now: Date
    ) throws -> PatternInboxItem {
        try enqueue(
            source: source,
            originalFilename: source.lastPathComponent,
            declaredFileExtension: source.pathExtension,
            origin: origin,
            targetProjectID: targetProjectID,
            now: now,
            cancellationToken: PatternInboxEnqueueCancellationToken()
        )
    }

    public func enqueue(
        source: URL,
        originalFilename: String,
        declaredFileExtension: String,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        now: Date,
        cancellationToken: PatternInboxEnqueueCancellationToken
    ) throws -> PatternInboxItem {
        try cancellationToken.checkCancellation()
        _ = try recover()
        try cancellationToken.checkCancellation()
        // Validate the source before copying and again after copying: both the source
        // and the owned candidate must be regular, non-symlink files.
        _ = try PatternFileService(root: root).inspect(
            source,
            fileExtension: declaredFileExtension
        )
        try cancellationToken.checkCancellation()
        let id = UUID()
        try createDirectories()
        try cancellationToken.checkCancellation()
        let candidate = candidateURL(for: id)
        var staged: URL?
        var ownedManifest: URL?
        do {
            try copyItem(source, candidate)
            try cancellationToken.checkCancellation()
            let metadata = try PatternFileService(root: root).inspect(
                candidate,
                fileExtension: declaredFileExtension
            )
            try cancellationToken.checkCancellation()
            let item = PatternInboxItem(
                id: id,
                originalFilename: originalFilename,
                receivedAt: now,
                origin: origin,
                targetProjectID: targetProjectID,
                stagedFilename: "\(id.uuidString).\(metadata.fileExtension)"
            )
            let ownedStaged = try stagedURL(for: item)
            staged = ownedStaged
            try cancellationToken.checkCancellation()
            try moveItem(candidate, ownedStaged)
            try cancellationToken.checkCancellation()
            let manifest = manifestURL(for: id)
            guard !FileManager.default.fileExists(atPath: manifest.path) else {
                throw PatternInboxError.invalidItem
            }
            ownedManifest = manifest
            try cancellationToken.performCommit {
                try writeManifest(.init(version: 1, item: item, state: .staged))
            }
            return item
        } catch {
            try? removeOwnedFile(candidate)
            if let staged {
                try? removeOwnedStagedFile(staged)
            }
            if let ownedManifest {
                try? removeOwnedManifestFile(ownedManifest, id: id)
            }
            throw error
        }
    }

    public func item(id: UUID) throws -> PatternInboxItem? {
        _ = try recover()
        guard let manifest = try manifest(id: id), manifest.state == .staged else { return nil }
        return manifest.item
    }

    public func items() throws -> [PatternInboxItem] {
        _ = try recover()
        return try manifestURLs().compactMap { url in
            guard let id = manifestID(from: url.lastPathComponent),
                  let manifest = try manifest(id: id), manifest.state == .staged else {
                return nil
            }
            return manifest.item
        }.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func stagedURL(for item: PatternInboxItem) throws -> URL {
        try validateOwnedInboxTree()
        guard isSafe(item) else { throw PatternInboxError.invalidItem }
        return itemsRoot.appendingPathComponent(item.stagedFilename)
    }

    public func markCommitted(_ item: PatternInboxItem) throws {
        guard let manifest = try manifest(id: item.id), manifest.item == item,
              manifest.state == .staged else { throw PatternInboxError.invalidItem }
        try writeManifest(.init(version: 1, item: item, state: .committed))
    }

    /// Best-effort post-publication cleanup. Its failure must not invalidate the
    /// already committed archive; a later `recover()` retries the same cleanup.
    public func cleanupCommitted(_ item: PatternInboxItem) throws {
        guard let manifest = try manifest(id: item.id), manifest.item == item,
              manifest.state == .committed else { return }
        let staged = try stagedURL(for: item)
        if FileManager.default.fileExists(atPath: staged.path) {
            try removeItem(staged)
        }
        let sidecar = manifestURL(for: item.id)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try removeItem(sidecar)
        }
    }

    /// Returns immutable evidence for a transaction journal without performing
    /// recovery. A committed sidecar may already have removed its staged bytes;
    /// in that one case the committed manifest itself is the cleanup proof.
    func journalVerificationItem(id: UUID) throws -> PatternInboxJournalVerification? {
        do {
            guard let manifest = try manifest(id: id),
                  manifest.version == 1,
                  isSafe(manifest.item) else { return nil }
            let staged = try stagedURL(for: manifest.item)
            if FileManager.default.fileExists(atPath: staged.path) {
                guard try isRegularNonSymlink(staged) else { return nil }
                return PatternInboxJournalVerification(
                    item: manifest.item,
                    metadata: try PatternFileService(root: root).inspect(staged),
                    isCommitted: manifest.state == .committed
                )
            }
            guard manifest.state == .committed else { return nil }
            return PatternInboxJournalVerification(item: manifest.item, metadata: nil, isCommitted: true)
        } catch {
            // A transaction journal must never obtain publication authority from
            // a corrupt or unsupported inbox sidecar.
            return nil
        }
    }

    public func recover(publishedItemIDs: Set<UUID> = []) throws -> PatternInboxRecoveryReport {
        try createDirectories()
        var report = PatternInboxRecoveryReport()
        for candidate in try candidateURLs() {
            guard let id = UUID(uuidString: candidate.lastPathComponent) else { continue }
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            try removeOwnedFile(candidate)
            report.removedCandidateIDs.insert(id)
        }

        var referencedStaged = Set<String>()
        for url in try manifestURLs() {
            guard let id = manifestID(from: url.lastPathComponent) else { continue }
            guard try isRegularNonSymlink(url), let manifest = try? decodedManifest(at: url),
                  manifest.version == 1, manifest.item.id == id, isSafe(manifest.item) else {
                try quarantine(id: id, manifestURL: url, stagedURL: stagedURLIfOwned(id: id))
                report.quarantinedItemIDs.insert(id)
                continue
            }
            let staged = try stagedURL(for: manifest.item)
            referencedStaged.insert(manifest.item.stagedFilename)
            guard FileManager.default.fileExists(atPath: staged.path) else {
                if manifest.state == .committed {
                    do {
                        // A previous cleanup may already have removed staged
                        // bytes before it failed to remove the manifest.
                        try cleanupCommitted(manifest.item)
                        report.cleanedCommittedIDs.insert(id)
                    } catch {
                        // Keep the committed sidecar for the next retry.
                    }
                    continue
                }
                try quarantine(id: id, manifestURL: url, stagedURL: staged)
                report.quarantinedItemIDs.insert(id)
                continue
            }
            guard try isRegularNonSymlink(staged) else {
                try quarantine(id: id, manifestURL: url, stagedURL: staged)
                report.quarantinedItemIDs.insert(id)
                continue
            }
            if manifest.state == .staged, publishedItemIDs.contains(id) {
                do {
                    // The asset journal proves that the archive was already
                    // published.  Do not discard that proof unless this sidecar
                    // transition and its cleanup both finish.
                    try writeManifest(.init(version: 1, item: manifest.item, state: .committed))
                    try cleanupCommitted(manifest.item)
                    report.cleanedCommittedIDs.insert(id)
                } catch {
                    // Leave the staged manifest and the asset journal in place so
                    // the next launch can retry this transition without a second
                    // archive mutation.
                }
            } else if manifest.state == .committed {
                do {
                    try cleanupCommitted(manifest.item)
                    report.cleanedCommittedIDs.insert(id)
                } catch {
                    // Keep the committed manifest intact. This is a retriable cleanup,
                    // never a reason to recreate or re-publish the archive mutation.
                }
            }
        }

        for staged in try stagedURLs() where !referencedStaged.contains(staged.lastPathComponent) {
            guard let id = stagedID(from: staged.lastPathComponent), try isRegularNonSymlink(staged) else { continue }
            try quarantine(id: id, manifestURL: nil, stagedURL: staged)
            report.quarantinedItemIDs.insert(id)
        }
        return report
    }

    private var candidatesRoot: URL { root.appendingPathComponent(".Candidates", isDirectory: true) }
    private var itemsRoot: URL { root.appendingPathComponent("Items", isDirectory: true) }
    private var manifestsRoot: URL { root.appendingPathComponent("Manifests", isDirectory: true) }
    private var quarantineRoot: URL { root.appendingPathComponent(".Quarantine", isDirectory: true) }

    private func createDirectories() throws {
        try validateOwnedInboxTree()
        for url in [candidatesRoot, itemsRoot, manifestsRoot, quarantineRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func candidateURL(for id: UUID) -> URL { candidatesRoot.appendingPathComponent(id.uuidString) }
    private func manifestURL(for id: UUID) -> URL { manifestsRoot.appendingPathComponent("\(id.uuidString).json") }

    private func manifest(id: UUID) throws -> PatternInboxManifest? {
        try validateOwnedInboxTree()
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try isRegularNonSymlink(url) else { throw PatternInboxError.invalidItem }
        return try decodedManifest(at: url)
    }

    private func decodedManifest(at url: URL) throws -> PatternInboxManifest {
        try JSONDecoder().decode(PatternInboxManifest.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ manifest: PatternInboxManifest) throws {
        try validateOwnedInboxTree()
        try writeData(JSONEncoder().encode(manifest), manifestURL(for: manifest.item.id))
    }

    private func candidateURLs() throws -> [URL] { try contents(of: candidatesRoot) }
    private func stagedURLs() throws -> [URL] { try contents(of: itemsRoot) }
    private func manifestURLs() throws -> [URL] { try contents(of: manifestsRoot) }
    private func contents(of root: URL) throws -> [URL] {
        try validateOwnedInboxTree()
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    private func manifestID(from name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }

    private func stagedID(from name: String) -> UUID? {
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, allowedExtensions.contains(String(parts[1]).lowercased()) else { return nil }
        return UUID(uuidString: String(parts[0]))
    }

    private var allowedExtensions: Set<String> { ["pdf", "png", "jpg", "jpeg", "heic"] }
    private func stagedURLIfOwned(id: UUID) -> URL? {
        (try? stagedURLs())?.first { stagedID(from: $0.lastPathComponent) == id }
    }

    private func isSafe(_ item: PatternInboxItem) -> Bool {
        let extensionValue = URL(fileURLWithPath: item.originalFilename).pathExtension.lowercased()
        return !item.originalFilename.isEmpty
            && item.originalFilename == URL(fileURLWithPath: item.originalFilename).lastPathComponent
            && allowedExtensions.contains(extensionValue)
            && item.stagedFilename == "\(item.id.uuidString).\(extensionValue)"
    }

    private func isRegularNonSymlink(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func removeOwnedFile(_ url: URL) throws {
        try validateOwnedInboxTree()
        guard url.deletingLastPathComponent().standardizedFileURL.path == candidatesRoot.standardizedFileURL.path,
              UUID(uuidString: url.lastPathComponent) != nil else { return }
        try removeItem(url)
    }

    private func removeOwnedStagedFile(_ url: URL) throws {
        try validateOwnedInboxTree()
        guard url.deletingLastPathComponent().standardizedFileURL.path == itemsRoot.standardizedFileURL.path,
              stagedID(from: url.lastPathComponent) != nil,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try removeItem(url)
    }

    private func removeOwnedManifestFile(_ url: URL, id: UUID) throws {
        try validateOwnedInboxTree()
        guard url.deletingLastPathComponent().standardizedFileURL.path == manifestsRoot.standardizedFileURL.path,
              manifestID(from: url.lastPathComponent) == id,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try removeItem(url)
    }

    private func quarantine(id: UUID, manifestURL: URL?, stagedURL: URL?) throws {
        try validateOwnedInboxTree()
        let token = "\(id.uuidString)-\(UUID().uuidString)"
        if let manifestURL, FileManager.default.fileExists(atPath: manifestURL.path) {
            try moveItem(manifestURL, quarantineRoot.appendingPathComponent("\(token).manifest"))
        }
        if let stagedURL, FileManager.default.fileExists(atPath: stagedURL.path) {
            let values = try stagedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                // Unlinking a known, UUID-named inbox symlink never follows its target.
                try removeItem(stagedURL)
            } else if values.isRegularFile == true {
                try moveItem(stagedURL, quarantineRoot.appendingPathComponent("\(token).staged"))
            }
        }
    }

    private func validateOwnedInboxTree() throws {
        for directory in [root, candidatesRoot, itemsRoot, manifestsRoot, quarantineRoot] {
            let lexical = directory.standardizedFileURL
            guard lexical.resolvingSymlinksInPath().path == lexical.path else {
                throw PatternInboxError.invalidItem
            }
        }
    }
}
