import Combine
import CryptoKit
import Foundation

public struct ProjectArchive: Codable, Sendable {
    public static let currentVersion = 11
    public static let minimumSupportedVersion = 1
    public static let patternLibraryIntroducedVersion = 10

    public static func isSupported(version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
    }

    public static func supportsPatternLibrary(version: Int) -> Bool {
        isSupported(version: version) && version >= patternLibraryIntroducedVersion
    }

    public let version: Int
    public var projects: [StoredProject]
    public var yarns: [StoredYarn]
    public var patternAssets: [PatternAsset]
    public var patterns: [StoredPattern]
    public var patternUsages: [PatternProjectUsage]

    public init(
        version: Int,
        projects: [StoredProject],
        yarns: [StoredYarn] = [],
        patternAssets: [PatternAsset] = [],
        patterns: [StoredPattern] = [],
        patternUsages: [PatternProjectUsage] = []
    ) {
        self.version = version
        self.projects = projects
        self.yarns = yarns
        self.patternAssets = patternAssets
        self.patterns = patterns
        self.patternUsages = patternUsages
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case yarns
        case patternAssets
        case patterns
        case patternUsages
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([StoredProject].self, forKey: .projects)
        yarns = try values.decodeIfPresent([StoredYarn].self, forKey: .yarns) ?? []
        patternAssets = try values.decodeIfPresent([PatternAsset].self, forKey: .patternAssets) ?? []
        patterns = try values.decodeIfPresent([StoredPattern].self, forKey: .patterns) ?? []
        patternUsages = try values.decodeIfPresent([PatternProjectUsage].self, forKey: .patternUsages) ?? []
    }
}

public enum ProjectPhotoChange: Sendable {
    case unchanged
    case replace(Data)
    case remove
}

public enum ProjectStoreError: Error, Equatable, Sendable {
    case unreadableArchive
    case archiveUnavailable
    case invalidYarnProjectLinks
    case patternNotFound
    case staleDataGeneration
    case persistenceFailed
    case accessRestricted
}

public typealias MutationAuthorizer = @MainActor (FeatureMutation) -> FeatureAccessDecision
public typealias MutationSuccessCommitter = @MainActor (FeatureMutation) -> FeatureAccessDecision

public enum PatternLibraryMutationError: Error, Equatable, Sendable {
    case patternNotFound
    case projectNotFound
    case usageNotFound
    case usageInactive
    case projectCompleted
    case activeLinksExist([UUID])
}

/// Counter changes issued from a pattern reader are tied to one active usage,
/// rather than merely to the containing project.
public enum PatternReaderCounterMutation: Sendable {
    case increment
    case reset
    case update(name: String?, value: Int)
}

enum ProjectJournalPhotoReferencePolicy {
    static func unreferencedFilenames(
        requestedFilenames: Set<String>,
        remainingProjects: [StoredProject]
    ) -> Set<String> {
        let referencedFilenames = Set(
            remainingProjects.flatMap(\.journalEntries).flatMap {
                [$0.photoFilename, $0.thumbnailFilename]
            }
        )
        return Set(requestedFilenames.filter(ProjectJournalPhotoFilename.isManaged))
            .subtracting(referencedFilenames)
    }
}

enum PatternLibraryDeletionError: Error, Equatable, Sendable {
    case invalidJournal
    case unsafeTransactionRoot
    case conflictingFiles
}

enum PatternLibraryDeletionPhase: String, Codable, Sendable {
    case staged
    case published
    case committed
}

struct PatternLibraryDeletionItem: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case usageMarkup
        case asset
    }

    let kind: Kind
    let usageID: UUID?
    let asset: PatternAsset?
    let canonicalRelativePath: String
    let stagedFilename: String

    static func usageMarkup(_ usageID: UUID) -> PatternLibraryDeletionItem {
        .init(
            kind: .usageMarkup,
            usageID: usageID,
            asset: nil,
            canonicalRelativePath: "UsageMarkup/\(usageID.uuidString)",
            stagedFilename: "usage-\(usageID.uuidString)"
        )
    }

    static func asset(_ asset: PatternAsset) -> PatternLibraryDeletionItem {
        .init(
            kind: .asset,
            usageID: nil,
            asset: asset,
            canonicalRelativePath: "Assets/\(asset.storedFilename)",
            stagedFilename: "asset-\(asset.id.uuidString)"
        )
    }

    var isValid: Bool {
        switch kind {
        case .usageMarkup:
            guard let usageID, asset == nil else { return false }
            return canonicalRelativePath == "UsageMarkup/\(usageID.uuidString)"
                && stagedFilename == "usage-\(usageID.uuidString)"
        case .asset:
            guard let asset, usageID == nil else { return false }
            return canonicalRelativePath == "Assets/\(asset.storedFilename)"
                && stagedFilename == "asset-\(asset.id.uuidString)"
        }
    }
}

struct PatternLibraryDeletionJournal: Codable, Sendable {
    private struct Payload: Codable {
        let version: Int
        let transactionID: UUID
        let phase: PatternLibraryDeletionPhase
        let items: [PatternLibraryDeletionItem]
    }

    let version: Int
    let transactionID: UUID
    let phase: PatternLibraryDeletionPhase
    let items: [PatternLibraryDeletionItem]
    let integrity: String

    init(
        transactionID: UUID,
        phase: PatternLibraryDeletionPhase,
        items: [PatternLibraryDeletionItem]
    ) throws {
        version = 1
        self.transactionID = transactionID
        self.phase = phase
        self.items = items
        integrity = try Self.integrity(
            for: .init(version: version, transactionID: transactionID, phase: phase, items: items)
        )
    }

    func isValid() throws -> Bool {
        guard version == 1, hasValidStructure else { return false }
        let expectedIntegrity = try Self.integrity(
            for: .init(version: version, transactionID: transactionID, phase: phase, items: items)
        )
        return integrity == expectedIntegrity
    }

    var hasValidStructure: Bool {
        !items.isEmpty
            && Set(items.map(\.stagedFilename)).count == items.count
            && items.allSatisfy(\.isValid)
    }

    func withPhase(_ phase: PatternLibraryDeletionPhase) throws -> PatternLibraryDeletionJournal {
        try .init(transactionID: transactionID, phase: phase, items: items)
    }

    private static func integrity(for payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class PatternLibraryDeletionTransaction {
    private let markupService: PatternMarkupFileService
    private let fileService: PatternFileService
    private let transactionsRoot: URL
    private let isNoOp: Bool
    private var journal: PatternLibraryDeletionJournal
    private let transactionRoot: URL

    private init(
        root: URL,
        markupService: PatternMarkupFileService,
        fileService: PatternFileService,
        journal: PatternLibraryDeletionJournal,
        isNoOp: Bool = false
    ) throws {
        self.markupService = markupService
        self.fileService = fileService
        self.isNoOp = isNoOp
        transactionsRoot = try Self.validatedTransactionsRoot(root)
        self.journal = journal
        transactionRoot = transactionsRoot
            .appendingPathComponent(journal.transactionID.uuidString, isDirectory: true)
    }

    static func begin(
        root: URL,
        markupService: PatternMarkupFileService,
        usageIDs: [UUID],
        asset: PatternAsset?,
        fileService: PatternFileService
    ) throws -> PatternLibraryDeletionTransaction {
        let items = usageIDs.map(PatternLibraryDeletionItem.usageMarkup)
            + (asset.map { [PatternLibraryDeletionItem.asset($0)] } ?? [])
        return try .init(
            root: root,
            markupService: markupService,
            fileService: fileService,
            journal: try .init(transactionID: UUID(), phase: .staged, items: items),
            isNoOp: items.isEmpty
        )
    }

    func stage() throws {
        guard !isNoOp else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: transactionsRoot, withIntermediateDirectories: true)
        try writeJournal()
        do {
            try manager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)
            for item in journal.items {
                try moveIfPresent(item)
            }
        } catch {
            try rollback()
            throw error
        }
    }

    func publish() throws {
        guard !isNoOp else { return }
        journal = try journal.withPhase(.published)
        try writeJournal()
    }

