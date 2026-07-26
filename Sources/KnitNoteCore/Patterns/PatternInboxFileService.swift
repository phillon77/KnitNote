import Foundation

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

public struct PatternInboxFileService: Sendable {
    public let root: URL
    private let moveItem: @Sendable (URL, URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(root: URL) {
        self.init(
            root: root,
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            writeData: { try $0.write(to: $1, options: .atomic) }
        )
    }

    init(
        root: URL,
        moveItem: @escaping @Sendable (URL, URL) throws -> Void,
        removeItem: @escaping @Sendable (URL) throws -> Void,
        writeData: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        self.root = root
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
        _ = try recover()
        // Validate the source before copying and again after copying: both the source
        // and the owned candidate must be regular, non-symlink files.
        _ = try PatternFileService(root: root).inspect(source)
        let id = UUID()
        try createDirectories()
        let candidate = candidateURL(for: id)
        do {
            try FileManager.default.copyItem(at: source, to: candidate)
            let metadata = try PatternFileService(root: root).inspect(
                candidate,
                fileExtension: source.pathExtension
            )
            let item = PatternInboxItem(
                id: id,
                originalFilename: source.lastPathComponent,
                receivedAt: now,
                origin: origin,
                targetProjectID: targetProjectID,
                stagedFilename: "\(id.uuidString).\(metadata.fileExtension)"
            )
            let staged = try stagedURL(for: item)
            try moveItem(candidate, staged)
            try writeManifest(.init(version: 1, item: item, state: .staged))
            return item
        } catch {
            // A candidate is never published. A staged file without a manifest is
            // deliberately recovered/quarantined on the next launch.
            try? removeOwnedFile(candidate)
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
            guard FileManager.default.fileExists(atPath: staged.path), try isRegularNonSymlink(staged) else {
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
        for url in [candidatesRoot, itemsRoot, manifestsRoot, quarantineRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func candidateURL(for id: UUID) -> URL { candidatesRoot.appendingPathComponent(id.uuidString) }
    private func manifestURL(for id: UUID) -> URL { manifestsRoot.appendingPathComponent("\(id.uuidString).json") }

    private func manifest(id: UUID) throws -> PatternInboxManifest? {
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try isRegularNonSymlink(url) else { throw PatternInboxError.invalidItem }
        return try decodedManifest(at: url)
    }

    private func decodedManifest(at url: URL) throws -> PatternInboxManifest {
        try JSONDecoder().decode(PatternInboxManifest.self, from: Data(contentsOf: url))
    }

    private func writeManifest(_ manifest: PatternInboxManifest) throws {
        try writeData(JSONEncoder().encode(manifest), manifestURL(for: manifest.item.id))
    }

    private func candidateURLs() throws -> [URL] { try contents(of: candidatesRoot) }
    private func stagedURLs() throws -> [URL] { try contents(of: itemsRoot) }
    private func manifestURLs() throws -> [URL] { try contents(of: manifestsRoot) }
    private func contents(of root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
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
        guard url.deletingLastPathComponent().standardizedFileURL.path == candidatesRoot.standardizedFileURL.path,
              UUID(uuidString: url.lastPathComponent) != nil else { return }
        try removeItem(url)
    }

    private func quarantine(id: UUID, manifestURL: URL?, stagedURL: URL?) throws {
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
}
