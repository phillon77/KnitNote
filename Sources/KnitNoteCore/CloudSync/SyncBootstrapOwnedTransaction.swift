import CryptoKit
import Darwin
import Foundation

enum SyncBootstrapOwnedBoundary: Equatable {
    case selector(SyncBootstrapOwnedSelectorPoint)
    case beforePreparingPublication, afterPreparingPublication
    case beforeTransactionRootCreation, afterTransactionRootCreation
    case afterPreparationOutput(index: Int), afterPreparedPublication
    case beforeSourceSpend, afterSourceSpend, afterLiveMove, afterStagedMove, afterInstalled
    case afterJournalOperation(index: Int), afterReceipt, afterRollbackIntent, afterFailedMove, afterOriginalRestore
    case beforeAbortPublication, afterAbortPublication
}

enum SyncBootstrapOwnedSelectorPoint: Equatable {
    case afterNextCreation, afterNextWrite, afterNextSynchronize, beforeRename, afterRename, afterSelectedSynchronize
}

/// Internal planning/preparation boundary. Construction never issues a capability;
/// App and transport activation remain gated on coherent installation/recovery.
final class SyncBootstrapOwnedTransaction {
    private let storage: SyncAccountStorage
    private let paths: SyncAccountStorage.Paths
    private let account: SyncAccountIdentity
    private let context: SyncBootstrapContext
    private let journalRelativePath: String
    private let patternFolderNameContext: PatternFolderNameContext?
    private let maximumBytes: Int
    /// The ordinary bootstrap namespace hashes this standardized spelling
    /// (not storage's descriptor-bound URL spelling, e.g. /private/var).
    private let livePath: String
    private let transactionID: UUID
    private let now: Date
    private let validateContext: (SyncBootstrapContext) throws -> Void
    private let boundary: (SyncBootstrapOwnedBoundary) throws -> Void
    private let io: SyncBootstrapOwnedIO

    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
         account: SyncAccountIdentity, context: SyncBootstrapContext,
         journalRelativePath: String = SyncBootstrapTransaction.defaultJournalRelativePath,
         patternFolderNameContext: PatternFolderNameContext? = nil,
         maximumBytes: Int = 100_000_000,
         transactionID: UUID = UUID(), now: Date = Date(),
         validateContext: @escaping (SyncBootstrapContext) throws -> Void,
         boundary: @escaping (SyncBootstrapOwnedBoundary) throws -> Void = { _ in },
         io: SyncBootstrapOwnedIO = .init()) throws {
        guard (0...100_000_000).contains(maximumBytes),
              context.accountIDHash == account.accountIDHash,
              OwnedBootstrapCodec.relative(journalRelativePath) else { throw SyncBootstrapError.corrupt }
        self.storage = storage; self.paths = paths; self.account = account; self.context = context
        self.journalRelativePath = journalRelativePath; self.patternFolderNameContext = patternFolderNameContext
        self.maximumBytes = maximumBytes; self.validateContext = validateContext
        self.livePath = paths.workingSet.standardizedFileURL.path
        self.transactionID = transactionID; self.now = now
        self.boundary = boundary
        self.io = io
    }

    func plan(_ input: SyncBootstrapOwnedInput) throws -> SyncBootstrapOwnedProgram {
        try validateContext(context)
        guard input.remote.context == context else { throw SyncBootstrapError.contextChanged }
        guard input.remote.isComplete else { throw SyncBootstrapError.incompleteFetch }
        guard input.pending?.mutations.contains(where: { $0.recordID.kind == .knittingReminder }) != true else {
            throw SyncPublicationError.pendingRepair
        }
        let result = try storage.withRecoveryOwnership(paths: paths, account: account,
            maximumBytes: maximumBytes) { access in
            let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
            let control = try observer.observe(access: access)
            // A derivative is an unresolved owner transition even when main
            // still names an absent source. Planning cannot choose either slot.
            guard control.nextBytes == nil else { throw SyncBootstrapError.sourceChanged }
            switch control.state {
            case nil, .absentSource: break
            default: throw SyncBootstrapError.sourceChanged
            }
            // A no-control legacy absence must first receive the real durable
            // source handoff. An ephemeral inventory state cannot replace it.
            if input.local == nil, control.mainBytes == nil { throw SyncBootstrapError.sourceChanged }
            let journal = FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath))
            let inventory = try SyncAccountRecoveryInventory.capture(access: access, paths: paths,
                account: account, journal: journal, archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                control: control, maximumBytes: maximumBytes)
            let original = Self.liveProofs(inventory.entries)
            let fingerprint = OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.encode(original))
            let prefix = "working-set/" + journalRelativePath
            let journalParent = OwnedBootstrapCodec.parent(prefix)
            let journalName = String(prefix.split(separator: "/").last!)
            let hidden = journalParent + "/." + journalName
            let hasJournal = inventory.entries.contains {
                $0.relativePath == prefix || $0.relativePath.hasPrefix(prefix + ".") || $0.relativePath.hasPrefix(hidden)
            }
            if let pending = input.pending {
                guard pending.sourceTreeFingerprint == fingerprint,
                      pending.mutations == inventory.packet.mutations else { throw SyncBootstrapError.sourceChanged }
            } else if hasJournal || !inventory.packet.mutations.isEmpty { throw SyncBootstrapError.sourceChanged }
            let archivePath = "working-set/projects-v1.json"
            let sourceProof: SyncBootstrapSourceProof
            if input.local != nil {
                let bytes = try read(archivePath, inventory: inventory)
                guard try SyncBootstrapTransaction.sameArchive(JSONDecoder().decode(ProjectArchive.self, from: bytes),
                    input.sourceArchive) else { throw SyncBootstrapError.sourceChanged }
                sourceProof = .archive(sha256: OwnedBootstrapCodec.hash(bytes))
            } else {
                try SyncAccountRecoveryInventory.requireAbsent(inventory.entries, archivePath: archivePath)
                guard SyncBootstrapTransaction.sameArchive(input.sourceArchive,
                    .init(version: ProjectArchive.currentVersion, projects: [])) else { throw SyncBootstrapError.sourceChanged }
                sourceProof = .missingArchive(treeSHA256: fingerprint)
            }
            let id = transactionID
            let namespace = ".KnitNote-SyncBootstrap/" + account.accountIDHash + "/"
                + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(livePath.utf8)))
            let bootstrapRoot = ".KnitNote-SyncBootstrap"
            let knownAncestors = [bootstrapRoot, bootstrapRoot + "/" + account.accountIDHash, namespace]
            for entry in inventory.entries {
                guard let first = entry.relativePath.split(separator: "/").first,
                      OwnedBootstrapCodec.alias(String(first)) == OwnedBootstrapCodec.alias(bootstrapRoot) else { continue }
                guard (OwnedBootstrapCodec.containsExactPath(knownAncestors, entry.relativePath) && entry.isDirectory)
                    || OwnedBootstrapCodec.hasExactPrefix(entry.relativePath, namespace + "/") else {
                    throw SyncBootstrapError.sourceChanged
                }
            }
            let root = namespace + "/" + id.uuidString
            guard !inventory.entries.contains(where: { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }) else {
                throw SyncBootstrapError.sourceChanged
            }
            let program = try compose(input, inventory: inventory, control: control, journal: journal,
                original: original, sourceProof: sourceProof, transactionID: id, namespace: namespace)
            try access.validate()
            guard try access.entries() == inventory.entries, try observer.observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
            return program
        }
        try validateContext(context)
        return result
    }

    private func compose(_ input: SyncBootstrapOwnedInput, inventory: SyncAccountRecoveryInventory,
        control: SyncAccountControlObservation, journal: FileSyncMutationJournal,
        original: [String: BootstrapManifestV3.FileProof], sourceProof: SyncBootstrapSourceProof,
        transactionID: UUID, namespace: String) throws -> SyncBootstrapOwnedProgram {
        typealias Builder = SyncBootstrapOwnedProgramBuilder
        var allocationIndex = 0
        func nextID() -> UUID {
            defer { allocationIndex += 1 }
            return deterministicSyncUUID(kind: .project, components: [
                "owned-bootstrap-output-allocation-v1", transactionID.uuidString, String(allocationIndex)
            ])
        }
        var builder = Builder(temporaryID: nextID)
        var initial = Builder.Tree()
        for (path, proof) in original {
            if proof.bytes == -1 { initial.directories.insert(String(path.dropLast())) }
            else {
                let value = SyncBootstrapOutputProof(byteCount: proof.bytes, sha256: proof.digest)
                initial.files[path] = .init(proof: value, origin: .live(path: "working-set/" + path, proof: value))
            }
        }
        var sources = input.local?.attachments ?? [:]
        if input.local == nil {
            for mutation in input.pending?.mutations ?? [] {
                let value = try mutation.validatedForJournalLoad()
                guard let source = value.attachmentSource else { continue }
                if let old = sources[value.recordID.uuid], old.byteCount != source.byteCount || old.contentSHA256 != source.contentSHA256 {
                    throw SyncBootstrapError.corrupt
                }
                sources[value.recordID.uuid] = source
            }
        }
        for (id, source) in input.remote.attachments {
            if let old = sources[id], old.byteCount != source.byteCount || old.contentSHA256 != source.contentSHA256 {
                throw SyncBootstrapError.corrupt
            }
            sources[id] = source
        }
        var sourceAllowance = try OwnedBootstrapCodec.encode(input.remote.records).count
        for source in sources.values {
            _ = try source.validated()
            sourceAllowance = try SyncBootstrapRecoveryBudget.add(sourceAllowance,
                SyncBootstrapRecoveryBudget.base64Bytes(Int(source.byteCount)))
        }
        guard sourceAllowance <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        let proofs = sources.mapValues { SyncBootstrapOutputProof(byteCount: $0.byteCount, sha256: $0.contentSHA256) }
        let merged = try SyncMergeEngine().merge(local: input.local?.records ?? [], remote: input.remote.records,
            pendingLocalMutations: input.pending?.mutations ?? [], counterReminderContext: input.counterReminderContext)
        let projection = try ProjectArchiveSyncMapper.projectUnvalidated(records: merged.records,
            attachmentProofs: proofs, baseArchive: input.sourceArchive)
        // Actual source metadata and encoded allowances are complete before the
        // first selected external payload read. No future role URL is read.
        var identities: [UUID: SyncRegularFileIdentity] = [:]
        for id in sources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            identities[id] = try verifySource(sources[id]!).identity
        }
        try builder.copy(initial, to: .original)
        try builder.copy(builder.trees[.original]!, to: .staged)
        let root = paths.accountRoot.appendingPathComponent(namespace).appendingPathComponent(transactionID.uuidString)
        let service = KnitNoteBackupService(liveRoot: paths.workingSet,
            workRoot: root.appendingPathComponent("ValidationMerged"), patternFolderNameContext: patternFolderNameContext)
        func frozen(_ tree: Builder.Tree, archive: Data) -> KnitNoteBackupFrozenTree {
            .init(archiveData: archive, directories: tree.directories.subtracting([""]), files: tree.files.mapValues(\.proof))
        }
        func backup(_ role: SyncBootstrapOutputRole, tree: Builder.Tree, archive: Data,
                    builder: inout Builder) throws {
            let source = frozen(tree, archive: archive)
            let package = try service.planOwnedPackage(source: source, role: role, packageID: nextID(),
                accountIDHash: account.accountIDHash,
                livePathSHA256: OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(livePath.utf8))),
                transactionID: transactionID, appVersion: "bootstrap", now: now, maximumMetadataBytes: maximumBytes,
                temporaryID: { _ in nextID() })
            let established = builder.trees[role] != nil
            let index = builder.backupPackages.count
            builder.backupPackages.append(package)
            try builder.appendHelper(package.actions, step: .backup(index: index, initial: source,
                establishedRoleRoot: established), mayConsumeRoot: role)
        }
        if input.local != nil {
            try backup(.validationOriginal, tree: builder.trees[.original]!,
                archive: read("working-set/projects-v1.json", inventory: inventory), builder: &builder)
        }
        builder.establish(.attachments)
        var durableSources: [UUID: SyncAttachmentSource] = [:]
        for id in sources.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let proof = proofs[id]!
            try builder.write(.attachments, id.uuidString, proof: proof,
                content: .copy(.attachment(versionID: id, proof: proof)))
            durableSources[id] = try .init(fileURL: root.appendingPathComponent("Attachments/" + id.uuidString),
                contentSHA256: proof.sha256, byteCount: proof.byteCount)
        }
        if let local = input.local {
            let localProjection = try ProjectArchiveSyncMapper.projectUnvalidated(records: local.records,
                attachmentProofs: proofs, baseArchive: input.sourceArchive)
            guard SyncBootstrapTransaction.sameArchive(localProjection.archive, input.sourceArchive, checkingVersion: false) else {
                throw SyncBootstrapError.sourceChanged
            }
            builder.steps.append(.validateLocal(localProjection, expected: input.sourceArchive))
        }
        builder.steps.append(.validateMaterialization(projection))
        for file in projection.files {
            guard let source = builder.trees[.attachments]?.files[file.version.versionID.uuidString] else {
                throw SyncBootstrapError.corrupt
            }
            try builder.write(.staged, file.relativePath, proof: file.proof, content: .copy(source.origin))
        }
        let archiveBytes = try OwnedBootstrapCodec.encode(projection.archive)
        try builder.write(.staged, "projects-v1.json", bytes: archiveBytes)
        var requests: [SyncDeletionCaptureRequest] = []
        try SyncBootstrapTransaction.walkIncomingDeletionRequests(remote: input.remote.records,
            records: projection.records, archive: projection.archive,
            liveAttachmentIDs: Set(projection.files.map { $0.version.versionID }), sourceProofs: proofs,
            counterReminderContext: input.counterReminderContext) { requests.append($0) }
        let staged = builder.trees[.staged]!
        let ledger: SyncDeletionFrozenLedger
        if staged.directories.contains(".sync-deletions") {
            let bytes = try read("working-set/.sync-deletions/ledger.json", inventory: inventory)
            let dirs = Set(staged.directories.filter { $0 == ".sync-deletions" || $0.hasPrefix(".sync-deletions/") }
                .map { $0 == ".sync-deletions" ? "" : String($0.dropFirst(".sync-deletions/".count)) })
            let files = Dictionary(uniqueKeysWithValues: staged.files.filter { $0.key.hasPrefix(".sync-deletions/") }
                .map { (String($0.key.dropFirst(".sync-deletions/".count)), $0.value.proof) })
            ledger = .present(manifestBytes: bytes, directories: dirs, files: files)
        } else { ledger = .absent }
        let allocations = requests.map { request in
            SyncDeletionCaptureAllocation(stagedEntryID: nextID(), liveValidationID: nextID(), restoredValidationID: nextID(),
                restoredAttachmentIDs: Dictionary(uniqueKeysWithValues: request.attachments.keys
                    .sorted(by: { $0.uuidString < $1.uuidString }).map { ($0, nextID()) }))
        }
        builder.establish(.validationMerged)
        let deletion = try SyncDeletionLedger.planIncomingCaptures(initial: ledger, requests: requests,
            allocations: allocations, temporaryID: nextID)
        let deletionActions = deletion.steps.compactMap { step -> SyncBootstrapOutputAction? in
            if case let .output(output) = step { return output.action }; return nil
        }
        try builder.appendHelper(deletionActions, step: .deletion)
        let canonicalCounters = Dictionary(uniqueKeysWithValues: projection.records.compactMap { record -> (UUID, SyncCounterReminderState)? in
            guard case let .projectCounter(state)? = record.payload.atomicDomain?.value else { return nil }
            return (record.id.uuid, state)
        })
        let checkpoint = SyncBootstrapCheckpoint(archiveSHA256: OwnedBootstrapCodec.hash(archiveBytes), records: projection.records,
            counterStates: canonicalCounters, legacyRecordIDsToDelete: merged.legacyRecordIDsToDelete)
        try builder.write(.staged, "SyncMetadata/bootstrap-canonical.json", bytes: OwnedBootstrapCodec.encode(checkpoint))
        let attachmentRecords = projection.records.filter { $0.id.kind == .attachment }
        let watchProofs = projection.records.compactMap { record -> SyncProcessedWatchCommandProof? in
            guard case let .orphanWatchCommandProof(value)? = record.payload.atomicDomain?.value else { return nil }
            return value.proof
        } + projection.counterStates.values.flatMap(\.processedCommandProofs)
        let grouped = Dictionary(grouping: watchProofs, by: \.id)
        guard grouped.values.allSatisfy({ values in values.allSatisfy { $0 == values.first } }) else { throw SyncBootstrapError.corrupt }
        let evidence = SyncAttachmentPublicationEvidence(versions: attachmentRecords.compactMap(\.payload.attachment),
            deletedVersionIDs: Set(attachmentRecords.filter { $0.deletedAt.value != nil }.map(\.id.uuid)),
            watchCommandProofs: grouped.values.compactMap(\.first), attachmentRecords: attachmentRecords)
        let selectedPaths = try SyncAttachmentPublicationEvidenceFile.ownedSelectedExistingPaths(evidence)
        let publicationTree = builder.trees[.staged]!
        let publicationInput = SyncPublicationEvidenceFrozenTree(directories: publicationTree.directories.sorted(),
            files: try publicationTree.files.keys.sorted().map { path in
                let file = publicationTree.files[path]!
                return .init(path: path, proof: file.proof,
                    bytes: selectedPaths.contains(path) ? try read("working-set/" + path, inventory: inventory) : nil)
            })
        let publication = try SyncAttachmentPublicationEvidenceFile.planSave(evidence, initial: publicationInput, temporaryID: nextID)
        try builder.appendHelper(publication.actions, step: .publication)
        try backup(.validationMerged, tree: builder.trees[.staged]!, archive: archiveBytes, builder: &builder)
        let mutations = try SyncBootstrapTransaction.ownedMutations(merged: merged, sources: durableSources, context: context)
        var mapped: [UUID: SyncAttachmentSource] = [:]
        for mutation in mutations {
            guard let source = mutation.attachmentSource, !source.isJournalStaged,
                  source.fileURL.path.hasPrefix(root.appendingPathComponent("Attachments").path + "/"),
                  let actual = sources[mutation.recordID.uuid] else { continue }
            if let old = mapped[mutation.recordID.uuid], old != actual { throw SyncBootstrapError.corrupt }
            mapped[mutation.recordID.uuid] = actual
        }
        let journalProjection = try journal.planOwnedEnqueueProjection(mutations, accountRoot: paths.accountRoot,
            inventoryEntries: inventory.entries, preflightSources: mapped, temporaryID: nextID)
        let journalProgram = journalProjection.commitProgram
        let finalStaged = builder.trees[.staged]!
        guard journalProgram.initialJournalDirectories.allSatisfy({ finalStaged.directories.contains($0) }),
              journalProgram.initialJournalFiles.allSatisfy({ path, proof in
                  finalStaged.files[path]?.proof == proof.value
              }) else { throw SyncBootstrapError.sourceChanged }
        let receipt = try OwnedBootstrapCodec.encode(SyncBootstrapReceipt(transactionID: transactionID,
            accountIDHash: account.accountIDHash, sourceProof: sourceProof))
        let receiptPath = "SyncMetadata/bootstrap-receipt.json"
        let oldReceipt = builder.trees[.staged]!.files[receiptPath]?.proof
        let commit = BootstrapManifestV3.CommitProgram(journalRelativePath: journalProgram.journalRelativePath,
            initialJournalDirectories: journalProgram.initialJournalDirectories, initialJournalFiles: journalProgram.initialJournalFiles,
            operations: journalProgram.operations + [.replace(path: receiptPath, old: oldReceipt.map(BootstrapManifestV3.OutputProof.init),
                bytes: receipt, temporaryID: nextID()), .synchronize(path: "SyncMetadata")])
        let reservation = try SyncBootstrapOutputPlanner.plan(accountIDHash: account.accountIDHash,
            livePathSHA256: OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(livePath.utf8))),
            transactionID: transactionID, actions: builder.actions, maximumMetadataBytes: maximumBytes)
        let predecessor: BootstrapManifestV3.PendingHistoryRecord?
        let activePath = namespace + "/active.json"
        if inventory.entries.contains(where: { $0.relativePath == activePath }) {
            let bytes = try read(activePath, inventory: inventory)
            let terminal = try SyncBootstrapTransaction.legacyHistorySource(bytes)
            let oldRoot = namespace + "/" + terminal.id.uuidString
            let tree = inventory.entries.filter { $0.relativePath == oldRoot || $0.relativePath.hasPrefix(oldRoot + "/") }
            let record = try BootstrapHistoryRecordV1(version: 1, accountIDHash: account.accountIDHash,
                livePath: terminal.livePath, journalPath: terminal.journalPath, transactionID: terminal.id,
                terminalEnvelope: bytes, treeEntries: tree, previous: nil).encoded(maximumBytes: maximumBytes)
            predecessor = .init(record: record, reference: .init(sha256: OwnedBootstrapCodec.hash(record),
                byteCount: Int64(record.count), recordCount: 1, chainByteCount: Int64(record.count)))
        } else { predecessor = nil }
        let budget = try SyncBootstrapRecoveryBudget.compose(inventory: inventory, control: control, context: context,
            original: original, sourceProof: sourceProof, builder: builder, reservation: reservation,
            deletion: deletion, commit: commit, mutations: mutations,
            finalPending: journalProjection.pendingMutations ?? inventory.packet.mutations,
            finalJournalFiles: journalProjection.finalJournalFiles,
            namespace: namespace, predecessor: predecessor,
            // Existing field name; this is the shared source-and-pending
            // baseline domain, including selected deletion data and FIFO.
            pendingSnapshotSHA256: SyncAccountSourceBaseline.digest(entries: inventory.entries,
                accountRoot: inventory.accountRoot, journalURL: inventory.journalURL,
                mutations: inventory.packet.mutations, selectedFiles: inventory.packet.files + inventory.deletionFiles,
                deletionLedger: inventory.deletionLedger, pendingMarkerVersions: inventory.pendingMarkerVersions),
            maximumBytes: maximumBytes)
        for (id, source) in sources {
            guard try verifySource(source).identity == identities[id] else { throw SyncBootstrapError.sourceChanged }
        }
        return .init(transactionID: transactionID, actions: builder.actions, backupPackages: builder.backupPackages,
            deletion: deletion, deletionRequests: requests, deletionAllocations: allocations,
            publication: publication, reservation: reservation,
            preparingEnvelope: budget.preparingEnvelope, maximumRecoveryEnvelopeBytes: budget.maximumRecoveryEnvelopeBytes,
            lifetimeScenarios: budget.scenarios,
            steps: builder.steps, attachmentSources: sources, attachmentIdentities: identities,
            projection: projection, mutations: mutations,
            commitProgram: commit, finalJournalFiles: journalProjection.finalJournalFiles,
            initialInventory: inventory, initialControl: control)
    }

    /// Match the ordinary cooperative sandbox ancestry rule. Keep the final
    /// parent descriptor open while comparing both named-file observations to
    /// the bounded reader's actual inode; no descriptor escapes this call.
    private func verifySource(_ source: SyncAttachmentSource) throws -> SyncRegularFileRead {
        let url = source.fileURL
        guard url.isFileURL, url.host == nil || url.host == "",
              url.query == nil, url.fragment == nil else { throw SyncBootstrapError.unsafePath }
        var path = url.deletingLastPathComponent().standardizedFileURL.path
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SyncBootstrapError.unsafePath }
        defer { close(descriptor) }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SyncBootstrapError.unsafePath }
            close(descriptor); descriptor = next
        }
        func identity() throws -> SyncRegularFileIdentity {
            var info = stat()
            guard fstatat(descriptor, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw SyncBootstrapError.unsafePath }
            return .init(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
        let before = try identity()
        let value = try SyncRegularFileReader().read(url, maximumBytes: min(maximumBytes, Int(source.byteCount)),
            expected: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
        guard value.identity == before, try identity() == before else { throw SyncBootstrapError.sourceChanged }
        return value
    }

    private static func liveProofs(_ entries: [SyncAccountRecoveryInventory.Entry]) -> [String: BootstrapManifestV3.FileProof] {
        Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix("working-set/") }.map {
            (String($0.relativePath.dropFirst("working-set/".count)) + ($0.isDirectory ? "/" : ""),
             .init(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
        })
    }

    private func read(_ path: String, inventory: SyncAccountRecoveryInventory) throws -> Data {
        guard let entry = inventory.entries.first(where: { $0.relativePath == path }), !entry.isDirectory else {
            throw SyncBootstrapError.sourceChanged
        }
        let value = try SyncRegularFileReader().read(paths.accountRoot.appendingPathComponent(path),
            maximumBytes: min(maximumBytes, Int(entry.byteCount)),
            expected: .init(byteCount: entry.byteCount, sha256: entry.sha256))
        guard value.device == entry.device, value.inode == entry.inode else { throw SyncBootstrapError.sourceChanged }
        return value.data
    }
}

extension SyncBootstrapOwnedTransaction {
    private typealias POSIX = SyncBootstrapOwnedPOSIX
    struct PreparationFailure: Error {
        let original: any Error
        let abort: any Error
    }
    private var namespace: String {
        ".KnitNote-SyncBootstrap/" + account.accountIDHash + "/"
            + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(livePath.utf8)))
    }

    func prepare(_ input: SyncBootstrapOwnedInput) throws -> SyncBootstrapPreparation {
        let program = try plan(input)
        try validateContext(context)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            guard try access.entries() == program.initialInventory.entries,
                  try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == program.initialControl else {
                throw SyncBootstrapError.sourceChanged
            }
            try boundary(.beforePreparingPublication)
            let selected = try BootstrapManifestV3.decodeEnvelope(program.preparingEnvelope, maximumBytes: maximumBytes)
            let ancestors = OwnedBootstrapCodec.parents(namespace) + [namespace]
            for path in ancestors {
                let parent = try POSIX.directory(OwnedBootstrapCodec.parent(path), from: access.accountDescriptor)
                let name = String(path.split(separator: "/").last!)
                var info = stat()
                if fstatat(parent.value, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT, mkdirat(parent.value, name, 0o700) == 0 else { throw SyncBootstrapError.unsafePath }
                    try POSIX.synchronize(parent.value)
                }
                _ = try POSIX.directory(path, from: access.accountDescriptor)
            }
            let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
            let old = try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes)
            let expected = program.initialInventory.entries.first { $0.relativePath == namespace + "/active.json" }
            guard expected.map({ old.map(POSIX.proof) == .init(byteCount: $0.byteCount, sha256: $0.sha256) }) ?? (old == nil) else {
                throw SyncBootstrapError.sourceChanged
            }
            // A first mainless derivative never receives output authority.
            guard try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == nil else {
                throw SyncBootstrapError.sourceChanged
            }
            try publish(program.preparingEnvelope, replacing: old, access: access) {
                try access.validate()
                let entries = try access.entries()
                let unchanged = entries.filter { !ancestors.contains($0.relativePath) && $0.relativePath != self.namespace + "/active-next.json" }
                let original = program.initialInventory.entries.filter { !ancestors.contains($0.relativePath) }
                guard unchanged == original,
                      try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == program.initialControl else {
                    throw SyncBootstrapError.sourceChanged
                }
                for entry in program.initialInventory.entries where ancestors.contains(entry.relativePath) {
                    guard entries.contains(entry) else { throw SyncBootstrapError.sourceChanged }
                }
            }
            let issuer = try Issuer(owner: self, access: access, selected: selected,
                exactBytes: program.preparingEnvelope, baseline: program.initialInventory.entries)
            do {
                try boundary(.afterPreparingPublication)
                try issuer.completeHistory()
                try boundary(.beforeTransactionRootCreation)
                try issuer.makeDirectory(selected.transactionRelativePath, allowExisting: false)
                try boundary(.afterTransactionRootCreation)
                try issuer.execute(program)
                let prepared = try issuer.finish(program)
                try boundary(.afterPreparedPublication)
                return prepared
            } catch {
                let first = error
                // Prepared is already durable; no preparation output/abort may
                // follow its publication, including a failing observer hook.
                guard issuer.active else { throw first }
                do { try issuer.abort() }
                catch { throw PreparationFailure(original: first, abort: error) }
                throw first
            }
        }
    }

    /// Preparing recovery freezes outputs; canonical/source-origin handoff is
    /// deliberately absent until the coherent installation/inventory checkpoint.
    func recover() throws -> SyncCanonicalBootstrapHandoff? {
        try validateContext(context)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let entries = try access.entries()
            guard entries.contains(where: { $0.relativePath == namespace + "/active.json" }) else {
                guard !entries.contains(where: { $0.relativePath == namespace || $0.relativePath.hasPrefix(namespace + "/") }) else {
                    throw SyncBootstrapError.sourceChanged
                }
                return nil
            }
            let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
            guard let bytes = try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) else {
                throw SyncBootstrapError.sourceChanged
            }
            struct Version: Decodable { let version: Int }
            let version = try JSONDecoder().decode(Version.self, from: OwnedBootstrapCodec.envelopePayload(bytes)).version
            if version != 3 {
                try recoverLegacyDerivative(bytes, entries: entries, access: access)
                return nil
            }
            let manifest = try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: maximumBytes)
            switch manifest.body {
            case .preparing:
                let issuer = try Issuer(owner: self, access: access, selected: manifest, exactBytes: bytes, baseline: nil)
                try issuer.abort()
            case .abortedPreparation:
                // A later v3 attempt needs Task3's source-origin adapter. Do
                // not report an unresolved later selector as recovered here.
                guard try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == nil else {
                    throw SyncBootstrapError.invalidPhase
                }
                try synchronizeSelected(bytes, access: access)
                try validateSource(manifest, access: access)
                _ = try validateHistory(manifest, access: access)
            default: throw SyncBootstrapError.invalidPhase
            }
            return nil
        }
    }

    private func recoverLegacyDerivative(_ bytes: Data, entries: [SyncAccountRecoveryInventory.Entry],
        access: SyncAccountStorage.RecoveryAccess) throws {
        let nextPath = namespace + "/active-next.json"
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        guard let next = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes),
              let nextEntry = entries.first(where: { $0.relativePath == nextPath }), !nextEntry.isDirectory,
              POSIX.proof(next) == .init(byteCount: nextEntry.byteCount, sha256: nextEntry.sha256) else {
            throw SyncBootstrapError.invalidPhase
        }
        let control = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
        // Legacy missing-source origin reissue belongs to the later handoff.
        guard control.mainBytes == nil, control.nextBytes == nil else { throw SyncBootstrapError.sourceChanged }
        let old = try SyncBootstrapTransaction.legacyHistorySource(bytes)
        guard case .archive = old.sourceProof else { throw SyncBootstrapError.sourceChanged }
        let filtered = entries.filter { $0.relativePath != nextPath }
        try SyncAccountRecoveryInventory.compatibilityGate(filtered)
        _ = try SyncBootstrapTransaction.terminalRecoveryEvidence(account: account, accountRoot: paths.accountRoot,
            liveRoot: paths.workingSet, journalURL: paths.workingSet.appendingPathComponent(journalRelativePath), entries: filtered)
        let root = namespace + "/" + old.id.uuidString
        let ancestors = OwnedBootstrapCodec.parents(namespace) + [namespace]
        let tree = entries.filter { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }
        for entry in entries where entry.relativePath.split(separator: "/").first.map({
            OwnedBootstrapCodec.alias(String($0)) == OwnedBootstrapCodec.alias(".KnitNote-SyncBootstrap")
        }) == true {
            guard (ancestors.contains(entry.relativePath) && entry.isDirectory)
                || entry.relativePath == namespace + "/active.json" || entry.relativePath == nextPath
                || entry.relativePath == root || entry.relativePath.hasPrefix(root + "/") else { throw SyncBootstrapError.sourceChanged }
        }
        _ = try BootstrapHistoryRecordV1(version: 1, accountIDHash: account.accountIDHash,
            livePath: old.livePath, journalPath: old.journalPath, transactionID: old.id,
            terminalEnvelope: bytes, treeEntries: tree, previous: nil).encoded(maximumBytes: maximumBytes)
        let dependencies = try SyncAccountRecoveryInventory.captureSourceDependencies(paths: paths,
            journal: FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath)),
            archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"), entries: entries, maximumBytes: maximumBytes)
        if (try? JSONSerialization.jsonObject(with: next, options: [.fragmentsAllowed])) != nil, next != bytes {
            let candidate = try BootstrapManifestV3.decodeEnvelope(next, maximumBytes: maximumBytes)
            guard case let .preparing(preparing) = candidate.body, let pending = preparing.predecessor,
                  candidate.historyHead == nil, candidate.livePath == old.livePath, candidate.journalPath == old.journalPath,
                  candidate.context.accountIDHash == account.accountIDHash, candidate.original == old.original,
                  candidate.sourceProof == old.sourceProof, preparing.sourceControlSHA256 == nil,
                  preparing.pendingSnapshotSHA256 == dependencies.baseline else { throw SyncBootstrapError.sourceChanged }
            let record = try BootstrapHistoryRecordV1.decodeEnvelope(pending.record, maximumBytes: maximumBytes)
            guard record.terminalEnvelope == bytes, SyncBootstrapHistory.exactEntries(record.treeEntries, tree),
                  !entries.contains(where: { $0.relativePath == candidate.transactionRelativePath
                    || $0.relativePath.hasPrefix(candidate.transactionRelativePath + "/") }) else { throw SyncBootstrapError.sourceChanged }
        }
        try access.validate()
        guard try access.entries() == entries,
              try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == control else {
            throw SyncBootstrapError.sourceChanged
        }
        try synchronizeSelected(bytes, access: access)
        try publish(bytes, replacing: bytes, access: access) {
            try access.validate()
            guard try access.entries().filter({ $0.relativePath != nextPath }) == filtered,
                  try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
        }
    }

    private func synchronizeSelected(_ bytes: Data, access: SyncAccountStorage.RecoveryAccess) throws {
        try access.validate()
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == bytes else {
            throw SyncBootstrapError.sourceChanged
        }
        let file = try POSIX.Descriptor(openat(directory.value, "active.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC))
        try POSIX.match(file.value, name: "active.json", parent: directory.value, directory: false)
        try POSIX.synchronize(file.value)
        for path in ([namespace] + OwnedBootstrapCodec.parents(namespace).reversed() + [""]) {
            let fd = try POSIX.directory(path, from: access.accountDescriptor)
            try POSIX.synchronize(fd.value)
        }
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == bytes else {
            throw SyncBootstrapError.sourceChanged
        }
        try access.validate()
    }

    private func publish(_ bytes: Data, replacing old: Data?, access: SyncAccountStorage.RecoveryAccess,
        revalidate: () throws -> Void) throws {
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == old else {
            throw SyncBootstrapError.sourceChanged
        }
        try revalidate()
        // An existing derivative may be replaced only by the owner of the exact
        // current main after its complete source/history checks.
        let next = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes)
        guard next == nil || old != nil else { throw SyncBootstrapError.sourceChanged }
        let flags = O_WRONLY | O_NOFOLLOW | O_CLOEXEC | (next == nil ? O_CREAT | O_EXCL : O_TRUNC)
        let file = try POSIX.Descriptor(openat(directory.value, "active-next.json", flags, 0o600))
        try POSIX.match(file.value, name: "active-next.json", parent: directory.value, directory: false)
        try boundary(.selector(.afterNextCreation))
        try POSIX.write(file.value, bytes)
        try boundary(.selector(.afterNextWrite))
        try POSIX.synchronize(file.value)
        try boundary(.selector(.afterNextSynchronize))
        try revalidate()
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == old,
              try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == bytes else {
            throw SyncBootstrapError.sourceChanged
        }
        try POSIX.match(file.value, name: "active-next.json", parent: directory.value, directory: false)
        try boundary(.selector(.beforeRename))
        guard renameat(directory.value, "active-next.json", directory.value, "active.json") == 0 else {
            throw SyncAccountStorageError.unavailable
        }
        try boundary(.selector(.afterRename))
        // First establish the rename's namespace/ancestry durability, then
        // perform the exact selected readback and synchronization again.
        for path in ([namespace] + OwnedBootstrapCodec.parents(namespace).reversed() + [""]) {
            let fd = try POSIX.directory(path, from: access.accountDescriptor)
            try POSIX.synchronize(fd.value)
        }
        try synchronizeSelected(bytes, access: access)
        try boundary(.selector(.afterSelectedSynchronize))
    }

    private func validateHistory(_ manifest: BootstrapManifestV3, access: SyncAccountStorage.RecoveryAccess) throws -> [SyncAccountRecoveryInventory.Entry] {
        let entries = try access.entries()
        var incompletePendingPath: String?
        let pending: BootstrapManifestV3.PendingHistoryRecord?
        if case let .preparing(body) = manifest.body { pending = body.predecessor } else { pending = nil }
        let records = try entries.filter { !$0.isDirectory && $0.relativePath.hasPrefix(namespace + "/History/") }.compactMap { entry -> SyncBootstrapHistory.SuppliedRecord? in
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(entry.relativePath), from: access.accountDescriptor)
            let bytes = try POSIX.read(String(entry.relativePath.split(separator: "/").last!), parent: parent.value, maximumBytes: maximumBytes)
            guard let bytes else { throw SyncBootstrapError.sourceChanged }
            if let pending, entry.relativePath == SyncBootstrapHistory.recordPath(namespace: namespace, hash: pending.reference.sha256),
               bytes != pending.record {
                guard pending.record.starts(with: bytes), POSIX.proof(bytes) == .init(byteCount: entry.byteCount, sha256: entry.sha256) else {
                    throw SyncBootstrapError.sourceChanged
                }
                // Only this declared exact-prefix derivative is represented by
                // its durable preparing bytes while validating the old chain.
                incompletePendingPath = entry.relativePath
                return nil
            }
            return SyncBootstrapHistory.SuppliedRecord(relativePath: entry.relativePath, bytes: bytes)
        }
        _ = try SyncBootstrapHistory.validate(current: manifest, records: records,
            accountEntries: entries.filter { $0.relativePath != incompletePendingPath }, maximumBytes: maximumBytes)
        return entries
    }

    private func validateSource(_ manifest: BootstrapManifestV3, access: SyncAccountStorage.RecoveryAccess) throws {
        guard manifest.context.accountIDHash == account.accountIDHash,
              manifest.livePath == livePath, manifest.journalPath == journalRelativePath else { throw SyncBootstrapError.sourceChanged }
        let binding: (Data?, Data)
        switch manifest.body {
        case let .preparing(value): binding = (value.sourceControlSHA256, value.pendingSnapshotSHA256)
        case let .abortedPreparation(value): binding = (value.sourceControlSHA256, value.pendingSnapshotSHA256)
        default: throw SyncBootstrapError.invalidPhase
        }
        let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
        let control = try observer.observe(access: access)
        guard control.nextBytes == nil, control.mainBytes.map(OwnedBootstrapCodec.hash) == binding.0 else {
            throw SyncBootstrapError.sourceChanged
        }
        let entries = try access.entries()
        let bootstrapRoot = ".KnitNote-SyncBootstrap"
        let ancestors = OwnedBootstrapCodec.parents(namespace) + [namespace]
        for entry in entries where entry.relativePath.split(separator: "/").first.map({
            OwnedBootstrapCodec.alias(String($0)) == OwnedBootstrapCodec.alias(bootstrapRoot)
        }) == true {
            guard (OwnedBootstrapCodec.containsExactPath(ancestors, entry.relativePath) && entry.isDirectory)
                || OwnedBootstrapCodec.hasExactPrefix(entry.relativePath, namespace + "/") else {
                throw SyncBootstrapError.sourceChanged
            }
        }
        // The full v3 namespace is checked separately, so only its declared
        // output entries bypass ordinary unresolved-temporary classification.
        try SyncAccountRecoveryInventory.compatibilityGate(entries.filter { !$0.relativePath.hasPrefix(namespace + "/") })
        guard Self.liveProofs(entries) == manifest.original else { throw SyncBootstrapError.sourceChanged }
        let dependencies = try SyncAccountRecoveryInventory.captureSourceDependencies(paths: paths,
            journal: FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath)),
            archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"), entries: entries, maximumBytes: maximumBytes)
        guard dependencies.baseline == binding.1 else { throw SyncBootstrapError.sourceChanged }
        switch (manifest.sourceProof, control.state) {
        case (.archive(let hash), nil):
            guard entries.first(where: { $0.relativePath == "working-set/projects-v1.json" })?.sha256 == hash else {
                throw SyncBootstrapError.sourceChanged
            }
        case (.missingArchive, .absentSource(let source)):
            let root = try POSIX.identity(access.accountDescriptor)
            guard source.accountIDHash == account.accountIDHash, source.accountRoot == paths.accountRoot,
                  source.accountDevice == root.device, source.accountInode == root.inode,
                  source.archiveURL == paths.workingSet.appendingPathComponent("projects-v1.json"),
                  source.journalURL == paths.workingSet.appendingPathComponent(journalRelativePath),
                  source.baselineSHA256 == dependencies.baseline else { throw SyncBootstrapError.sourceChanged }
            try SyncAccountRecoveryInventory.requireAbsent(entries, archivePath: "working-set/projects-v1.json")
        default: throw SyncBootstrapError.sourceChanged
        }
        try access.validate()
        guard try access.entries() == entries, try observer.observe(access: access) == control else { throw SyncBootstrapError.sourceChanged }
    }

    /// Only exact synchronized preparing readback can construct this scoped
    /// executor. Neither the value nor its descriptors leave storage ownership.
    private final class Issuer {
        let owner: SyncBootstrapOwnedTransaction
        let access: SyncAccountStorage.RecoveryAccess
        let manifest: BootstrapManifestV3
        let bytes: Data
        let baseline: [SyncAccountRecoveryInventory.Entry]?
        var directories: [String: BootstrapManifestV3.InstallRootIdentity] = [:]
        var immutableHistory: [String: SyncAccountRecoveryInventory.Entry] = [:]
        var locks: [POSIX.Descriptor] = []
        var active = true
        var outputIndex = 0

        init(owner: SyncBootstrapOwnedTransaction, access: SyncAccountStorage.RecoveryAccess,
            selected: BootstrapManifestV3, exactBytes: Data, baseline: [SyncAccountRecoveryInventory.Entry]?) throws {
            guard case .preparing = selected.body,
                  try BootstrapManifestV3.decodeEnvelope(exactBytes) == selected else { throw SyncBootstrapError.invalidPhase }
            try owner.synchronizeSelected(exactBytes, access: access)
            self.owner = owner; self.access = access; manifest = selected; bytes = exactBytes; self.baseline = baseline
            try owner.validateSource(selected, access: access)
            for entry in try access.entries() {
                if entry.isDirectory { directories[entry.relativePath] = .init(device: entry.device, inode: entry.inode) }
                else if entry.relativePath.hasPrefix(owner.namespace + "/History/") {
                    if case let .preparing(preparing) = selected.body, let pending = preparing.predecessor,
                       entry.relativePath == SyncBootstrapHistory.recordPath(namespace: owner.namespace, hash: pending.reference.sha256),
                       entry.sha256 != pending.reference.sha256 { continue }
                    immutableHistory[entry.relativePath] = entry
                }
            }
        }
        func validate() throws {
            guard active else { throw SyncBootstrapError.invalidPhase }
            try owner.validateSource(manifest, access: access)
            let entries = try access.entries()
            if let baseline {
                let prefix = owner.namespace + "/"
                let ancestors = OwnedBootstrapCodec.parents(owner.namespace) + [owner.namespace]
                guard entries.filter({ !$0.relativePath.hasPrefix(prefix) && !ancestors.contains($0.relativePath) })
                    == baseline.filter({ !$0.relativePath.hasPrefix(prefix) && !ancestors.contains($0.relativePath) }) else {
                    throw SyncBootstrapError.sourceChanged
                }
            }
            for (path, identity) in directories {
                guard let entry = entries.first(where: { $0.relativePath == path }), entry.isDirectory,
                      entry.device == identity.device, entry.inode == identity.inode else { throw SyncBootstrapError.sourceChanged }
            }
            for (path, expected) in immutableHistory {
                guard entries.first(where: { $0.relativePath == path }) == expected else { throw SyncBootstrapError.sourceChanged }
            }
            let fd = try POSIX.directory(owner.namespace, from: access.accountDescriptor)
            guard try POSIX.read("active.json", parent: fd.value, maximumBytes: owner.maximumBytes) == bytes else {
                throw SyncBootstrapError.sourceChanged
            }
            if let next = try POSIX.read("active-next.json", parent: fd.value, maximumBytes: owner.maximumBytes),
               next != bytes, (try? JSONSerialization.jsonObject(with: next, options: [.fragmentsAllowed])) != nil {
                let candidate = try BootstrapManifestV3.decodeEnvelope(next, maximumBytes: owner.maximumBytes)
                guard case let .preparing(preparing) = manifest.body,
                      candidate.id == manifest.id, candidate.context == manifest.context,
                      candidate.livePath == manifest.livePath, candidate.journalPath == manifest.journalPath,
                      candidate.original == manifest.original, candidate.sourceProof == manifest.sourceProof,
                      candidate.historyHead == (preparing.predecessor?.reference ?? manifest.historyHead) else {
                    throw SyncBootstrapError.sourceChanged
                }
                let digest = OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.envelopePayload(bytes))
                switch candidate.body {
                case let .abortedPreparation(value):
                    let actual = entries.filter { $0.relativePath == manifest.transactionRelativePath || $0.relativePath.hasPrefix(manifest.transactionRelativePath + "/") }
                    guard value.preparationSHA256 == digest, value.sourceControlSHA256 == preparing.sourceControlSHA256,
                          value.pendingSnapshotSHA256 == preparing.pendingSnapshotSHA256,
                          value.outputAllocation == preparing.outputAllocation,
                          SyncBootstrapHistory.exactEntries(actual, value.frozenOutputEntries) else { throw SyncBootstrapError.sourceChanged }
                case let .prepared(value):
                    let prefix = rolePath(.staged) + "/"
                    let installed = Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix(prefix) }.map {
                        (String($0.relativePath.dropFirst(prefix.count)) + ($0.isDirectory ? "/" : ""),
                         BootstrapManifestV3.FileProof(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
                    })
                    guard value.preparationSHA256 == digest, value.installed == installed,
                          value.originalLiveRoot == directories["working-set"], value.stagedRoot == directories[rolePath(.staged)] else {
                        throw SyncBootstrapError.sourceChanged
                    }
                default: throw SyncBootstrapError.invalidPhase
                }
            }
            _ = try owner.validateHistory(manifest, access: access)
        }
        func makeDirectory(_ path: String, allowExisting: Bool) throws {
            try validate()
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(path), from: access.accountDescriptor)
            let name = String(path.split(separator: "/").last!)
            if mkdirat(parent.value, name, 0o700) != 0 {
                guard allowExisting, errno == EEXIST, directories[path] != nil else { throw SyncBootstrapError.unsafePath }
            }
            let fd = try POSIX.directory(path, from: access.accountDescriptor)
            let identity = try POSIX.identity(fd.value)
            if let old = directories[path] { guard old == identity else { throw SyncBootstrapError.sourceChanged } }
            directories[path] = identity
            try owner.io.synchronize(fd.value); try owner.io.synchronize(parent.value)
            try validate()
        }
        func completeHistory() throws {
            guard case let .preparing(preparing) = manifest.body else { throw SyncBootstrapError.invalidPhase }
            try validate()
            if let pending = preparing.predecessor {
                let path = SyncBootstrapHistory.recordPath(namespace: owner.namespace, hash: pending.reference.sha256)
                let directoryPath = OwnedBootstrapCodec.parent(path)
                try makeDirectory(directoryPath, allowExisting: true)
                let directory = try POSIX.directory(directoryPath, from: access.accountDescriptor)
                let name = String(path.split(separator: "/").last!)
                let existing = try POSIX.read(name, parent: directory.value, maximumBytes: owner.maximumBytes)
                guard existing.map({ pending.record.starts(with: $0) }) ?? true else { throw SyncBootstrapError.sourceChanged }
                let fd = try POSIX.Descriptor(openat(directory.value, name,
                    O_WRONLY | O_NOFOLLOW | O_CLOEXEC | (existing == nil ? O_CREAT | O_EXCL : 0), 0o600))
                try POSIX.match(fd.value, name: name, parent: directory.value, directory: false)
                if existing != pending.record {
                    guard lseek(fd.value, off_t(existing?.count ?? 0), SEEK_SET) >= 0 else { throw SyncAccountStorageError.unavailable }
                    try owner.io.write(fd.value, Data(pending.record.dropFirst(existing?.count ?? 0)))
                }
                try owner.io.synchronize(fd.value); try owner.io.synchronize(directory.value)
                guard try POSIX.read(name, parent: directory.value, maximumBytes: owner.maximumBytes) == pending.record else {
                    throw SyncBootstrapError.sourceChanged
                }
                guard let entry = try access.entries().first(where: { $0.relativePath == path }) else { throw SyncBootstrapError.sourceChanged }
                immutableHistory[path] = entry
            }
            _ = try owner.validateHistory(manifest, access: access)
        }
        func abort() throws {
            // No async writer exists; release helper locks before freezing.
            locks.removeAll()
            try validate()
            try completeHistory()
            let entries = try owner.validateHistory(manifest, access: access)
            guard case let .preparing(preparing) = manifest.body else { throw SyncBootstrapError.invalidPhase }
            let frozen = entries.filter { $0.relativePath == manifest.transactionRelativePath || $0.relativePath.hasPrefix(manifest.transactionRelativePath + "/") }
            let terminal = BootstrapManifestV3(id: manifest.id, context: manifest.context,
                livePath: manifest.livePath, journalPath: manifest.journalPath, sourceProof: manifest.sourceProof,
                original: manifest.original, historyHead: preparing.predecessor?.reference ?? manifest.historyHead,
                body: .abortedPreparation(.init(preparationSHA256: OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.envelopePayload(bytes)),
                    sourceControlSHA256: preparing.sourceControlSHA256, pendingSnapshotSHA256: preparing.pendingSnapshotSHA256,
                    outputAllocation: preparing.outputAllocation, frozenOutputEntries: frozen)))
            let encoded = try terminal.encoded(maximumBytes: owner.maximumBytes)
            try synchronizeFrozenOutputs(frozen, observed: entries)
            try validate()
            guard try access.entries() == entries else { throw SyncBootstrapError.sourceChanged }
            try owner.boundary(.beforeAbortPublication)
            try owner.publish(encoded, replacing: bytes, access: access) {
                try self.validate()
                let current = try self.access.entries().filter { $0.relativePath != self.owner.namespace + "/active-next.json" }
                guard current == entries.filter({ $0.relativePath != self.owner.namespace + "/active-next.json" }) else {
                    throw SyncBootstrapError.sourceChanged
                }
            }
            active = false
            try owner.boundary(.afterAbortPublication)
        }

        /// A terminal selector may retain a failed write that never reached its
        /// normal file barrier. Bind and synchronize that exact frozen tree
        /// before publishing it, including the parent that names the UUID root.
        private func synchronizeFrozenOutputs(_ frozen: [SyncAccountRecoveryInventory.Entry],
                                              observed: [SyncAccountRecoveryInventory.Entry]) throws {
            func synchronize(_ entry: SyncAccountRecoveryInventory.Entry) throws {
                let parentPath = OwnedBootstrapCodec.parent(entry.relativePath)
                guard let expectedParent = observed.first(where: { $0.relativePath == parentPath }),
                      expectedParent.isDirectory else { throw SyncBootstrapError.sourceChanged }
                let parent = try POSIX.directory(parentPath, from: access.accountDescriptor)
                let parentIdentity = try POSIX.identity(parent.value)
                guard parentIdentity.device == expectedParent.device, parentIdentity.inode == expectedParent.inode else {
                    throw SyncBootstrapError.sourceChanged
                }
                let name = String(entry.relativePath.split(separator: "/").last!)
                let fd = try POSIX.Descriptor(openat(parent.value, name,
                    O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (entry.isDirectory ? O_DIRECTORY : 0)))
                func recheck() throws {
                    try POSIX.match(fd.value, name: name, parent: parent.value, directory: entry.isDirectory)
                    var status = stat()
                    guard fstat(fd.value, &status) == 0,
                          UInt64(status.st_dev) == entry.device, UInt64(status.st_ino) == entry.inode else {
                        throw SyncBootstrapError.sourceChanged
                    }
                    if !entry.isDirectory {
                        guard status.st_size == entry.byteCount,
                              let bytes = try POSIX.read(name, parent: parent.value, maximumBytes: owner.maximumBytes),
                              POSIX.proof(bytes) == .init(byteCount: entry.byteCount, sha256: entry.sha256) else {
                            throw SyncBootstrapError.sourceChanged
                        }
                        try POSIX.match(fd.value, name: name, parent: parent.value, directory: false)
                    }
                }
                try recheck()
                try owner.io.synchronize(fd.value)
                try recheck()
            }
            // The complete bounded inventory and terminal codec have already
            // validated these entries. No missing root or child is created.
            for entry in frozen.filter({ !$0.isDirectory }) { try synchronize(entry) }
            let directories = frozen.filter(\.isDirectory).sorted {
                let left = $0.relativePath.split(separator: "/").count
                let right = $1.relativePath.split(separator: "/").count
                return left == right ? $0.relativePath < $1.relativePath : left > right
            }
            for entry in directories { try synchronize(entry) }
            guard let parent = observed.first(where: { $0.relativePath == owner.namespace }), parent.isDirectory else {
                throw SyncBootstrapError.sourceChanged
            }
            try synchronize(parent)
        }

        func rolePath(_ role: SyncBootstrapOutputRole, _ path: String = "") -> String {
            manifest.transactionRelativePath + "/" + role.rawValue + (path.isEmpty ? "" : "/" + path)
        }
        func readPath(_ path: String, proof: SyncBootstrapOutputProof? = nil) throws -> Data {
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(path), from: access.accountDescriptor)
            guard let bytes = try POSIX.read(String(path.split(separator: "/").last!), parent: parent.value,
                maximumBytes: owner.maximumBytes), proof.map({ POSIX.proof(bytes) == $0 }) ?? true else {
                throw SyncBootstrapError.sourceChanged
            }
            return bytes
        }
        func outputLocation(_ action: SyncBootstrapOutputAction) -> String {
            switch action {
            case let .directory(role, path), let .write(role, path, _, _),
                 let .reuseExact(role, path, _), let .lock(role, path, _): return rolePath(role, path)
            }
        }
        func output(_ action: SyncBootstrapOutputAction, bytes: Data?, consumeRoot: Bool = false) throws {
            try validate()
            let path = outputLocation(action)
            if consumeRoot {
                guard case let .directory(role, relative) = action, relative.isEmpty,
                      path == rolePath(role), let expected = directories[path] else { throw SyncBootstrapError.unsafePath }
                let existing = try POSIX.directory(path, from: access.accountDescriptor)
                guard try POSIX.identity(existing.value) == expected else { throw SyncBootstrapError.sourceChanged }
                // Composer already emitted this role's sole create action.
                // The helper declaration is an exact existing-root precondition.
                return
            }
            switch action {
            case .directory:
                try makeDirectory(path, allowExisting: consumeRoot)
            case let .write(_, _, mode, temporaryID):
                let new: SyncBootstrapOutputProof, old: SyncBootstrapOutputProof?
                switch mode {
                case let .create(proof): new = proof; old = nil
                case let .replace(expected, proof): new = proof; old = expected
                }
                guard let bytes, POSIX.proof(bytes) == new else { throw SyncBootstrapError.sourceChanged }
                let parentPath = OwnedBootstrapCodec.parent(path)
                let parent = try POSIX.directory(parentPath, from: access.accountDescriptor)
                guard try POSIX.identity(parent.value) == directories[parentPath] else { throw SyncBootstrapError.sourceChanged }
                let name = String(path.split(separator: "/").last!)
                func compareTarget() throws {
                    let current = try POSIX.read(name, parent: parent.value, maximumBytes: owner.maximumBytes)
                    guard current.map(POSIX.proof) == old else { throw SyncBootstrapError.sourceChanged }
                }
                try compareTarget()
                let temporary = "." + name + "." + temporaryID.uuidString + ".tmp"
                let fd = try POSIX.Descriptor(openat(parent.value, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
                try POSIX.match(fd.value, name: temporary, parent: parent.value, directory: false)
                try owner.io.write(fd.value, bytes)
                guard try POSIX.read(temporary, parent: parent.value, maximumBytes: owner.maximumBytes) == bytes else {
                    throw SyncBootstrapError.sourceChanged
                }
                try owner.io.synchronize(fd.value)
                try validate(); try compareTarget()
                try POSIX.match(fd.value, name: temporary, parent: parent.value, directory: false)
                guard renameat(parent.value, temporary, parent.value, name) == 0 else { throw SyncAccountStorageError.unavailable }
                try owner.io.synchronize(parent.value)
                guard POSIX.proof(try readPath(path)) == new else { throw SyncBootstrapError.sourceChanged }
            case let .reuseExact(_, _, proof):
                _ = try readPath(path, proof: proof)
                let parent = try POSIX.directory(OwnedBootstrapCodec.parent(path), from: access.accountDescriptor)
                try owner.io.synchronize(parent.value)
            case let .lock(_, _, expected):
                let parent = try POSIX.directory(OwnedBootstrapCodec.parent(path), from: access.accountDescriptor)
                let name = String(path.split(separator: "/").last!)
                guard try POSIX.read(name, parent: parent.value, maximumBytes: owner.maximumBytes).map(POSIX.proof) == expected else {
                    throw SyncBootstrapError.sourceChanged
                }
                let fd = try POSIX.Descriptor(openat(parent.value, name,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC | (expected == nil ? O_CREAT | O_EXCL : 0), 0o600))
                try POSIX.match(fd.value, name: name, parent: parent.value, directory: false)
                guard flock(fd.value, LOCK_EX | LOCK_NB) == 0 else { throw SyncAccountStorageError.unavailable }
                locks.append(fd)
                try owner.io.synchronize(fd.value); try owner.io.synchronize(parent.value)
            }
            try validate()
            try owner.boundary(.afterPreparationOutput(index: outputIndex)); outputIndex += 1
        }
        func frozenTree(_ role: SyncBootstrapOutputRole) throws -> KnitNoteBackupFrozenTree {
            let prefix = rolePath(role) + "/"
            let selected = try access.entries().filter { $0.relativePath.hasPrefix(prefix) }
            return .init(archiveData: try readPath(prefix + "projects-v1.json"),
                directories: Set(selected.filter(\.isDirectory).map { String($0.relativePath.dropFirst(prefix.count)) }),
                files: Dictionary(uniqueKeysWithValues: selected.filter { !$0.isDirectory }.map {
                    (String($0.relativePath.dropFirst(prefix.count)), .init(byteCount: $0.byteCount, sha256: $0.sha256))
                }))
        }
        func stagedSources(_ program: SyncBootstrapOwnedProgram) throws -> [UUID: SyncAttachmentSource] {
            var result: [UUID: SyncAttachmentSource] = [:]
            for (id, source) in program.attachmentSources {
                let path = rolePath(.attachments, id.uuidString)
                _ = try readPath(path, proof: .init(byteCount: source.byteCount, sha256: source.contentSHA256))
                result[id] = .init(fileURL: owner.paths.accountRoot.appendingPathComponent(path),
                    contentSHA256: source.contentSHA256, byteCount: source.byteCount, isJournalStaged: true)
            }
            return result
        }
        func execute(_ program: SyncBootstrapOwnedProgram) throws {
            var outputs: [Int: String] = [:]
            var helpers: [Int: [Int: String]] = [:]
            func sourceBytes(_ source: SyncBootstrapOwnedProgram.Source) throws -> Data {
                switch source {
                case let .live(path, proof): return try readPath(path, proof: proof)
                case let .attachment(id, proof):
                    guard let source = program.attachmentSources[id] else { throw SyncBootstrapError.corrupt }
                    let value = try owner.verifySource(source)
                    guard value.identity == program.attachmentIdentities[id], POSIX.proof(value.data) == proof else { throw SyncBootstrapError.sourceChanged }
                    return value.data
                case let .output(index, proof):
                    guard let path = outputs[index] else { throw SyncBootstrapError.corrupt }; return try readPath(path, proof: proof)
                case let .helperOutput(programIndex, actionIndex, proof):
                    guard let path = helpers[programIndex]?[actionIndex] else { throw SyncBootstrapError.corrupt }; return try readPath(path, proof: proof)
                }
            }
            for (index, step) in program.steps.enumerated() {
                try validate()
                switch step {
                case let .output(value):
                    let bytes: Data?
                    switch value.content {
                    case let .bytes(value): bytes = value
                    case let .copy(source): bytes = try sourceBytes(source)
                    case nil: bytes = nil
                    }
                    try output(value.action, bytes: bytes)
                    outputs[index] = outputLocation(value.action)
                case let .backup(packageIndex, initial, established):
                    let package = program.backupPackages[packageIndex]
                    let role: SyncBootstrapOutputRole = package.role == .validationOriginal ? .original : .staged
                    let actual = try frozenTree(role)
                    guard actual == initial else { throw SyncBootstrapError.sourceChanged }
                    let service = KnitNoteBackupService(liveRoot: owner.paths.accountRoot.appendingPathComponent(rolePath(role)),
                        workRoot: owner.paths.accountRoot.appendingPathComponent(rolePath(package.role)),
                        patternFolderNameContext: owner.patternFolderNameContext)
                    try service.validateFrozenPackageSource(package, source: actual)
                    var locations: [Int: String] = [:]
                    for (actionIndex, action) in package.actions.enumerated() {
                        let bytes: Data?
                        if case let .write(_, path, _, _) = action {
                            let prefix = package.packageID.uuidString + ".knitnote-backup/Data/"
                            if path == package.packageID.uuidString + ".knitnote-backup/manifest.json" { bytes = package.manifestData }
                            else {
                                guard path.hasPrefix(prefix) else { throw SyncBootstrapError.corrupt }
                                let relative = String(path.dropFirst(prefix.count))
                                guard let proof = package.sourceFiles[relative] else { throw SyncBootstrapError.corrupt }
                                bytes = try readPath(rolePath(role, relative), proof: proof)
                            }
                        } else { bytes = nil }
                        try output(action, bytes: bytes, consumeRoot: established && actionIndex == 0)
                        locations[actionIndex] = outputLocation(action)
                    }
                    try service.validateFrozenPackageSource(package, source: frozenTree(role))
                    _ = try service.inspectPackage(at: owner.paths.accountRoot.appendingPathComponent(
                        rolePath(package.role, package.packageID.uuidString + ".knitnote-backup")))
                    helpers[index] = locations
                case let .validateLocal(projection, expected):
                    let actual = try ProjectArchiveSyncMapper.materialize(records: projection.records,
                        attachments: stagedSources(program), baseArchive: expected)
                    guard SyncBootstrapTransaction.sameArchive(actual.archive, expected, checkingVersion: false) else { throw SyncBootstrapError.sourceChanged }
                case let .validateMaterialization(projection):
                    let base: ProjectArchive
                    switch manifest.sourceProof {
                    case .archive:
                        guard let original = program.steps.compactMap({ step -> ProjectArchive? in
                            if case let .validateLocal(_, expected) = step { return expected }; return nil
                        }).first else { throw SyncBootstrapError.corrupt }
                        base = original
                    case .missingArchive: base = .init(version: ProjectArchive.currentVersion, projects: [])
                    }
                    let actual = try ProjectArchiveSyncMapper.materialize(records: projection.records,
                        attachments: stagedSources(program), baseArchive: base)
                    guard SyncBootstrapTransaction.sameArchive(actual.archive, projection.archive), actual.records == projection.records,
                          actual.files.map(\.relativePath) == projection.files.map(\.relativePath) else { throw SyncBootstrapError.sourceChanged }
                case .deletion:
                    var locations: [Int: String] = [:], actions: [Int: String] = [:]
                    var actionIndex = 0
                    for (localIndex, step) in program.deletion.steps.enumerated() {
                        switch step {
                        case let .output(value):
                            let bytes: Data?
                            switch value.content {
                            case let .bytes(value): bytes = value
                            case let .copy(source, proof):
                                switch source {
                                case let .incoming(requestIndex, id):
                                    guard program.deletionRequests.indices.contains(requestIndex),
                                          program.deletionRequests[requestIndex].attachments[id] == proof
                                            || program.deletionRequests[requestIndex].supportingAttachments[id] == proof else { throw SyncBootstrapError.corrupt }
                                    bytes = try readPath(rolePath(.attachments, id.uuidString), proof: proof)
                                case let .initialRetained(path): bytes = try readPath(rolePath(.staged, ".sync-deletions/" + path), proof: proof)
                                case let .earlierOutput(stepIndex):
                                    guard stepIndex < localIndex, let path = locations[stepIndex] else { throw SyncBootstrapError.corrupt }
                                    bytes = try readPath(path, proof: proof)
                                }
                            case nil: bytes = nil
                            }
                            try output(value.action, bytes: bytes)
                            locations[localIndex] = outputLocation(value.action)
                            actions[actionIndex] = outputLocation(value.action); actionIndex += 1
                        case let .validate(validation):
                            if let context = validation.counterReminderContext {
                                _ = try SyncMergeEngine().merge(local: validation.records, remote: [], pendingLocal: [], counterReminderContext: context)
                            }
                            var sources: [UUID: SyncAttachmentSource] = [:]
                            for (id, sourceIndex) in validation.sources {
                                guard sourceIndex < localIndex, let path = locations[sourceIndex],
                                      path.hasPrefix(rolePath(.validationMerged) + "/") else { throw SyncBootstrapError.corrupt }
                                let proof = POSIX.proof(try readPath(path))
                                sources[id] = .init(fileURL: owner.paths.accountRoot.appendingPathComponent(path),
                                    contentSHA256: proof.sha256, byteCount: proof.byteCount, isJournalStaged: true)
                            }
                            let actual = try ProjectArchiveSyncMapper.materialize(records: validation.records,
                                attachments: sources, baseArchive: validation.baseArchive)
                            try SyncDeletionLedger.validateOwnedMaterialization(actual, comparison: validation.comparison)
                        }
                    }
                    locks.removeAll(); helpers[index] = actions
                case .publication:
                    let actual = try frozenTree(.staged), initial = program.publication.expectedInitialTree
                    guard actual.directories.union([""]) == Set(initial.directories),
                          actual.files == Dictionary(uniqueKeysWithValues: initial.files.map { ($0.path, $0.proof) }) else { throw SyncBootstrapError.sourceChanged }
                    var actions: [Int: String] = [:], actionIndex = 0
                    for step in program.publication.steps {
                        switch step {
                        case let .output(value):
                            try output(value.action, bytes: value.bytes)
                            actions[actionIndex] = outputLocation(value.action); actionIndex += 1
                        case let .synchronizeParentDirectory(path):
                            let directory = try POSIX.directory(OwnedBootstrapCodec.parent(rolePath(.staged, path)), from: access.accountDescriptor)
                            try owner.io.synchronize(directory.value)
                        }
                    }
                    locks.removeAll(); helpers[index] = actions
                }
                try validate()
            }
        }

        func finish(_ program: SyncBootstrapOwnedProgram) throws -> SyncBootstrapPreparation {
            try validate()
            let entries = try owner.validateHistory(manifest, access: access)
            var expected: [String: BootstrapManifestV3.FileProof] = [manifest.transactionRelativePath: .init(bytes: -1, digest: Data())]
            for action in program.actions {
                let path = outputLocation(action)
                switch action {
                case .directory: expected[path] = .init(bytes: -1, digest: Data())
                case let .write(_, _, mode, _):
                    let proof: SyncBootstrapOutputProof
                    switch mode { case let .create(value), let .replace(_, value): proof = value }
                    expected[path] = .init(bytes: proof.byteCount, digest: proof.sha256)
                case let .reuseExact(_, _, proof): expected[path] = .init(bytes: proof.byteCount, digest: proof.sha256)
                case .lock: expected[path] = .init(bytes: 0, digest: OwnedBootstrapCodec.hash(Data()))
                }
            }
            let actual = Dictionary(uniqueKeysWithValues: entries.filter {
                $0.relativePath == manifest.transactionRelativePath || $0.relativePath.hasPrefix(manifest.transactionRelativePath + "/")
            }.map { ($0.relativePath, BootstrapManifestV3.FileProof(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256)) })
            guard actual == expected else { throw SyncBootstrapError.sourceChanged }
            let originalPrefix = rolePath(.original) + "/"
            let actualOriginal = Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix(originalPrefix) }.map {
                (String($0.relativePath.dropFirst(originalPrefix.count)) + ($0.isDirectory ? "/" : ""),
                 BootstrapManifestV3.FileProof(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
            })
            guard actualOriginal == manifest.original else { throw SyncBootstrapError.sourceChanged }
            let staged = try frozenTree(.staged)
            guard staged.directories.union([""]) == Set(program.publication.finalDirectories),
                  staged.files == Dictionary(uniqueKeysWithValues: program.publication.finalFiles.map { ($0.path, $0.proof) }) else {
                throw SyncBootstrapError.sourceChanged
            }
            let prefix = rolePath(.staged) + "/"
            let installed = Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix(prefix) }.map {
                (String($0.relativePath.dropFirst(prefix.count)) + ($0.isDirectory ? "/" : ""),
                 BootstrapManifestV3.FileProof(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
            })
            guard case let .preparing(preparing) = manifest.body,
                  let liveIdentity = directories["working-set"], let stagedIdentity = directories[rolePath(.staged)] else {
                throw SyncBootstrapError.corrupt
            }
            let prepared = BootstrapManifestV3(id: manifest.id, context: manifest.context,
                livePath: manifest.livePath, journalPath: manifest.journalPath, sourceProof: manifest.sourceProof,
                original: manifest.original, historyHead: preparing.predecessor?.reference ?? manifest.historyHead,
                body: .prepared(.init(installed: installed, mutations: program.mutations,
                    preparationSHA256: OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.envelopePayload(bytes)),
                    commitProgram: program.commitProgram, originalLiveRoot: liveIdentity, stagedRoot: stagedIdentity)))
            try owner.publish(prepared.encoded(maximumBytes: owner.maximumBytes), replacing: bytes, access: access) {
                try self.validate()
                guard try self.access.entries().filter({ $0.relativePath != self.owner.namespace + "/active-next.json" }) == entries else {
                    throw SyncBootstrapError.sourceChanged
                }
            }
            active = false
            return .init(transactionID: manifest.id, originalBackupRoot: owner.paths.accountRoot.appendingPathComponent(rolePath(.original)),
                accountOwnedRoots: [owner.paths.accountRoot.appendingPathComponent(owner.namespace)])
        }
    }
}