    func rollback() throws {
        guard !isNoOp else { return }
        let manager = FileManager.default
        for item in journal.items.reversed() {
            let source = try canonicalURL(for: item)
            let staged = stagedURL(for: item)
            guard manager.fileExists(atPath: staged.path) else { continue }
            guard !manager.fileExists(atPath: source.path) else {
                throw PatternLibraryDeletionError.conflictingFiles
            }
            try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: staged, to: source)
        }
        if manager.fileExists(atPath: transactionRoot.path) {
            try manager.removeItem(at: transactionRoot)
        }
        try removeJournalAndEmptyRoot()
    }

    func commit() throws {
        guard !isNoOp else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: transactionRoot.path) {
            try manager.removeItem(at: transactionRoot)
        }
        journal = try journal.withPhase(.committed)
        try writeJournal()
        try removeJournalAndEmptyRoot()
    }

    static func recover(
        root: URL,
        markupService: PatternMarkupFileService,
        fileService: PatternFileService,
        archive: ProjectArchive
    ) throws {
        let transactionsRoot = try validatedTransactionsRoot(root)
        let manager = FileManager.default
        guard manager.fileExists(atPath: transactionsRoot.path) else { return }
        let entries = try manager.contentsOfDirectory(
            at: transactionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        let journalURLs = try entries.compactMap { url -> URL? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw PatternLibraryDeletionError.invalidJournal
            }
            if values.isDirectory == true {
                guard UUID(uuidString: url.lastPathComponent) != nil else {
                    throw PatternLibraryDeletionError.invalidJournal
                }
                return nil
            }
            guard url.pathExtension == "json",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  values.isRegularFile == true else {
                throw PatternLibraryDeletionError.invalidJournal
            }
            return url
        }
        for url in journalURLs {
            let journal: PatternLibraryDeletionJournal
            do {
                journal = try JSONDecoder().decode(PatternLibraryDeletionJournal.self, from: Data(contentsOf: url))
            } catch {
                throw PatternLibraryDeletionError.invalidJournal
            }
            guard try journal.isValid(),
                  journal.transactionID.uuidString == url.deletingPathExtension().lastPathComponent else {
                throw PatternLibraryDeletionError.invalidJournal
            }
            let transaction = try PatternLibraryDeletionTransaction(
                root: root,
                markupService: markupService,
                fileService: fileService,
                journal: journal
            )
            let archiveStillReferencesAnItem = journal.items.contains { item in
                switch item.kind {
                case .usageMarkup:
                    return item.usageID.map { usageID in archive.patternUsages.contains { $0.id == usageID } } ?? false
                case .asset:
                    return item.asset.map { asset in archive.patternAssets.contains { $0.id == asset.id } } ?? false
                }
            }
            if archiveStillReferencesAnItem {
                try transaction.rollback()
            } else {
                try transaction.commit()
            }
        }
        if manager.fileExists(atPath: transactionsRoot.path) {
            let remaining = try manager.contentsOfDirectory(atPath: transactionsRoot.path)
            guard remaining.isEmpty else { throw PatternLibraryDeletionError.invalidJournal }
            try manager.removeItem(at: transactionsRoot)
        }
    }

    private func moveIfPresent(_ item: PatternLibraryDeletionItem) throws {
        let manager = FileManager.default
        let source = try canonicalURL(for: item)
        guard manager.fileExists(atPath: source.path) else { return }
        try manager.moveItem(at: source, to: stagedURL(for: item))
    }

    private func canonicalURL(for item: PatternLibraryDeletionItem) throws -> URL {
        switch item.kind {
        case .usageMarkup:
            guard let usageID = item.usageID else { throw PatternLibraryDeletionError.invalidJournal }
            return try markupService.usageMarkupDirectory(usageID: usageID)
        case .asset:
            guard let asset = item.asset else { throw PatternLibraryDeletionError.invalidJournal }
            return try fileService.assetURL(asset)
        }
    }

    private func stagedURL(for item: PatternLibraryDeletionItem) -> URL {
        transactionRoot.appendingPathComponent(item.stagedFilename, isDirectory: item.kind == .usageMarkup)
    }

    private func writeJournal() throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private var journalURL: URL {
        transactionsRoot.appendingPathComponent("\(journal.transactionID.uuidString).json")
    }

    private func removeJournalAndEmptyRoot() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: journalURL.path) {
            try manager.removeItem(at: journalURL)
        }
        if manager.fileExists(atPath: transactionsRoot.path),
           try manager.contentsOfDirectory(atPath: transactionsRoot.path).isEmpty {
            try manager.removeItem(at: transactionsRoot)
        }
    }

    private static func validatedTransactionsRoot(_ root: URL) throws -> URL {
        let canonicalRoot = root.standardizedFileURL
        guard canonicalRoot.resolvingSymlinksInPath().path == canonicalRoot.path else {
            throw PatternLibraryDeletionError.unsafeTransactionRoot
        }
        let transactionsRoot = canonicalRoot
            .appendingPathComponent(".DeletionTransactions", isDirectory: true)
            .standardizedFileURL
        guard transactionsRoot.deletingLastPathComponent().path == canonicalRoot.path,
              transactionsRoot.resolvingSymlinksInPath().path == transactionsRoot.path else {
            throw PatternLibraryDeletionError.unsafeTransactionRoot
        }
        return transactionsRoot
    }

}

@MainActor public final class JSONProjectStore: ObservableObject {
    @Published public private(set) var projects: [StoredProject] = []
    @Published public private(set) var yarns: [StoredYarn] = []
    @Published public private(set) var patternAssets: [PatternAsset] = []
    @Published public private(set) var patterns: [StoredPattern] = []
    @Published public private(set) var patternUsages: [PatternProjectUsage] = []
    @Published public private(set) var loadError: ProjectStoreError?
    @Published public private(set) var isDataOperationInProgress = false
    @Published public private(set) var dataGeneration: UInt64 = 0
    @Published public private(set) var projectCoverGeneration: UInt64 = 0
    private var url: URL
    private let photoService: ProjectPhotoFileService
    private let yarnPhotoService: YarnPhotoFileService
    private let journalPhotoService: ProjectJournalPhotoFileService
    private var patternFileService: PatternFileService?
    private var patternInboxFileService: PatternInboxFileService?
    private var patternPublicationReceiptService: PatternInboxPublicationReceiptService?
    private let patternMarkupFileService: PatternMarkupFileService
    private let patternThumbnailService: PatternThumbnailFileService
    private let backupService: KnitNoteBackupService
    private let archiveWrite: @Sendable (Data, URL) throws -> Void
    private let patternStorageLocationsProvider: (() throws -> PatternStorageLocations)?
    private var activeJournalPhotoTransactions = 0
    private var activePatternTransactions = 0
    private let authorizeMutation: MutationAuthorizer
    private let commitSuccessfulMutation: MutationSuccessCommitter

