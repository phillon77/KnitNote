import Combine
import Foundation

public struct ProjectArchive: Codable, Sendable {
    public static let currentVersion = 10
    public static let minimumSupportedVersion = 1

    public static func isSupported(version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
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
    private let patternMarkupFileService: PatternMarkupFileService
    private let patternThumbnailService: PatternThumbnailFileService
    private let backupService: KnitNoteBackupService
    private let archiveWrite: @Sendable (Data, URL) throws -> Void
    private let patternStorageLocationsProvider: (() throws -> PatternStorageLocations)?
    private var activeJournalPhotoTransactions = 0
    private var activePatternTransactions = 0

    public convenience init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternInboxFileService: PatternInboxFileService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        patternThumbnailService: PatternThumbnailFileService? = nil
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
            patternMarkupFileService: patternMarkupFileService,
            patternThumbnailService: patternThumbnailService,
            backupService: KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        )
    }

    init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternInboxFileService: PatternInboxFileService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        patternThumbnailService: PatternThumbnailFileService? = nil,
        backupService: KnitNoteBackupService,
        initialLoadError: ProjectStoreError? = nil,
        patternStorageLocationsProvider: (() throws -> PatternStorageLocations)? = nil,
        archiveWrite: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
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
        if let initialLoadError {
            loadError = initialLoadError
        } else {
            load()
        }
    }

    public static func live() -> JSONProjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            return try live(
                baseDirectory: base,
                locations: PatternStorageLocations.live()
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
                patternStorageLocationsProvider: { try PatternStorageLocations.live() }
            )
        }
    }

    public static func live(baseDirectory: URL) -> JSONProjectStore {
        let liveRoot = baseDirectory.appendingPathComponent("KnitNote", isDirectory: true)
        return live(
            baseDirectory: baseDirectory,
            locations: PatternStorageLocations(
                assetRoot: liveRoot.appendingPathComponent("Patterns", isDirectory: true),
                inboxRoot: liveRoot.appendingPathComponent("PatternInbox", isDirectory: true)
            )
        )
    }

    private static func live(
        baseDirectory: URL,
        locations: PatternStorageLocations
    ) -> JSONProjectStore {
        let liveRoot = locations.assetRoot.deletingLastPathComponent()
        let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        let workRoot = baseDirectory.appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        let backupService = KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        do {
            try backupService.recoverInterruptedReplacement()
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                backupService: backupService
            )
        } catch {
            return JSONProjectStore(
                url: archiveURL,
                patternFileService: PatternFileService(root: locations.assetRoot),
                patternInboxFileService: PatternInboxFileService(root: locations.inboxRoot),
                backupService: backupService,
                initialLoadError: .unreadableArchive
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
        let deletedProject = projects.first(where: { $0.id == id })
        let filename = deletedProject?.photoFilename
        let journalFilenames = Set(deletedProject?.journalEntries.flatMap {
            [$0.photoFilename, $0.thumbnailFilename]
        } ?? [])
        var stagedYarns = yarns
        let now = Date.now
        for index in stagedYarns.indices where stagedYarns[index].linkedProjectIDs.contains(id) {
            stagedYarns[index].setLinkedProjectIDs(
                stagedYarns[index].linkedProjectIDs.subtracting([id]),
                now: now
            )
        }
        try persist(projects: projects.filter { $0.id != id }, yarns: stagedYarns)
        if let filename { try? photoService.delete(filename: filename) }
        deleteJournalPhotosIfUnreferenced(journalFilenames)
        try? patternThumbnailService.deleteProject(projectID: id)
    }
    public func rename(id: UUID, to name: String) throws { try mutate(id: id) { try $0.rename(to: name) } }
    public func markCompleted(projectID: UUID) throws {
        try mutate(id: projectID) { $0.markCompleted() }
    }
    public func resumeProject(projectID: UUID) throws {
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
        try mutate(id: projectID) { $0.selectCounter(id: counterID) }
    }
    public func incrementCounter(projectID: UUID, counterID: UUID) throws {
        try mutate(id: projectID) { $0.incrementCounter(id: counterID) }
    }
    public func decrementCounter(projectID: UUID, counterID: UUID) throws {
        try mutate(id: projectID) { $0.decrementCounter(id: counterID) }
    }
    public func resetCounter(projectID: UUID, counterID: UUID) throws {
        try mutate(id: projectID) { $0.resetCounter(id: counterID) }
    }
    public func updateCounter(projectID: UUID, counterID: UUID, name: String?, value: Int) throws {
        try mutate(id: projectID) { $0.updateCounter(id: counterID, name: name, value: value) }
    }
    public func renameCounter(projectID: UUID, counterID: UUID, name: String?) throws {
        try mutate(id: projectID) { $0.renameCounter(id: counterID, to: name) }
    }
    public func applyWatchCommand(
        _ command: WatchCounterCommand,
        ledger: inout ProcessedWatchCommandLedger,
        now: Date = .now
    ) throws -> WatchCommandAcknowledgement {
        try ensureArchiveAvailable()
        if ledger.contains(command.id) {
            return try watchAcknowledgement(for: command.id, rejection: nil, now: now)
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
        return try watchAcknowledgement(for: command.id, rejection: nil, now: now)
    }
    public func saveNote(projectID: UUID, counterID: UUID, row: Int, text: String) throws {
        try mutate(id: projectID) { try $0.saveNote(counterID: counterID, row: row, text: text) }
    }
    public func deleteNote(projectID: UUID, counterID: UUID, row: Int) throws {
        try mutate(id: projectID) { $0.deleteNote(counterID: counterID, row: row) }
    }
    public func addPattern(projectID: UUID, pattern: PatternDocument) throws { try mutate(id: projectID) { $0.addPattern(pattern) } }
    public func importPattern(from source: URL, projectID: UUID) async throws -> PatternDocument {
        try ensureArchiveAvailable()
        guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        let service = try requiredPatternFileService()
        let pattern = try await Task.detached(priority: .userInitiated) {
            try service.importFile(from: source, projectID: projectID)
        }.value
        do {
            try Task.checkCancellation()
            guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
            try addPattern(projectID: projectID, pattern: pattern)
            let thumbnailService = patternThumbnailService
            let patternSourceURL = service.url(projectID: projectID, pattern: pattern)
            _ = await Task.detached(priority: .utility) {
                _ = try? thumbnailService.thumbnailURL(
                    projectID: projectID,
                    pattern: pattern,
                    sourceURL: patternSourceURL
                )
            }.value
            return pattern
        } catch {
            try? service.delete(projectID: projectID, pattern: pattern)
            throw error
        }
    }
    public func processPatternInboxItem(
        id: UUID,
        selectingPatternID: UUID? = nil
    ) async throws -> PatternImportOutcome {
        try ensureArchiveAvailable()
        let inbox = try requiredPatternInboxFileService()
        let files = try requiredPatternFileService()
        guard let item = try inbox.item(id: id) else {
            throw PatternInboxError.itemNotFound
        }
        let capturedGeneration = dataGeneration
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }

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
        return try publishPatternImport(prepared, selectingPatternID: selectingPatternID)
    }
    public func deletePattern(projectID: UUID, id: UUID) throws {
        try ensureArchiveAvailable()
        guard let pattern = project(id: projectID)?.patterns.first(where: { $0.id == id }) else {
            return
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        try mutate(id: projectID) { $0.deletePattern(id: id) }
        try? requiredPatternFileService().delete(projectID: projectID, pattern: pattern)
        try? patternThumbnailService.delete(projectID: projectID, patternID: pattern.id)
    }
    public func savePatternPageNote(
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int,
        text: String,
        expectedDataGeneration: UInt64? = nil
    ) throws {
        try validateExpectedDataGeneration(expectedDataGeneration)
        try mutate(id: projectID) {
            $0.savePatternPageNote(patternID: patternID, pageIndex: pageIndex, text: text)
        }
    }
    public func updatePatternState(projectID: UUID, id: UUID, pageIndex: Int, highlightPosition: Double) throws { try mutate(id: projectID) { $0.updatePatternState(id: id, pageIndex: pageIndex, highlightPosition: highlightPosition) } }
    public func updatePatternState(
        projectID: UUID,
        id: UUID,
        state: PatternReadingState,
        expectedDataGeneration: UInt64? = nil
    ) throws {
        try validateExpectedDataGeneration(expectedDataGeneration)
        try mutate(id: projectID) { $0.updatePatternState(id: id, state: state) }
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
    public func savePatternMarkup(
        _ document: PatternMarkupDocument,
        projectID: UUID,
        patternID: UUID,
        pageIndex: Int,
        expectedDataGeneration: UInt64
    ) throws {
        try ensureArchiveAvailable()
        try validateExpectedDataGeneration(expectedDataGeneration)
        guard project(id: projectID)?.patterns.contains(where: { $0.id == patternID }) == true else {
            throw ProjectStoreError.patternNotFound
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        try patternMarkupFileService.save(
            document,
            projectID: projectID,
            patternID: patternID,
            pageIndex: pageIndex
        )
    }
    public func project(id: UUID) -> StoredProject? { projects.first { $0.id == id } }
    public func addJournalEntry(
        projectID: UUID,
        photoData: Data,
        caption: String?,
        createdAt: Date = .now
    ) async throws {
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
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            throw ProjectJournalMutationError.entryNotFound
        }
        var staged = projects
        try staged[projectIndex].updateJournalCaption(id: entryID, caption: caption)
        try persist(projects: staged, yarns: yarns)
    }
    public func deleteJournalEntry(projectID: UUID, entryID: UUID) throws {
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
        let filename = yarns.first(where: { $0.id == id })?.photoFilename
        try persist(projects: projects, yarns: yarns.filter { $0.id != id })
        if let filename { try? yarnPhotoService.delete(filename: filename) }
    }
    public func yarn(id: UUID) -> StoredYarn? { yarns.first { $0.id == id } }
    public func setYarnProjects(yarnID: UUID, projectIDs: Set<UUID>) throws {
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
        guard let pattern = project.patterns.first else { return nil }
        guard let files = patternFileService else { return nil }
        let sourceURL = files.url(projectID: project.id, pattern: pattern)
        let service = patternThumbnailService
        return await Task.detached(priority: .utility) {
            try? service.thumbnailURL(
                projectID: project.id,
                pattern: pattern,
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
        now: Date
    ) throws -> WatchCommandAcknowledgement {
        WatchCommandAcknowledgement(
            commandID: commandID,
            rejection: rejection,
            snapshot: try WatchSnapshotBuilder.make(
                projects: projects,
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
                try recoverPatternImportArtifacts(referencedAssetIDs: [])
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
            try recoverPatternImportArtifacts(
                referencedAssetIDs: Set(initialArchive.patternAssets.map(\.id))
            )
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

    private func recoverPatternImportArtifacts(referencedAssetIDs: Set<UUID>) throws {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
        let publishedInboxItems = try files.recoverImportTransactions(
            referencedAssetIDs: referencedAssetIDs
        )
        let report = try inbox.recover(publishedItemIDs: publishedInboxItems)
        for itemID in report.cleanedCommittedIDs.intersection(publishedInboxItems) {
            try? files.completeImportTransaction(itemID: itemID)
        }
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
        selectingPatternID: UUID?
    ) throws -> PatternImportOutcome {
        let files = try requiredPatternFileService()
        let inbox = try requiredPatternInboxFileService()
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
            try files.beginImportTransaction(itemID: prepared.item.id, asset: proposedAsset)
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
                try? files.rollbackImportTransaction(itemID: prepared.item.id)
                throw error
            }
            outcome = .created(patternID: pattern.id)
        } else {
            let selected: StoredPattern?
            if let selectingPatternID {
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
            if usages != patternUsages {
                try persist(
                    projects: projects,
                    yarns: yarns,
                    patternAssets: patternAssets,
                    patterns: patterns,
                    patternUsages: usages
                )
            }
            outcome = .existing(patternID: pattern.id)
        }
        if (try? inbox.markCommitted(prepared.item)) != nil {
            try? files.completeImportTransaction(itemID: prepared.item.id)
        }
        try? inbox.cleanupCommitted(prepared.item)
        return outcome
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
        guard !existingUsages.contains(where: {
            $0.patternID == patternID && $0.projectID == targetProjectID
        }) else {
            return existingUsages
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
        guard patternFileService == nil || patternInboxFileService == nil else { return }
        guard let patternStorageLocationsProvider else {
            throw ProjectStoreError.archiveUnavailable
        }
        let locations = try patternStorageLocationsProvider()
        url = locations.assetRoot.deletingLastPathComponent().appendingPathComponent("projects-v1.json")
        patternFileService = PatternFileService(root: locations.assetRoot)
        patternInboxFileService = PatternInboxFileService(root: locations.inboxRoot)
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

    private func validateExpectedDataGeneration(_ expected: UInt64?) throws {
        try ensureArchiveAvailable()
        guard expected == nil || expected == dataGeneration else {
            throw ProjectStoreError.staleDataGeneration
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
