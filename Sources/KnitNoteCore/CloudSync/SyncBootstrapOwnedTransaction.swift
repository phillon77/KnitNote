import CryptoKit
import Darwin
import Foundation

/// The read-only planning boundary. Construction never issues a capability.
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

    init(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
         account: SyncAccountIdentity, context: SyncBootstrapContext,
         journalRelativePath: String = SyncBootstrapTransaction.defaultJournalRelativePath,
         patternFolderNameContext: PatternFolderNameContext? = nil,
         maximumBytes: Int = 100_000_000,
         transactionID: UUID = UUID(), now: Date = Date(),
         validateContext: @escaping (SyncBootstrapContext) throws -> Void) throws {
        guard (0...100_000_000).contains(maximumBytes),
              context.accountIDHash == account.accountIDHash,
              OwnedBootstrapCodec.relative(journalRelativePath) else { throw SyncBootstrapError.corrupt }
        self.storage = storage; self.paths = paths; self.account = account; self.context = context
        self.journalRelativePath = journalRelativePath; self.patternFolderNameContext = patternFolderNameContext
        self.maximumBytes = maximumBytes; self.validateContext = validateContext
        self.livePath = paths.workingSet.standardizedFileURL.path
        self.transactionID = transactionID; self.now = now
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