    public convenience init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternInboxFileService: PatternInboxFileService? = nil,
        patternPublicationReceiptService: PatternInboxPublicationReceiptService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        patternThumbnailService: PatternThumbnailFileService? = nil,
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) {
        let liveRoot = url.deletingLastPathComponent()
        let workRoot = liveRoot.deletingLastPathComponent().appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        self.init(
            url: url,
            photoService: photoService,
            yarnPhotoService: yarnPhotoService,
            journalPhotoService: journalPhotoService,
            patternFileService: patternFileService,
            patternInboxFileService: patternInboxFileService,
            patternPublicationReceiptService: patternPublicationReceiptService,
            patternMarkupFileService: patternMarkupFileService,
            patternThumbnailService: patternThumbnailService,
            backupService: KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot),
            authorizeMutation: authorizeMutation,
            commitSuccessfulMutation: commitSuccessfulMutation
        )
    }

    init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternInboxFileService: PatternInboxFileService? = nil,
        patternPublicationReceiptService: PatternInboxPublicationReceiptService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        patternThumbnailService: PatternThumbnailFileService? = nil,
        backupService: KnitNoteBackupService,
        initialLoadError: ProjectStoreError? = nil,
        patternStorageLocationsProvider: (() throws -> PatternStorageLocations)? = nil,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        },
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) {
        self.url = url
        self.photoService = photoService ?? ProjectPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("ProjectPhotos", isDirectory: true)
        )
        self.yarnPhotoService = yarnPhotoService ?? YarnPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("YarnPhotos", isDirectory: true)
        )
        self.journalPhotoService = journalPhotoService ?? ProjectJournalPhotoFileService(
            directory: url.deletingLastPathComponent().appendingPathComponent("ProjectJournalPhotos", isDirectory: true)
        )
        self.patternStorageLocationsProvider = patternStorageLocationsProvider
        let fallbackPatternRoot = url.deletingLastPathComponent().appendingPathComponent("Patterns", isDirectory: true)
        self.patternFileService = patternFileService ?? (patternStorageLocationsProvider == nil
            ? PatternFileService(root: fallbackPatternRoot)
            : nil)
        self.patternPublicationReceiptService = patternPublicationReceiptService
            ?? (patternStorageLocationsProvider == nil
                ? PatternInboxPublicationReceiptService(root: fallbackPatternRoot)
                : nil)
        self.patternInboxFileService = patternInboxFileService ?? (patternStorageLocationsProvider == nil
            ? PatternInboxFileService(root: url.deletingLastPathComponent().appendingPathComponent("PatternInbox", isDirectory: true))
            : nil)
        self.patternMarkupFileService = patternMarkupFileService ?? PatternMarkupFileService(
            root: self.patternFileService?.root ?? fallbackPatternRoot
        )
        let liveRoot = url.deletingLastPathComponent()
        self.patternThumbnailService = patternThumbnailService ?? PatternThumbnailFileService(
            directory: liveRoot.deletingLastPathComponent().appendingPathComponent(
                ".KnitNote-PatternThumbnailCache",
                isDirectory: true
            )
        )
        self.backupService = backupService
        self.archiveWrite = archiveWrite
        self.authorizeMutation = authorizeMutation
        self.commitSuccessfulMutation = commitSuccessfulMutation
        if let initialLoadError {
            loadError = initialLoadError
        } else {
            load()
        }
    }

    public static func live(
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) -> JSONProjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            return try live(
                baseDirectory: base,
                locations: PatternStorageLocations.live(),
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        } catch {
            // The normal iOS path never substitutes a private inbox when the App
            // Group is unavailable. The error store cannot publish mutations.
            let liveRoot = base.appendingPathComponent("KnitNote", isDirectory: true)
            let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
            let workRoot = base.appendingPathComponent(".KnitNote-BackupWork", isDirectory: true)
            return JSONProjectStore(
                url: archiveURL,
                backupService: KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot),
                initialLoadError: .archiveUnavailable,
                patternStorageLocationsProvider: { try PatternStorageLocations.live() },
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        }
    }

    public static func live(
        baseDirectory: URL,
        authorizeMutation: @escaping MutationAuthorizer = { _ in .allow },
        commitSuccessfulMutation: @escaping MutationSuccessCommitter = { _ in .allow }
    ) -> JSONProjectStore {
        let liveRoot = baseDirectory.appendingPathComponent("KnitNote", isDirectory: true)
        return live(
            baseDirectory: baseDirectory,
            locations: PatternStorageLocations(
                assetRoot: liveRoot.appendingPathComponent("Patterns", isDirectory: true),
                inboxRoot: liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
            ),
            authorizeMutation: authorizeMutation,
            commitSuccessfulMutation: commitSuccessfulMutation
        )
    }

    private static func live(
        baseDirectory: URL,
        locations: PatternStorageLocations,
        authorizeMutation: @escaping MutationAuthorizer,
        commitSuccessfulMutation: @escaping MutationSuccessCommitter
    ) -> JSONProjectStore {
        let liveRoot = locations.assetRoot.deletingLastPathComponent()
        let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        let workRoot = baseDirectory.appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        let backupService = KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        do {
            let interruptedInstallation = try backupService.recoverInterruptedReplacement()
            let store = JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                backupService: backupService,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
            guard let interruptedInstallation else { return store }
            if store.loadError == nil {
                backupService.commit(interruptedInstallation)
                return store
            }
            try backupService.rollback(interruptedInstallation)
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                backupService: backupService,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        } catch {
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                backupService: backupService,
                initialLoadError: .unreadableArchive,
                authorizeMutation: authorizeMutation,
                commitSuccessfulMutation: commitSuccessfulMutation
            )
        }
    }
    public func retryLoad() {
        guard loadError != nil else { return }
        do {
            try refreshPatternStorageDependencies()
            load()
        } catch {
            loadError = .archiveUnavailable
        }
    }

    public func reloadFromDisk() throws {
        guard !isDataOperationInProgress else {
            throw KnitNoteBackupError.operationInProgress
        }
        try reloadFromDiskDuringDataOperation()
    }

    public func exportBackup(appVersion: String) async throws -> URL {
        try beginDataOperation()
        defer { isDataOperationInProgress = false }
        let service = backupService
        return try await Task.detached(priority: .userInitiated) {
            try service.createPackage(appVersion: appVersion)
        }.value
    }

    public func prepareBackupRestore(from packageURL: URL) async throws -> StagedKnitNoteBackup {
        let accessedSecurityScope = packageURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                packageURL.stopAccessingSecurityScopedResource()
            }
        }
        let service = backupService
        return try await Task.detached(priority: .userInitiated) {
            try service.stagePackage(at: packageURL)
        }.value
    }

    public func cancelBackupRestore(_ backup: StagedKnitNoteBackup) {
        removeOwnedBackupArtifact(at: backup.root, kind: .stagedRestore)
    }

    public func cleanupBackupArtifact(at url: URL) {
        removeOwnedBackupArtifact(at: url, kind: .exportPackage)
    }

    public func restoreBackup(_ backup: StagedKnitNoteBackup) async throws {
        try requireAccess(.restoreBackup)
        try beginDataOperation()
        defer { isDataOperationInProgress = false }
        let service = backupService
        let installation = try await Task.detached(priority: .userInitiated) {
            try service.install(backup)
        }.value

        do {
            try reloadFromDiskDuringDataOperation()
        } catch {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.rollback(installation)
                }.value
                try reloadFromDiskDuringDataOperation()
            } catch {
                throw KnitNoteBackupError.rollbackFailed
            }
            throw KnitNoteBackupError.installFailedOriginalPreserved
        }
        await Task.detached(priority: .utility) {
            service.commit(installation)
        }.value
        try? patternThumbnailService.deleteAll()
        projectCoverGeneration &+= 1
    }
    public func add(name: String) throws { try add(name: name, photoData: nil) }
    public func add(name: String, photoData: Data?) throws {
        var project = try StoredProject(name: name)
        try requireAccess(.createProject)
        var newFilename: String?
        do {
            if let photoData {
                try ensureArchiveAvailable()
                newFilename = try photoService.save(data: photoData, projectID: project.id)
                project.setPhotoFilename(newFilename)
            }
            try persist(projects: projects + [project], yarns: yarns)
        } catch {
            if let newFilename { try? photoService.delete(filename: newFilename) }
            throw error
        }
    }
    public func delete(id: UUID) throws {
        try requireAccess(.deleteProject)
        let deletedProject = projects.first(where: { $0.id == id })
        guard let deletedProject else { return }
        let filename = deletedProject.photoFilename
        let journalFilenames = Set(deletedProject.journalEntries.flatMap {
            [$0.photoFilename, $0.thumbnailFilename]
        })
        var stagedYarns = yarns
        let now = Date.now
        for index in stagedYarns.indices where stagedYarns[index].linkedProjectIDs.contains(id) {
            stagedYarns[index].setLinkedProjectIDs(
                stagedYarns[index].linkedProjectIDs.subtracting([id]),
                now: now
            )
        }
        let removedUsages = patternUsages.filter { $0.projectID == id }
        let remainingUsages = patternUsages.filter { $0.projectID != id }
        let files = try requiredPatternFileService()
        let deletion = try PatternLibraryDeletionTransaction.begin(
            root: files.root,
            markupService: patternMarkupFileService,
            usageIDs: removedUsages.map(\.id),
            asset: nil,
            fileService: files
        )
        try deletion.stage()
        do {
            try persist(
                projects: projects.filter { $0.id != id },
                yarns: stagedYarns,
                patternUsages: remainingUsages
            )
        } catch {
            try deletion.rollback()
            throw error
        }
        try deletion.publish()
        try deletion.commit()
        if let filename { try? photoService.delete(filename: filename) }
        deleteJournalPhotosIfUnreferenced(journalFilenames)
    }
    public func rename(id: UUID, to name: String) throws {
        try requireAccess(.editProject)
        try mutate(id: id) { try $0.rename(to: name) }
    }
    public func markCompleted(projectID: UUID) throws {
        try requireAccess(.completeProject)
        try mutate(id: projectID) { $0.markCompleted() }
    }
    public func resumeProject(projectID: UUID) throws {
        try requireAccess(.resumeProject)
        try mutate(id: projectID) { $0.resume() }
    }
    public func updateProject(
        id: UUID,
        name: String,
        toolType: ProjectToolType?,
        toolSize: String?,
        toolNotes: String?,
        photoChange: ProjectPhotoChange
    ) throws {
        try requireAccess(.editProject)
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let oldFilename = projects[index].photoFilename
        var updated = projects[index]
        try updated.rename(to: name)
        updated.updateToolDetails(type: toolType, size: toolSize, notes: toolNotes)
        var newFilename: String?
        do {
            switch photoChange {
            case .unchanged:
                break
            case let .replace(data):
                try ensureArchiveAvailable()
                newFilename = try photoService.save(data: data, projectID: id)
                updated.setPhotoFilename(newFilename)
            case .remove:
                updated.setPhotoFilename(nil)
            }
            var staged = projects
            staged[index] = updated
            try persist(projects: staged, yarns: yarns)
        } catch {
            if let newFilename { try? photoService.delete(filename: newFilename) }
            throw error
        }
        if let oldFilename, oldFilename != updated.photoFilename {
            try? photoService.delete(filename: oldFilename)
        }
    }
    public func selectCounter(projectID: UUID, counterID: UUID) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.selectCounter(id: counterID) }
    }
    public func incrementCounter(projectID: UUID, counterID: UUID) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.incrementCounter(id: counterID) }
    }
    public func decrementCounter(projectID: UUID, counterID: UUID) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.decrementCounter(id: counterID) }
    }
    public func resetCounter(projectID: UUID, counterID: UUID) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.resetCounter(id: counterID) }
    }
    public func updateCounter(projectID: UUID, counterID: UUID, name: String?, value: Int) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.updateCounter(id: counterID, name: name, value: value) }
    }

    /// Performs one reader-originated counter mutation and returns the exact
    /// generation published by its successful archive write.
    @discardableResult
    public func mutatePatternReaderCounter(
        usageID: UUID,
        counterID: UUID,
        mutation: PatternReaderCounterMutation,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try requireAccess(.changeCounter)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let usageIndex = try mutableUsageIndex(usageID: usageID)
        let projectID = patternUsages[usageIndex].projectID
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        var stagedProjects = projects
        stagedProjects[projectIndex].selectCounter(id: counterID)
        switch mutation {
        case .increment:
            stagedProjects[projectIndex].incrementCounter(id: counterID)
        case .reset:
            stagedProjects[projectIndex].resetCounter(id: counterID)
        case let .update(name, value):
            stagedProjects[projectIndex].updateCounter(id: counterID, name: name, value: value)
        }
        try persist(projects: stagedProjects, yarns: yarns)
        return dataGeneration
    }
    public func renameCounter(projectID: UUID, counterID: UUID, name: String?) throws {
        try requireAccess(.changeCounter)
        try mutate(id: projectID) { $0.renameCounter(id: counterID, to: name) }
    }
    public func applyWatchCommand(
        _ command: WatchCounterCommand,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        try authorizeWatchCounterMutation()
        return try applyAuthorizedWatchCommand(
            command,
            entitlement: .permanentlyUnlocked,
            ledger: &ledger,
            now: now
        )
    }

    public func applyWatchCommand(
        _ command: WatchCounterCommand,
        entitlement: EntitlementSnapshot,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        do {
            try requireWatchEntitlement(entitlement, now: now)
        } catch ProjectStoreError.accessRestricted {
            try ensureArchiveAvailable()
            ledger.record(command.id, at: now)
            return try watchAcknowledgement(
                for: command.id,
                rejection: .entitlementRequired,
                entitlement: entitlement,
                now: now
            )
        }
        return try applyAuthorizedWatchCommand(
            command,
            entitlement: entitlement,
            ledger: &ledger,
            now: now
        )
    }

    public func acknowledgeRejectedWatchCommandDurably(
        _ command: WatchCounterCommand,
        rejection: WatchCommandRejection,
        entitlement: EntitlementSnapshot,
        ledgerURL: URL,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        try ensureArchiveAvailable()
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try ledgerFile.load() ?? ProcessedWatchCommandLedger()
        ledger.record(command.id, at: now)
        try ledgerFile.save(ledger)
        return try watchAcknowledgement(
            for: command.id,
            rejection: rejection,
            entitlement: entitlement,
            now: now
        )
    }

    func requireWatchEntitlement(_ entitlement: EntitlementSnapshot, now: Date) throws {
        guard FeatureAccessPolicy.decision(
            for: .changeCounter,
            snapshot: entitlement,
            now: now
        ) == .allow else {
            throw ProjectStoreError.accessRestricted
        }
        guard entitlement.state(at: now) != .trialNotStarted else {
            throw ProjectStoreError.accessRestricted
        }
    }

    func authorizeWatchCounterMutation() throws {
        try requireAccess(.changeCounter)
    }

    func applyAuthorizedWatchCommand(
        _ command: WatchCounterCommand,
        entitlement: EntitlementSnapshot = .permanentlyUnlocked,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date
    ) throws -> WatchCommandAcknowledgement {
        try ensureArchiveAvailable()
        if ledger.contains(command.id) {
            return try watchAcknowledgement(
                for: command.id,
                rejection: nil,
                entitlement: entitlement,
                now: now
            )
        }

        let rejection: WatchCommandRejection?
        if command.schemaVersion != WatchCounterCommand.currentSchemaVersion {
            rejection = .unsupportedSchema
        } else if let project = project(id: command.projectID) {
            if !project.counters.contains(where: { $0.id == command.counterID }) {
                rejection = .counterMissing
            } else if project.isCompleted {
                rejection = .projectCompleted
            } else {
                rejection = nil
            }
        } else {
            rejection = .projectMissing
        }

        if let rejection {
            ledger.record(command.id, at: now)
            return try watchAcknowledgement(
                for: command.id,
                rejection: rejection,
                entitlement: entitlement,
                now: now
            )
        }

        try mutate(id: command.projectID) { project in
            switch command.operation {
            case .increment:
                project.incrementCounter(id: command.counterID, now: now)
            case .decrement:
                project.decrementCounter(id: command.counterID, now: now)
            case .reset:
                project.resetCounter(id: command.counterID, now: now)
            }
        }
        ledger.record(command.id, at: now)
        return try watchAcknowledgement(
            for: command.id,
            rejection: nil,
            entitlement: entitlement,
            now: now
        )
    }
    public func saveNote(projectID: UUID, counterID: UUID, row: Int, text: String) throws {
        try requireAccess(.editNote)
        try mutate(id: projectID) { try $0.saveNote(counterID: counterID, row: row, text: text) }
    }
    public func deleteNote(projectID: UUID, counterID: UUID, row: Int) throws {
        try requireAccess(.editNote)
        try mutate(id: projectID) { $0.deleteNote(counterID: counterID, row: row) }
    }
    public func addPattern(projectID: UUID, pattern: PatternDocument) throws {
        try requireAccess(.importPattern)
        try addPatternWithoutAuthorization(projectID: projectID, pattern: pattern)
    }
    private func addPatternWithoutAuthorization(
        projectID: UUID,
        pattern: PatternDocument
    ) throws {
        try mutate(id: projectID) { $0.addPattern(pattern) }
    }
    public func importPattern(from source: URL, projectID: UUID) async throws -> PatternDocument {
        let access = try preflightAccess(.importPattern)
        try ensureArchiveAvailable()
        guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
        let service = try requiredPatternFileService()
        _ = try service.inspect(source)
        try commitAccessIfNeeded(access, mutation: .importPattern)
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let pattern = try await Task.detached(priority: .userInitiated) {
            try service.importFile(from: source, projectID: projectID)
        }.value
        do {
            try Task.checkCancellation()
            guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
            try addPatternWithoutAuthorization(projectID: projectID, pattern: pattern)
        } catch {
            try? service.delete(projectID: projectID, pattern: pattern)
            throw error
        }
        return pattern
    }
    public func processPatternInboxItem(
        id: UUID,
        selectingPatternID: UUID? = nil
    ) async throws -> PatternImportOutcome {
        return try await processPatternInboxItem(
            id: id,
            duplicateResolution: selectingPatternID.map(PatternImportDuplicateResolution.existing)
                ?? .automatic
        )
    }

    public func processPatternInboxItem(
        id: UUID,
        duplicateResolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome {
        let access = try preflightAccess(.importPattern)
        return try await withActivePatternTransaction {
            try await processPatternInboxItemWithoutTransaction(
                id: id,
                duplicateResolution: duplicateResolution,
                access: access
            )
        }
    }

    private func processPatternInboxItemWithoutTransaction(
        id: UUID,
        duplicateResolution: PatternImportDuplicateResolution,
        access: FeatureAccessDecision
    ) async throws -> PatternImportOutcome {
        try ensureArchiveAvailable()
        try await reconcilePublishedPatternInboxItems()
        let inbox = try requiredPatternInboxFileService()
        let files = try requiredPatternFileService()
        guard let item = try inbox.item(id: id) else {
            throw PatternInboxError.itemNotFound
        }
        let capturedGeneration = dataGeneration

        let coordinator = PatternImportCoordinator()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try coordinator.prepare(item: item, inbox: inbox, fileService: files)
        }.value
        try Task.checkCancellation()

        // A completed detached read may have raced with another published mutation.
        // Resolve from the current arrays either way; this branch makes that contract explicit.
        if dataGeneration != capturedGeneration {
            try ensureArchiveAvailable()
        }
        if let targetProjectID = prepared.item.targetProjectID {
            guard project(id: targetProjectID) != nil else {
                throw ProjectStoreError.patternNotFound
            }
        }
        return try publishPatternImport(
            prepared,
            duplicateResolution: duplicateResolution,
            access: access
        )
    }

    public func pendingPatternInboxItems() async throws -> [PatternInboxItem] {
        try await withActivePatternTransaction {
            try ensureArchiveAvailable()
            try await reconcilePublishedPatternInboxItems()
            let inbox = try requiredPatternInboxFileService()
            return try await Task.detached(priority: .utility) {
                try inbox.items()
            }.value
        }
    }

    public func discardPatternInboxItem(id: UUID) async throws {
        try requireAccess(.importPattern)
        try await withActivePatternTransaction {
            try ensureArchiveAvailable()
            let inbox = try requiredPatternInboxFileService()
            try await Task.detached(priority: .utility) {
                guard let item = try inbox.item(id: id) else { return }
                try inbox.markCommitted(item)
                try inbox.cleanupCommitted(item)
            }.value
        }
    }

    public func importPatternFromLibrary(
        _ source: URL,
        now: Date = .now
    ) async throws -> PatternImportOutcome {
        let access = try preflightAccess(.importPattern)
        try ensureArchiveAvailable()
        _ = try requiredPatternFileService().inspect(source)
        try commitAccessIfNeeded(access, mutation: .importPattern)
        return try await enqueuePatternImport(
            source,
            origin: .library,
            targetProjectID: nil,
            now: now
        )
    }

    public func importPatternFromProject(
        _ source: URL,
        projectID: UUID,
        now: Date = .now
    ) async throws -> PatternImportOutcome {
        let access = try preflightAccess(.importPattern)
        guard project(id: projectID) != nil else {
            throw PatternLibraryMutationError.projectNotFound
        }
        try ensureArchiveAvailable()
        _ = try requiredPatternFileService().inspect(source)
        try commitAccessIfNeeded(access, mutation: .importPattern)
        return try await enqueuePatternImport(
            source,
            origin: .project,
            targetProjectID: projectID,
            now: now
        )
    }

    private func enqueuePatternImport(
        _ source: URL,
        origin: PatternImportOrigin,
        targetProjectID: UUID?,
        now: Date
    ) async throws -> PatternImportOutcome {
        try await withActivePatternTransaction {
            try ensureArchiveAvailable()
            let inbox = try requiredPatternInboxFileService()
            let item = try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try inbox.enqueue(
                    source: source,
                    origin: origin,
                    targetProjectID: targetProjectID,
                    now: now
                )
            }.value
            try Task.checkCancellation()
            return try await processPatternInboxItemWithoutTransaction(
                id: item.id,
                duplicateResolution: .automatic,
                access: .allow
            )
        }
    }
    public func deletePattern(projectID: UUID, id: UUID) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let pattern = project(id: projectID)?.patterns.first(where: { $0.id == id }) else {
            return
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        try mutate(id: projectID) { $0.deletePattern(id: id) }
        try? requiredPatternFileService().delete(projectID: projectID, pattern: pattern)
    }

    @discardableResult
    public func linkPattern(patternID: UUID, to projectID: UUID) throws -> PatternProjectUsage {
        try requireAccess(.linkPattern)
        try ensureArchiveAvailable()
        guard patterns.contains(where: { $0.id == patternID }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        guard projects.contains(where: { $0.id == projectID }) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        if let index = patternUsages.firstIndex(where: {
            $0.patternID == patternID && $0.projectID == projectID
        }) {
            guard !patternUsages[index].isActive else { return patternUsages[index] }
            var staged = patternUsages
            staged[index].isActive = true
            staged[index].unlinkedAt = nil
            try persist(projects: projects, yarns: yarns, patternUsages: staged)
            return staged[index]
        }
        let nextSortOrder = (patternUsages.filter { $0.projectID == projectID }
            .map(\.sortOrder).max() ?? -1) + 1
        let usage = PatternProjectUsage(
            patternID: patternID,
            projectID: projectID,
            sortOrder: nextSortOrder
        )
        try persist(
            projects: projects,
            yarns: yarns,
            patternUsages: patternUsages + [usage]
        )
        return usage
    }

    public func unlinkPattern(patternID: UUID, from projectID: UUID) throws {
        try requireAccess(.linkPattern)
        try ensureArchiveAvailable()
        guard let index = patternUsages.firstIndex(where: {
            $0.patternID == patternID && $0.projectID == projectID
        }) else {
            return
        }
        guard patternUsages[index].isActive else { return }
        var staged = patternUsages
        staged[index].isActive = false
        staged[index].unlinkedAt = .now
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
    }

    public func deletePatternPermanently(id: UUID) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let pattern = patterns.first(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        let usagesToDelete = patternUsages.filter { $0.patternID == id }
        let activeProjectIDs = usagesToDelete.filter(\.isActive).map(\.projectID)
            .sorted { $0.uuidString < $1.uuidString }
        guard activeProjectIDs.isEmpty else {
            throw PatternLibraryMutationError.activeLinksExist(activeProjectIDs)
        }
        let assetIsUnreferenced = !patterns.contains { $0.id != id && $0.assetID == pattern.assetID }
        let asset = assetIsUnreferenced
            ? patternAssets.first(where: { $0.id == pattern.assetID })
            : nil
        let files = try requiredPatternFileService()
        let deletion = try PatternLibraryDeletionTransaction.begin(
            root: files.root,
            markupService: patternMarkupFileService,
            usageIDs: usagesToDelete.map(\.id),
            asset: asset,
            fileService: files
        )
        try deletion.stage()
        do {
            try persist(
                projects: projects,
                yarns: yarns,
                patternAssets: assetIsUnreferenced
                    ? patternAssets.filter { $0.id != pattern.assetID }
                    : patternAssets,
                patterns: patterns.filter { $0.id != id },
                patternUsages: patternUsages.filter { $0.patternID != id }
            )
        } catch {
            try deletion.rollback()
            throw error
        }
        try deletion.publish()
        try deletion.commit()
        if assetIsUnreferenced, let asset {
            try? patternThumbnailService.delete(assetID: asset.id)
        }
    }

    public func renamePattern(id: UUID, to name: String) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var staged = patterns
        staged[index].displayName = trimmed
        try persist(projects: projects, yarns: yarns, patterns: staged)
    }

    public func setPatternNote(id: UUID, note: String?) throws {
        try requireAccess(.editPattern)
        try ensureArchiveAvailable()
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        var staged = patterns
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        staged[index].note = trimmed.isEmpty ? nil : trimmed
        try persist(projects: projects, yarns: yarns, patterns: staged)
    }

    public func markPatternOpened(id: UUID, at date: Date = .now) throws {
        try requireAccess(.recordPatternBrowsing)
        try ensureArchiveAvailable()
        guard let index = patterns.firstIndex(where: { $0.id == id }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        var staged = patterns
        staged[index].lastOpenedAt = date
        try persist(projects: projects, yarns: yarns, patterns: staged)
    }

    public func patternAssetURL(patternID: UUID) throws -> URL {
        try ensureArchiveAvailable()
        guard let pattern = patterns.first(where: { $0.id == patternID }),
              let asset = patternAssets.first(where: { $0.id == pattern.assetID }) else {
            throw PatternLibraryMutationError.patternNotFound
        }
        return try requiredPatternFileService().assetURL(asset)
    }

    public func patternThumbnailURL(patternID: UUID) async -> URL? {
        guard loadError == nil,
              let pattern = patterns.first(where: { $0.id == patternID }),
              let asset = patternAssets.first(where: { $0.id == pattern.assetID }),
              let sourceURL = try? requiredPatternFileService().assetURL(asset)
        else { return nil }
        let service = patternThumbnailService
        return await Task.detached(priority: .utility) {
            try? service.thumbnailURL(asset: asset, sourceURL: sourceURL)
        }.value
    }

    public func patternPDFPageThumbnailURL(
        assetID: UUID,
        pageIndex: Int
    ) async -> URL? {
        guard !Task.isCancelled,
              let asset = patternAssets.first(where: { $0.id == assetID }),
              asset.kind == .pdf,
              let pageCount = asset.pageCount,
              pageIndex >= 0,
              pageIndex < pageCount,
              let sourceURL = try? requiredPatternFileService().assetURL(asset)
        else { return nil }
        let service = patternThumbnailService
        let thumbnailURL = await Task.detached(priority: .utility) { () -> URL? in
            guard !Task.isCancelled else { return nil }
            return try? service.thumbnailURL(asset: asset, sourceURL: sourceURL, pageIndex: pageIndex)
        }.value
        guard !Task.isCancelled else { return nil }
        return thumbnailURL
    }

    @discardableResult
    public func updatePatternState(
        usageID: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try updatePatternState(
            usageID: usageID,
            state: state,
            expectedDataGeneration: expectedDataGeneration,
            mutation: .editPatternReadingState
        )
    }

    @discardableResult
    public func updatePatternBrowsingState(
        usageID: UUID,
        state: PatternBrowsingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.recordPatternBrowsing)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let index = try mutableUsageIndex(usageID: usageID)
        var staged = patternUsages
        staged[index].updateBrowsingState(state)
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
        return dataGeneration
    }

    private func updatePatternState(
        usageID: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64?,
        mutation: FeatureMutation
    ) throws -> UInt64 {
        try requireAccess(mutation)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let index = try mutableUsageIndex(usageID: usageID)
        var staged = patternUsages
        staged[index].updateReadingState(state)
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
        return dataGeneration
    }

    @discardableResult
    public func savePatternPageNote(
        usageID: UUID,
        pageIndex: Int,
        text: String,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try validateExpectedDataGeneration(expectedDataGeneration)
        let index = try mutableUsageIndex(usageID: usageID)
        var staged = patternUsages
        let page = max(0, pageIndex)
        var state = staged[index].readingState
        if state.pageIndex == page {
            state.setPageNote(text)
        } else {
            let existing = state.pageStates[page]
            state.pageStates[page] = PatternPageState(
                horizontalPosition: existing?.horizontalPosition ?? 0.5,
                verticalPosition: existing?.verticalPosition ?? 0.5,
                note: text
            )
        }
        staged[index].updateReadingState(state)
        try persist(projects: projects, yarns: yarns, patternUsages: staged)
        return dataGeneration
    }

    public func loadPatternMarkup(
        usageID: UUID,
        pageIndex: Int
    ) throws -> PatternMarkupDocument {
        guard patternUsages.contains(where: { $0.id == usageID }) else {
            throw PatternLibraryMutationError.usageNotFound
        }
        return try patternMarkupFileService.load(usageID: usageID, pageIndex: pageIndex)
    }

    @discardableResult
    public func savePatternMarkup(
        _ document: PatternMarkupDocument,
        usageID: UUID,
        pageIndex: Int,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try validateExpectedDataGeneration(expectedDataGeneration)
        _ = try mutableUsageIndex(usageID: usageID)
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let snapshot = try patternMarkupFileService.snapshot(usageID: usageID, pageIndex: pageIndex)
        try patternMarkupFileService.save(document, usageID: usageID, pageIndex: pageIndex)
        do {
            // The archive write advances a durable shared revision for markup,
            // allowing concurrent readers to use the same optimistic lock.
            try persist(projects: projects, yarns: yarns, patternUsages: patternUsages)
        } catch {
            try patternMarkupFileService.restore(snapshot, usageID: usageID, pageIndex: pageIndex)
            throw error
        }
        return dataGeneration
    }
    @discardableResult
    public func savePatternPageNote(
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int,
        text: String,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try validateExpectedDataGeneration(expectedDataGeneration)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) {
            $0.savePatternPageNote(patternID: patternID, pageIndex: pageIndex, text: text)
        }
        return dataGeneration
    }
    public func updatePatternState(projectID: UUID, id: UUID, pageIndex: Int, highlightPosition: Double) throws {
        try requireAccess(.editPatternReadingState)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) { $0.updatePatternState(id: id, pageIndex: pageIndex, highlightPosition: highlightPosition) }
    }
    @discardableResult
    public func updatePatternState(
        projectID: UUID,
        id: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try updatePatternState(
            projectID: projectID,
            id: id,
            state: state,
            expectedDataGeneration: expectedDataGeneration,
            mutation: .editPatternReadingState
        )
    }

    @discardableResult
    public func updatePatternBrowsingState(
        projectID: UUID,
        id: UUID,
        state: PatternBrowsingState,
        expectedDataGeneration: UInt64? = nil
    ) throws -> UInt64 {
        try requireAccess(.recordPatternBrowsing)
        try validateExpectedDataGeneration(expectedDataGeneration)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) {
            $0.updatePatternBrowsingState(id: id, state: state)
        }
        return dataGeneration
    }

    private func updatePatternState(
        projectID: UUID,
        id: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64?,
        mutation: FeatureMutation
    ) throws -> UInt64 {
        try requireAccess(mutation)
        try validateExpectedDataGeneration(expectedDataGeneration)
        try ensureLegacyPatternReaderWriteAllowed(projectID: projectID)
        try mutate(id: projectID) { $0.updatePatternState(id: id, state: state) }
        return dataGeneration
    }
    public func patternURL(projectID: UUID, pattern: PatternDocument) -> URL {
        patternFileService?.url(projectID: projectID, pattern: pattern)
            ?? url.deletingLastPathComponent().appendingPathComponent("Patterns", isDirectory: true)
                .appendingPathComponent(projectID.uuidString, isDirectory: true)
                .appendingPathComponent(pattern.storedFilename)
    }
    public func loadPatternMarkup(
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int
    ) throws -> PatternMarkupDocument {
        try patternMarkupFileService.load(
            projectID: projectID,
            patternID: patternID,
            pageIndex: pageIndex
        )
    }
    @discardableResult
    public func savePatternMarkup(
        _ document: PatternMarkupDocument,
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int,
        expectedDataGeneration: UInt64
    ) throws -> UInt64 {
        try requireAccess(.editPatternReadingState)
        try ensureArchiveAvailable()
        try validateExpectedDataGeneration(expectedDataGeneration)
        guard let project = project(id: projectID),
              project.patterns.contains(where: { $0.id == patternID }) else {
            throw ProjectStoreError.patternNotFound
        }
        guard !project.isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        try patternMarkupFileService.save(
            document,
            projectID: projectID,
            patternID: patternID,
            pageIndex: pageIndex
        )
        return dataGeneration
    }
    public func project(id: UUID) -> StoredProject? { projects.first { $0.id == id } }
    public func addJournalEntry(
        projectID: UUID,
        photoData: Data,
        caption: String?,
        createdAt: Date = .now
    ) async throws {
        try requireAccess(.editJournal)
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        guard !project.isCompleted else {
            throw ProjectJournalMutationError.projectCompleted
        }
        try ensureArchiveAvailable()
        try Task.checkCancellation()
        activeJournalPhotoTransactions += 1
        defer {
            activeJournalPhotoTransactions -= 1
            if activeJournalPhotoTransactions == 0 {
                reconcileJournalPhotos()
            }
        }

        let entryID = UUID()
        let service = journalPhotoService
        let processingTask = Task.detached(priority: .userInitiated) {
            try service.save(data: photoData, projectID: projectID, entryID: entryID)
        }
        let files = try await withTaskCancellationHandler {
            try await processingTask.value
        } onCancel: {
            processingTask.cancel()
        }

        do {
            try Task.checkCancellation()
            let entry = try ProjectJournalEntry(
                id: entryID,
                photoFilename: files.photoFilename,
                thumbnailFilename: files.thumbnailFilename,
                caption: caption,
                createdAt: createdAt
            )
            guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
                throw ProjectJournalMutationError.entryNotFound
            }
            guard !projects[projectIndex].isCompleted else {
                throw ProjectJournalMutationError.projectCompleted
            }
            var staged = projects
            try staged[projectIndex].addJournalEntry(entry, now: createdAt)
            try persist(projects: staged, yarns: yarns)
        } catch {
            try? journalPhotoService.delete(files: files)
            throw error
        }
    }
    public func updateJournalCaption(projectID: UUID, entryID: UUID, caption: String?) throws {
        try requireAccess(.editJournal)
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        var staged = projects
        try staged[projectIndex].updateJournalCaption(id: entryID, caption: caption)
        try persist(projects: staged, yarns: yarns)
    }
    public func deleteJournalEntry(projectID: UUID, entryID: UUID) throws {
        try requireAccess(.editJournal)
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        var staged = projects
        let removed = try staged[projectIndex].deleteJournalEntry(id: entryID)
        try persist(projects: staged, yarns: yarns)
        deleteJournalPhotosIfUnreferenced([
            removed.photoFilename,
            removed.thumbnailFilename,
        ])
    }
    public func addYarn(_ yarn: StoredYarn) throws {
        try addYarn(yarn, photoData: nil)
    }
    public func addYarn(_ yarn: StoredYarn, photoData: Data?) throws {
        try requireAccess(.createYarn)
        var yarn = yarn
        var newFilename: String?
        do {
            if let photoData {
                try ensureArchiveAvailable()
                newFilename = try yarnPhotoService.save(data: photoData, yarnID: yarn.id)
                yarn.setPhotoFilename(newFilename)
            }
            try persist(projects: projects, yarns: yarns + [yarn])
        } catch {
            if let newFilename { try? yarnPhotoService.delete(filename: newFilename) }
            throw error
        }
    }
    public func updateYarn(_ yarn: StoredYarn) throws {
        try updateYarn(yarn, photoChange: .unchanged)
    }
    public func updateYarn(_ yarn: StoredYarn, photoChange: YarnPhotoChange) throws {
        try requireAccess(.editYarn)
        guard let index = yarns.firstIndex(where: { $0.id == yarn.id }) else { return }
        let oldFilename = yarns[index].photoFilename
        var updated = yarn
        var newFilename: String?
        do {
            switch photoChange {
            case .unchanged:
                updated.setPhotoFilename(oldFilename, now: updated.updatedAt)
            case let .replace(data):
                try ensureArchiveAvailable()
                newFilename = try yarnPhotoService.save(data: data, yarnID: yarn.id)
                updated.setPhotoFilename(newFilename)
            case .remove:
                updated.setPhotoFilename(nil)
            }
            var staged = yarns
            staged[index] = updated
            try persist(projects: projects, yarns: staged)
        } catch {
            if let newFilename { try? yarnPhotoService.delete(filename: newFilename) }
            throw error
        }
        if let oldFilename, oldFilename != updated.photoFilename {
            try? yarnPhotoService.delete(filename: oldFilename)
        }
    }
    public func deleteYarn(id: UUID) throws {
        try requireAccess(.deleteYarn)
        let filename = yarns.first(where: { $0.id == id })?.photoFilename
        try persist(projects: projects, yarns: yarns.filter { $0.id != id })
        if let filename { try? yarnPhotoService.delete(filename: filename) }
    }
    public func yarn(id: UUID) -> StoredYarn? { yarns.first { $0.id == id } }
    public func setYarnProjects(yarnID: UUID, projectIDs: Set<UUID>) throws {
        try requireAccess(.linkYarn)
        guard let index = yarns.firstIndex(where: { $0.id == yarnID }) else { return }
        var staged = yarns
        staged[index].setLinkedProjectIDs(projectIDs)
        try persist(projects: projects, yarns: staged)
    }
    public func photoURL(for project: StoredProject) -> URL? { project.photoFilename.map(photoService.url(filename:)) }
    public func projectCoverURL(for project: StoredProject) async -> URL? {
        if let photoURL = photoURL(for: project) {
            return photoURL
        }
        guard let usage = patternUsages
            .filter({ $0.projectID == project.id && $0.isActive })
            .sorted(by: { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.sortOrder < rhs.sortOrder
            })
            .first,
            let pattern = patterns.first(where: { $0.id == usage.patternID }),
            let asset = patternAssets.first(where: { $0.id == pattern.assetID }),
            let files = patternFileService,
            let sourceURL = try? files.assetURL(asset)
        else { return nil }
        let service = patternThumbnailService
        return await Task.detached(priority: .utility) {
            try? service.thumbnailURL(
                asset: asset,
                sourceURL: sourceURL
            )
        }.value
    }
    public func photoURL(for yarn: StoredYarn) -> URL? { yarn.photoFilename.map(yarnPhotoService.url(filename:)) }
    public func journalPhotoURL(for entry: ProjectJournalEntry) -> URL? {
        journalPhotoService.url(filename: entry.photoFilename)
    }
    public func journalThumbnailURL(for entry: ProjectJournalEntry) -> URL? {
        journalPhotoService.url(filename: entry.thumbnailFilename)
    }
    private func watchAcknowledgement(
        for commandID: UUID,
        rejection: WatchCommandRejection?,
        entitlement: EntitlementSnapshot,
        now: Date
    ) throws -> WatchCommandAcknowledgement {
        WatchCommandAcknowledgement(
            commandID: commandID,
            rejection: rejection,
            snapshot: try WatchSnapshotBuilder.make(
                projects: projects,
                entitlement: entitlement,
                locale: .current,
                generatedAt: now
            )
        )
    }
    private func mutate(id: UUID, _ body: (inout StoredProject) throws -> Void) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var staged = projects
        try body(&staged[index])
        try persist(projects: staged, yarns: yarns)
    }

    private func mutableUsageIndex(usageID: UUID) throws -> Int {
        guard let index = patternUsages.firstIndex(where: { $0.id == usageID }) else {
            throw PatternLibraryMutationError.usageNotFound
        }
        guard patternUsages[index].isActive else {
            throw PatternLibraryMutationError.usageInactive
        }
        guard let project = project(id: patternUsages[index].projectID) else {
            throw PatternLibraryMutationError.projectNotFound
        }
        guard !project.isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
        return index
    }

    private func ensureLegacyPatternReaderWriteAllowed(projectID: UUID) throws {
        guard let project = project(id: projectID) else { return }
        guard !project.isCompleted else {
            throw PatternLibraryMutationError.projectCompleted
        }
    }
    private func load() {
        do {
            try refreshPatternStorageDependencies()
        } catch {
            loadError = .archiveUnavailable
            return
        }
        do {
            try PatternLibraryMigrator().recoverInterruptedMigration(archiveURL: url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try recoverPatternDeletionArtifacts(
                    archive: ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
                )
                try recoverPatternImportArtifacts(
                    archive: ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
                )
                loadError = nil
                return
            }
            try reloadFromDiskDuringDataOperation()
        } catch let error as ProjectStoreError {
            loadError = error == .archiveUnavailable ? .archiveUnavailable : .unreadableArchive
        } catch {
            loadError = .unreadableArchive
        }
    }

    private func reloadFromDiskDuringDataOperation() throws {
        do {
            try refreshPatternStorageDependencies()
        } catch {
            loadError = .archiveUnavailable
            throw ProjectStoreError.archiveUnavailable
        }
        let decoded: (
            projects: [StoredProject],
            yarns: [StoredYarn],
            patternAssets: [PatternAsset],
            patterns: [StoredPattern],
            patternUsages: [PatternProjectUsage]
        )
        do {
            let migrator = PatternLibraryMigrator()
            try migrator.recoverInterruptedMigration(archiveURL: url)
            let initialArchive = try archiveFromDisk()
            try recoverPatternDeletionArtifacts(archive: initialArchive)
            try recoverPatternImportArtifacts(archive: initialArchive)
            if initialArchive.version < ProjectArchive.currentVersion {
                try migrator.migrateOnDisk(archiveURL: url)
            } else {
                try migrator.validateCurrentArchive(at: url)
            }
            decoded = try decode(archive: archiveFromDisk())
        } catch {
            loadError = .unreadableArchive
            throw ProjectStoreError.unreadableArchive
        }
        projects = decoded.projects
        yarns = decoded.yarns
        patternAssets = decoded.patternAssets
        patterns = decoded.patterns
        patternUsages = decoded.patternUsages
        dataGeneration &+= 1
        loadError = nil
        reconcileYarnPhotos()
        reconcileJournalPhotos()
    }

    private func recoverPatternImportArtifacts(archive: ProjectArchive) throws {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let receipts = try requiredPatternPublicationReceiptService()
        let assetJournalItems = try files.recoverImportTransactions(
            referencedAssets: archive.patternAssets,
            inbox: inbox
        )
        let receiptItems = try receipts.recover(
            patterns: archive.patterns,
            usages: archive.patternUsages,
            inbox: inbox
        )
        let publishedInboxItems = assetJournalItems.union(receiptItems)
        let report = try inbox.recover(publishedItemIDs: publishedInboxItems)
        for itemID in report.cleanedCommittedIDs.intersection(publishedInboxItems) {
            try? files.completeImportTransaction(itemID: itemID)
            try? receipts.complete(itemID: itemID)
        }
    }

    private func reconcilePublishedPatternInboxItems() async throws {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let receipts = try requiredPatternPublicationReceiptService()
        let capturedAssets = patternAssets
        let capturedPatterns = patterns
        let capturedUsages = patternUsages

        try await Task.detached(priority: .utility) {
            let assetJournalItems = try files.recoverImportTransactions(
                referencedAssets: capturedAssets,
                inbox: inbox
            )
            let receiptItems = try receipts.recover(
                patterns: capturedPatterns,
                usages: capturedUsages,
                inbox: inbox
            )
            let publishedItems = assetJournalItems.union(receiptItems)
            guard !publishedItems.isEmpty else { return }

            let report = try inbox.recover(publishedItemIDs: publishedItems)
            for itemID in report.cleanedCommittedIDs.intersection(publishedItems) {
                try? files.completeImportTransaction(itemID: itemID)
                try? receipts.complete(itemID: itemID)
            }
            let unresolvedPublication = try publishedItems.contains { itemID in
                try inbox.journalVerificationItem(id: itemID) != nil
            }
            guard !unresolvedPublication else {
                throw PatternInboxError.invalidItem
            }
        }.value
    }

    private func recoverPatternDeletionArtifacts(archive: ProjectArchive) throws {
        let files = try requiredPatternFileService()
        try PatternLibraryDeletionTransaction.recover(
            root: files.root,
            markupService: patternMarkupFileService,
            fileService: files,
            archive: archive
        )
    }

    private func archiveFromDisk() throws -> ProjectArchive {
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url))
        guard ProjectArchive.isSupported(version: archive.version) else {
            throw ProjectStoreError.unreadableArchive
        }
        return archive
    }

    private func decode(archive: ProjectArchive) throws -> (
        projects: [StoredProject],
        yarns: [StoredYarn],
        patternAssets: [PatternAsset],
        patterns: [StoredPattern],
        patternUsages: [PatternProjectUsage]
    ) {
        guard archive.version == ProjectArchive.currentVersion else {
            throw ProjectStoreError.unreadableArchive
        }
        let loadedProjects = archive.projects.sorted { $0.updatedAt > $1.updatedAt }
        let projectIDs = Set(loadedProjects.map(\.id))
        let loadedYarns = archive.yarns.map { yarn in
            var yarn = yarn
            yarn.setLinkedProjectIDs(
                yarn.linkedProjectIDs.intersection(projectIDs),
                now: yarn.updatedAt
            )
            return yarn
        }.sorted { $0.updatedAt > $1.updatedAt }
        _ = try PatternLibrarySnapshot(
            assets: archive.patternAssets,
            patterns: archive.patterns,
            usages: archive.patternUsages,
            validProjectIDs: loadedProjects.map(\.id)
        ).validated()
        return (
            loadedProjects,
            loadedYarns,
            archive.patternAssets,
            archive.patterns,
            archive.patternUsages
        )
    }
    private func publishPatternImport(
        _ prepared: PreparedPatternImport,
        duplicateResolution: PatternImportDuplicateResolution,
        access: FeatureAccessDecision
    ) throws -> PatternImportOutcome {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let receipts = try requiredPatternPublicationReceiptService()
        let coordinator = PatternImportCoordinator()
        let matchingAssets = patternAssets.filter { $0.sha256 == prepared.metadata.sha256 }
        let candidatePatterns = patterns.filter { pattern in
            matchingAssets.contains(where: { $0.id == pattern.assetID })
        }
        let pattern: StoredPattern
        let outcome: PatternImportOutcome

        if candidatePatterns.isEmpty {
            let assetID = coordinator.deterministicAssetID(for: prepared.metadata.sha256)
            let proposedAsset = PatternAsset(
                id: assetID,
                sha256: prepared.metadata.sha256,
                kind: prepared.metadata.kind,
                storedFilename: "\(assetID.uuidString).\(prepared.metadata.fileExtension)",
                byteCount: prepared.metadata.byteCount,
                pageCount: prepared.metadata.pageCount
            )
            try commitAccessIfNeeded(access, mutation: .importPattern)
            try files.beginImportTransaction(
                item: prepared.item,
                metadata: prepared.metadata,
                asset: proposedAsset
            )
            let asset = try files.installAsset(
                data: prepared.data,
                metadata: prepared.metadata,
                id: assetID,
                transactionID: prepared.item.id
            )
            pattern = StoredPattern(
                assetID: asset.id,
                displayName: displayName(for: prepared.item),
                createdAt: prepared.item.receivedAt
            )
            do {
                try receipts.begin(item: prepared.item, pattern: pattern)
                let usages = try addingUsage(
                    for: pattern.id,
                    targetProjectID: prepared.item.targetProjectID,
                    to: patternUsages
                )
                try persist(
                    projects: projects,
                    yarns: yarns,
                    patternAssets: patternAssets + [asset],
                    patterns: patterns + [pattern],
                    patternUsages: usages
                )
            } catch {
                try? receipts.complete(itemID: prepared.item.id)
                try? files.rollbackImportTransaction(itemID: prepared.item.id)
                throw error
            }
            outcome = .created(patternID: pattern.id)
        } else {
            if duplicateResolution == .createNew {
                guard let asset = matchingAssets.first else {
                    throw PatternInboxError.invalidItem
                }
                pattern = StoredPattern(
                    assetID: asset.id,
                    displayName: displayName(for: prepared.item),
                    createdAt: prepared.item.receivedAt
                )
                let usages = try addingUsage(
                    for: pattern.id,
                    targetProjectID: prepared.item.targetProjectID,
                    to: patternUsages
                )
                try commitAccessIfNeeded(access, mutation: .importPattern)
                do {
                    try receipts.begin(item: prepared.item, pattern: pattern)
                    try persist(
                        projects: projects,
                        yarns: yarns,
                        patternAssets: patternAssets,
                        patterns: patterns + [pattern],
                        patternUsages: usages
                    )
                } catch {
                    try? receipts.complete(itemID: prepared.item.id)
                    throw error
                }
                outcome = .created(patternID: pattern.id)
                try commitPublishedPatternInboxItem(
                    prepared.item,
                    inbox: inbox,
                    files: files,
                    receipts: receipts
                )
                return outcome
            }
            let selected: StoredPattern?
            if case let .existing(selectingPatternID) = duplicateResolution {
                selected = candidatePatterns.first { $0.id == selectingPatternID }
                guard selected != nil else { throw PatternInboxError.invalidSelection }
            } else if candidatePatterns.count == 1 {
                selected = candidatePatterns[0]
            } else {
                let originalName = coordinator.normalizedName(
                    URL(fileURLWithPath: prepared.item.originalFilename)
                        .deletingPathExtension()
                        .lastPathComponent
                )
                let named = candidatePatterns.filter {
                    coordinator.normalizedName($0.displayName) == originalName
                }
                selected = named.count == 1 ? named[0] : nil
            }
            guard let selected else {
                return .needsSelection(
                    itemID: prepared.item.id,
                    candidatePatternIDs: candidatePatterns.map(\.id).sorted { $0.uuidString < $1.uuidString }
                )
            }
            pattern = selected
            let usages = try addingUsage(
                for: pattern.id,
                targetProjectID: prepared.item.targetProjectID,
                to: patternUsages
            )
            try commitAccessIfNeeded(access, mutation: .importPattern)
            do {
                try receipts.begin(item: prepared.item, pattern: pattern)
                if usages != patternUsages {
                    try persist(
                        projects: projects,
                        yarns: yarns,
                        patternAssets: patternAssets,
                        patterns: patterns,
                        patternUsages: usages
                    )
                }
            } catch {
                try? receipts.complete(itemID: prepared.item.id)
                throw error
            }
            outcome = .existing(patternID: pattern.id)
        }
        try commitPublishedPatternInboxItem(
            prepared.item,
            inbox: inbox,
            files: files,
            receipts: receipts
        )
        return outcome
    }

    private func commitPublishedPatternInboxItem(
        _ item: PatternInboxItem,
        inbox: PatternInboxFileService,
        files: PatternFileService,
        receipts: PatternInboxPublicationReceiptService
    ) throws {
        // A failed staged -> committed transition remains a visible retryable
        // error. The durable item receipt lets startup finish it by exact itemID
        // without replaying the archive mutation.
        try inbox.markCommitted(item)
        do {
            try inbox.cleanupCommitted(item)
            try receipts.complete(itemID: item.id)
            try files.completeImportTransaction(itemID: item.id)
        } catch {
            // Once the sidecar is committed, cleanup is idempotent post-publication
            // work. Startup recovery keeps both journals until cleanup succeeds.
        }
    }

    private func displayName(for item: PatternInboxItem) -> String {
        let value = URL(fileURLWithPath: item.originalFilename)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Pattern" : value
    }

    private func addingUsage(
        for patternID: UUID,
        targetProjectID: UUID?,
        to existingUsages: [PatternProjectUsage]
    ) throws -> [PatternProjectUsage] {
        guard let targetProjectID else { return existingUsages }
        guard project(id: targetProjectID) != nil else { throw ProjectStoreError.patternNotFound }
        if let index = existingUsages.firstIndex(where: {
            $0.patternID == patternID && $0.projectID == targetProjectID
        }) {
            guard !existingUsages[index].isActive else { return existingUsages }
            var restored = existingUsages
            restored[index].isActive = true
            restored[index].unlinkedAt = nil
            return restored
        }
        let nextSortOrder = (existingUsages.filter { $0.projectID == targetProjectID }
            .map(\.sortOrder).max() ?? -1) + 1
        return existingUsages + [PatternProjectUsage(
            patternID: patternID,
            projectID: targetProjectID,
            sortOrder: nextSortOrder
        )]
    }

    private func persist(
        projects stagedProjects: [StoredProject],
        yarns stagedYarns: [StoredYarn],
        patternAssets stagedPatternAssets: [PatternAsset]? = nil,
        patterns stagedPatterns: [StoredPattern]? = nil,
        patternUsages stagedPatternUsages: [PatternProjectUsage]? = nil
    ) throws {
        try ensureArchiveAvailable()
        let projectIDs = Set(stagedProjects.map(\.id))
        guard stagedYarns.allSatisfy({ $0.linkedProjectIDs.isSubset(of: projectIDs) }) else {
            throw ProjectStoreError.invalidYarnProjectLinks
        }
        do {
            let sortedProjects = stagedProjects.sorted { $0.updatedAt > $1.updatedAt }
            let sortedYarns = stagedYarns.sorted { $0.updatedAt > $1.updatedAt }
            let assets = stagedPatternAssets ?? patternAssets
            let libraryPatterns = stagedPatterns ?? patterns
            let usages = stagedPatternUsages ?? patternUsages
            _ = try PatternLibrarySnapshot(
                assets: assets,
                patterns: libraryPatterns,
                usages: usages,
                validProjectIDs: sortedProjects.map(\.id)
            ).validated()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ProjectArchive(
                version: ProjectArchive.currentVersion,
                projects: sortedProjects,
                yarns: sortedYarns,
                patternAssets: assets,
                patterns: libraryPatterns,
                patternUsages: usages
            ))
            try archiveWrite(data, url)
            projects = sortedProjects
            yarns = sortedYarns
            patternAssets = assets
            patterns = libraryPatterns
            patternUsages = usages
            dataGeneration &+= 1
            reconcileYarnPhotos()
            reconcileJournalPhotos()
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.persistenceFailed
        }
    }

    private func reconcileYarnPhotos() {
        try? yarnPhotoService.reconcile(
            referencedFilenames: Set(yarns.compactMap(\.photoFilename))
        )
    }

    private func reconcileJournalPhotos() {
        guard activeJournalPhotoTransactions == 0 else { return }
        try? journalPhotoService.reconcile(
            referencedFilenames: Set(
                projects.flatMap(\.journalEntries).flatMap {
                    [$0.photoFilename, $0.thumbnailFilename]
                }
            )
        )
    }

    private func deleteJournalPhotosIfUnreferenced(_ requestedFilenames: Set<String>) {
        let deletableFilenames = ProjectJournalPhotoReferencePolicy.unreferencedFilenames(
            requestedFilenames: requestedFilenames,
            remainingProjects: projects
        )
        try? journalPhotoService.delete(filenames: deletableFilenames)
    }

    private func ensureArchiveAvailable() throws {
        guard !isDataOperationInProgress else {
            throw KnitNoteBackupError.operationInProgress
        }
        do {
            try refreshPatternStorageDependencies()
        } catch {
            loadError = .archiveUnavailable
            throw ProjectStoreError.archiveUnavailable
        }
        guard loadError == nil else {
            throw ProjectStoreError.archiveUnavailable
        }
    }

    private func refreshPatternStorageDependencies() throws {
        guard patternFileService == nil
                || patternInboxFileService == nil
                || patternPublicationReceiptService == nil else { return }
        guard let patternStorageLocationsProvider else {
            throw ProjectStoreError.archiveUnavailable
        }
        let locations = try patternStorageLocationsProvider()
        url = locations.assetRoot.deletingLastPathComponent().appendingPathComponent("projects-v1.json")
        patternFileService = PatternFileService(root: locations.assetRoot)
        patternInboxFileService = PatternInboxFileService(root: locations.inboxRoot)
        patternPublicationReceiptService = PatternInboxPublicationReceiptService(
            root: locations.assetRoot
        )
    }

    private func requiredPatternFileService() throws -> PatternFileService {
        try refreshPatternStorageDependencies()
        guard let patternFileService else { throw ProjectStoreError.archiveUnavailable }
        return patternFileService
    }

    private func requiredPatternInboxFileService() throws -> PatternInboxFileService {
        try refreshPatternStorageDependencies()
        guard let patternInboxFileService else { throw ProjectStoreError.archiveUnavailable }
        return patternInboxFileService
    }

    private func requiredPatternPublicationReceiptService() throws
        -> PatternInboxPublicationReceiptService {
        try refreshPatternStorageDependencies()
        guard let patternPublicationReceiptService else {
            throw ProjectStoreError.archiveUnavailable
        }
        return patternPublicationReceiptService
    }

    private func validateExpectedDataGeneration(_ expected: UInt64?) throws {
        try ensureArchiveAvailable()
        guard expected == nil || expected == dataGeneration else {
            throw ProjectStoreError.staleDataGeneration
        }
    }

    private func requireAccess(_ mutation: FeatureMutation) throws {
        let access = try preflightAccess(mutation)
        try commitAccessIfNeeded(access, mutation: mutation)
    }

    private func preflightAccess(_ mutation: FeatureMutation) throws -> FeatureAccessDecision {
        let decision = authorizeMutation(mutation)
        guard decision != .requiresUnlock else {
            throw ProjectStoreError.accessRestricted
        }
        return decision
    }

    private func commitAccessIfNeeded(
        _ decision: FeatureAccessDecision,
        mutation: FeatureMutation
    ) throws {
        switch decision {
        case .allow:
            return
        case .startTrial:
            try commitSuccessfulAccess(mutation)
        case .requiresUnlock:
            throw ProjectStoreError.accessRestricted
        }
    }

    private func commitSuccessfulAccess(_ mutation: FeatureMutation) throws {
        guard commitSuccessfulMutation(mutation) != .requiresUnlock else {
            throw ProjectStoreError.accessRestricted
        }
    }

    private func beginDataOperation() throws {
        guard !isDataOperationInProgress,
              activeJournalPhotoTransactions == 0,
              activePatternTransactions == 0 else {
            throw KnitNoteBackupError.operationInProgress
        }
        isDataOperationInProgress = true
    }

    private func withActivePatternTransaction<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        return try await operation()
    }

    private enum OwnedBackupArtifactKind {
        case exportPackage
        case stagedRestore

        func accepts(filename: String) -> Bool {
            switch self {
            case .exportPackage:
                let suffix = ".knitnote-backup"
                guard filename.hasSuffix(suffix) else { return false }
                return UUID(uuidString: String(filename.dropLast(suffix.count))) != nil
            case .stagedRestore:
                let prefix = "Staged-"
                guard filename.hasPrefix(prefix) else { return false }
                return UUID(uuidString: String(filename.dropFirst(prefix.count))) != nil
            }
        }
    }

    private func removeOwnedBackupArtifact(
        at artifact: URL,
        kind: OwnedBackupArtifactKind
    ) {
        let standardizedArtifact = artifact.standardizedFileURL
        guard standardizedArtifact.deletingLastPathComponent().path
                == backupService.workRoot.standardizedFileURL.path,
              kind.accepts(filename: standardizedArtifact.lastPathComponent),
              let workValues = try? backupService.workRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              workValues.isDirectory == true,
              workValues.isSymbolicLink != true,
              let artifactValues = try? standardizedArtifact.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              artifactValues.isDirectory == true,
              artifactValues.isSymbolicLink != true else {
            return
        }
        try? FileManager.default.removeItem(at: standardizedArtifact)
    }
}
