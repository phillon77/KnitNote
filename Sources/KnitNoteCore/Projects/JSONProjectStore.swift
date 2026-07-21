import Combine
import Foundation

public struct ProjectArchive: Codable, Sendable {
    public static let currentVersion = 9
    public static let minimumSupportedVersion = 1

    public static func isSupported(version: Int) -> Bool {
        (minimumSupportedVersion...currentVersion).contains(version)
    }

    public let version: Int
    public var projects: [StoredProject]
    public var yarns: [StoredYarn]

    public init(version: Int, projects: [StoredProject], yarns: [StoredYarn] = []) {
        self.version = version
        self.projects = projects
        self.yarns = yarns
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case projects
        case yarns
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        projects = try values.decode([StoredProject].self, forKey: .projects)
        yarns = try values.decodeIfPresent([StoredYarn].self, forKey: .yarns) ?? []
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
    @Published public private(set) var loadError: ProjectStoreError?
    @Published public private(set) var isDataOperationInProgress = false
    @Published public private(set) var dataGeneration: UInt64 = 0
    private let url: URL
    private let photoService: ProjectPhotoFileService
    private let yarnPhotoService: YarnPhotoFileService
    private let journalPhotoService: ProjectJournalPhotoFileService
    private let patternFileService: PatternFileService
    private let patternMarkupFileService: PatternMarkupFileService
    private let backupService: KnitNoteBackupService
    private var activeJournalPhotoTransactions = 0
    private var activePatternTransactions = 0

    public convenience init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil
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
            patternMarkupFileService: patternMarkupFileService,
            backupService: KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        )
    }

    init(
        url: URL,
        photoService: ProjectPhotoFileService? = nil,
        yarnPhotoService: YarnPhotoFileService? = nil,
        journalPhotoService: ProjectJournalPhotoFileService? = nil,
        patternFileService: PatternFileService? = nil,
        patternMarkupFileService: PatternMarkupFileService? = nil,
        backupService: KnitNoteBackupService,
        initialLoadError: ProjectStoreError? = nil
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
        self.patternFileService = patternFileService ?? PatternFileService(
            root: url.deletingLastPathComponent().appendingPathComponent("Patterns", isDirectory: true)
        )
        self.patternMarkupFileService = patternMarkupFileService ?? PatternMarkupFileService(
            root: self.patternFileService.root
        )
        self.backupService = backupService
        if let initialLoadError {
            loadError = initialLoadError
        } else {
            load()
        }
    }

    public static func live() -> JSONProjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return live(baseDirectory: base)
    }

    public static func live(baseDirectory: URL) -> JSONProjectStore {
        let liveRoot = baseDirectory.appendingPathComponent("KnitNote", isDirectory: true)
        let archiveURL = liveRoot.appendingPathComponent("projects-v1.json")
        let workRoot = baseDirectory.appendingPathComponent(
            ".KnitNote-BackupWork",
            isDirectory: true
        )
        let backupService = KnitNoteBackupService(liveRoot: liveRoot, workRoot: workRoot)
        do {
            try backupService.recoverInterruptedReplacement()
            return JSONProjectStore(url: archiveURL, backupService: backupService)
        } catch {
            return JSONProjectStore(
                url: archiveURL,
                backupService: backupService,
                initialLoadError: .unreadableArchive
            )
        }
    }
    public func retryLoad() {
        guard loadError != nil else { return }
        try? reloadFromDisk()
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
        let service = patternFileService
        let pattern = try await Task.detached(priority: .userInitiated) {
            try service.importFile(from: source, projectID: projectID)
        }.value
        do {
            try Task.checkCancellation()
            guard project(id: projectID) != nil else { throw ProjectStoreError.patternNotFound }
            try addPattern(projectID: projectID, pattern: pattern)
            return pattern
        } catch {
            try? service.delete(projectID: projectID, pattern: pattern)
            throw error
        }
    }
    public func deletePattern(projectID: UUID, id: UUID) throws {
        try ensureArchiveAvailable()
        guard let pattern = project(id: projectID)?.patterns.first(where: { $0.id == id }) else {
            return
        }
        activePatternTransactions += 1
        defer { activePatternTransactions -= 1 }
        try mutate(id: projectID) { $0.deletePattern(id: id) }
        try? patternFileService.delete(projectID: projectID, pattern: pattern)
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
        patternFileService.url(projectID: projectID, pattern: pattern)
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
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try reloadFromDiskDuringDataOperation()
        } catch {
            loadError = .unreadableArchive
        }
    }

    private func reloadFromDiskDuringDataOperation() throws {
        let decoded: (projects: [StoredProject], yarns: [StoredYarn])
        do {
            decoded = try decodeArchiveFromDisk()
        } catch {
            loadError = .unreadableArchive
            throw ProjectStoreError.unreadableArchive
        }
        projects = decoded.projects
        yarns = decoded.yarns
        dataGeneration &+= 1
        loadError = nil
        reconcileYarnPhotos()
        reconcileJournalPhotos()
    }

    private func decodeArchiveFromDisk() throws -> (
        projects: [StoredProject],
        yarns: [StoredYarn]
    ) {
        let data = try Data(contentsOf: url)
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: data)
        guard ProjectArchive.isSupported(version: archive.version) else {
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
        return (loadedProjects, loadedYarns)
    }
    private func persist(projects stagedProjects: [StoredProject], yarns stagedYarns: [StoredYarn]) throws {
        try ensureArchiveAvailable()
        let projectIDs = Set(stagedProjects.map(\.id))
        guard stagedYarns.allSatisfy({ $0.linkedProjectIDs.isSubset(of: projectIDs) }) else {
            throw ProjectStoreError.invalidYarnProjectLinks
        }
        do {
            let sortedProjects = stagedProjects.sorted { $0.updatedAt > $1.updatedAt }
            let sortedYarns = stagedYarns.sorted { $0.updatedAt > $1.updatedAt }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ProjectArchive(
                version: ProjectArchive.currentVersion,
                projects: sortedProjects,
                yarns: sortedYarns
            ))
            try data.write(to: url, options: .atomic)
            projects = sortedProjects
            yarns = sortedYarns
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
        guard loadError == nil else {
            throw ProjectStoreError.archiveUnavailable
        }
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
