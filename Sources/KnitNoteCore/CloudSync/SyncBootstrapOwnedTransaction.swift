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
    case beforeValidation(SyncBootstrapOwnedValidation), afterValidation(SyncBootstrapOwnedValidation)
}

/// Observation around the existing physical helper calls, never validation authority.
enum SyncBootstrapOwnedValidation: Equatable {
    case backupSource(index: Int, final: Bool), backupInspection(index: Int)
    case localMaterialization, mergedMaterialization, deletion(step: Int)
}

/// Exact selected terminal and immutable history, shared by physical capture
/// and authenticated decoding. This data never authorizes a write or cleanup.
struct SyncBootstrapOwnedTerminalEvidence {
    let manifest: BootstrapManifestV3
    let activeRelativePath: String
    let activeEnvelope: Data
    let historyRecords: [Data]
    let abandonedEntries: [SyncAccountRecoveryInventory.Entry]

    static func read(account: SyncAccountIdentity, accountRoot: URL, liveRoot: URL, journalURL: URL,
        entries: [SyncAccountRecoveryInventory.Entry], maximumBytes: Int,
        read: (String) throws -> Data) throws -> Self? {
        let live = liveRoot.deletingLastPathComponent().standardizedFileURL
            .appendingPathComponent(liveRoot.lastPathComponent, isDirectory: true)
        let namespace = ".KnitNote-SyncBootstrap/" + account.accountIDHash + "/"
            + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(live.path.utf8)))
        let activePath = namespace + "/active.json"
        guard entries.contains(where: { $0.relativePath == activePath && !$0.isDirectory }) else { return nil }
        func verified(_ path: String) throws -> Data {
            guard let entry = entries.first(where: { $0.relativePath == path && !$0.isDirectory }) else {
                throw SyncBootstrapError.corrupt
            }
            guard entry.byteCount <= maximumBytes else { throw SyncAccountRecoveryInventory.Error.tooLarge }
            let bytes = try read(path)
            guard bytes.count == entry.byteCount, OwnedBootstrapCodec.hash(bytes) == entry.sha256 else { throw SyncBootstrapError.corrupt }
            return bytes
        }
        let active = try verified(activePath)
        struct Version: Decodable { let version: Int }
        let payload = try OwnedBootstrapCodec.envelopePayload(active, maximumBytes: maximumBytes)
        if try JSONDecoder().decode(Version.self, from: payload).version != 3 { return nil }
        let manifest = try BootstrapManifestV3.decodeEnvelope(active, maximumBytes: maximumBytes)
        guard manifest.context.accountIDHash == account.accountIDHash,
              OwnedBootstrapCodec.samePath(manifest.livePath, live.path),
              live.deletingLastPathComponent() == accountRoot.standardizedFileURL,
              SyncBootstrapTransaction.sameStoragePath(live.appendingPathComponent(manifest.journalPath), journalURL),
              !entries.contains(where: { $0.relativePath == namespace + "/active-next.json" }) else { throw SyncBootstrapError.sourceChanged }
        let ancestors = OwnedBootstrapCodec.parents(namespace) + [namespace]
        for entry in entries where entry.relativePath.split(separator: "/").first.map({
            OwnedBootstrapCodec.alias(String($0)) == OwnedBootstrapCodec.alias(".KnitNote-SyncBootstrap")
        }) == true {
            guard (OwnedBootstrapCodec.containsExactPath(ancestors, entry.relativePath) && entry.isDirectory)
                || OwnedBootstrapCodec.hasExactPrefix(entry.relativePath, namespace + "/") else { throw SyncBootstrapError.corrupt }
        }
        let records = try entries.filter { !$0.isDirectory && $0.relativePath.hasPrefix(namespace + "/History/") }
            .map { SyncBootstrapHistory.SuppliedRecord(relativePath: $0.relativePath, bytes: try verified($0.relativePath)) }
        let history = try SyncBootstrapHistory.validate(current: manifest, records: records,
            accountEntries: entries, maximumBytes: maximumBytes)
        let lookup = Dictionary(uniqueKeysWithValues: records.map { ($0.relativePath, $0.bytes) })
        var ordered: [Data] = [], next = manifest.historyHead
        while let ref = next {
            let path = SyncBootstrapHistory.recordPath(namespace: namespace, hash: ref.sha256)
            guard let bytes = lookup[path] else { throw SyncBootstrapError.corrupt }
            ordered.append(bytes)
            next = history[ordered.count - 1].previous
        }
        let prefix = "working-set/"
        let liveProofs = Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix(prefix) }.map {
            (String($0.relativePath.dropFirst(prefix.count)) + ($0.isDirectory ? "/" : ""),
             BootstrapManifestV3.FileProof(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
        })
        let abandoned: [SyncAccountRecoveryInventory.Entry]
        switch manifest.body {
        case let .abortedPreparation(body):
            guard liveProofs == manifest.original else { throw SyncBootstrapError.sourceChanged }
            abandoned = body.frozenOutputEntries
        case let .rolledBack(body):
            guard liveProofs == manifest.original,
                  let liveEntry = entries.first(where: { $0.relativePath == "working-set" && $0.isDirectory }),
                  liveEntry.device == body.prepared.originalLiveRoot.device,
                  liveEntry.inode == body.prepared.originalLiveRoot.inode else { throw SyncBootstrapError.sourceChanged }
            abandoned = body.frozenTransactionEntries.filter {
                $0.relativePath == manifest.transactionRelativePath + "/Failed"
                    || $0.relativePath.hasPrefix(manifest.transactionRelativePath + "/Failed/")
            }
        case let .committed(body):
            let originalPrefix = manifest.transactionRelativePath + "/Original/"
            let original = Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix(originalPrefix) }.map {
                (String($0.relativePath.dropFirst(originalPrefix.count)) + ($0.isDirectory ? "/" : ""),
                 BootstrapManifestV3.FileProof(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
            })
            guard original == manifest.original,
                  let liveEntry = entries.first(where: { $0.relativePath == "working-set" && $0.isDirectory }),
                  liveEntry.device == body.stagedRoot.device, liveEntry.inode == body.stagedRoot.inode,
                  liveProofs["projects-v1.json"] == body.installed["projects-v1.json"] else { throw SyncBootstrapError.sourceChanged }
            let receiptPath = "SyncMetadata/bootstrap-receipt.json"
            let receipts = body.commitProgram.operations.compactMap { operation -> Data? in
                if case let .replace(path, _, bytes, _) = operation, path == receiptPath { return bytes }; return nil
            }
            guard receipts.count == 1, let receiptBytes = receipts.first,
                  liveProofs[receiptPath] == .init(bytes: Int64(receiptBytes.count), digest: OwnedBootstrapCodec.hash(receiptBytes)) else { throw SyncBootstrapError.corrupt }
            let receipt = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: receiptBytes)
            guard receipt.transactionID == manifest.id, receipt.accountIDHash == account.accountIDHash,
                  receipt.sourceProof == manifest.sourceProof else { throw SyncBootstrapError.corrupt }
            abandoned = []
        default: throw SyncBootstrapError.invalidPhase
        }
        var exceptions = abandoned
        for record in history {
            struct V: Decodable { let version: Int }
            if try JSONDecoder().decode(V.self, from: OwnedBootstrapCodec.envelopePayload(record.terminalEnvelope)).version == 3 {
                let old = try BootstrapManifestV3.decodeEnvelope(record.terminalEnvelope)
                switch old.body {
                case let .abortedPreparation(value): exceptions += value.frozenOutputEntries
                case let .rolledBack(value): exceptions += value.frozenTransactionEntries.filter {
                    $0.relativePath == old.transactionRelativePath + "/Failed" || $0.relativePath.hasPrefix(old.transactionRelativePath + "/Failed/")
                }
                default: throw SyncBootstrapError.invalidPhase
                }
            }
        }
        return .init(manifest: manifest, activeRelativePath: activePath, activeEnvelope: active,
            historyRecords: ordered, abandonedEntries: exceptions)
    }
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
        self.livePath = paths.workingSet.deletingLastPathComponent().standardizedFileURL
            .appendingPathComponent(paths.workingSet.lastPathComponent, isDirectory: true).path
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
            let fingerprint = try Self.sourceTreeFingerprint(inventory.entries)
            let hasJournal = Self.hasSourceJournal(inventory.entries, journalRelativePath: journalRelativePath)
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
        // Count already-received legacy input before combined migration, using
        // the existing migration encoder; durable output encoders stay strict.
        var sourceAllowance = try SyncRecordVersion.deterministicEncoder(allowingLegacyStandaloneReminder: true)
            .encode(input.remote.records).count
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
        var existingHistory: [Data] = []
        var existingHead: BootstrapHistoryRef?
        let activePath = namespace + "/active.json"
        if inventory.entries.contains(where: { $0.relativePath == activePath }) {
            let bytes = try read(activePath, inventory: inventory)
            let terminalID: UUID, terminalLive: String, terminalJournal: String
            if let bootstrap = inventory.bootstrapEvidence {
                let terminal = try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: maximumBytes)
                guard bootstrap.activeEnvelope == bytes else { throw SyncBootstrapError.sourceChanged }
                switch terminal.body { case .rolledBack, .abortedPreparation: break; default: throw SyncBootstrapError.alreadyCommitted }
                terminalID = terminal.id; terminalLive = terminal.livePath; terminalJournal = terminal.journalPath
                existingHistory = bootstrap.historyRecords; existingHead = terminal.historyHead
            } else {
                let terminal = try SyncBootstrapTransaction.legacyHistorySource(bytes)
                terminalID = terminal.id; terminalLive = terminal.livePath; terminalJournal = terminal.journalPath
            }
            let oldRoot = namespace + "/" + terminalID.uuidString
            let tree = inventory.entries.filter { $0.relativePath == oldRoot || $0.relativePath.hasPrefix(oldRoot + "/") }
            let record = try BootstrapHistoryRecordV1(version: 1, accountIDHash: account.accountIDHash,
                livePath: terminalLive, journalPath: terminalJournal, transactionID: terminalID,
                terminalEnvelope: bytes, treeEntries: tree, previous: existingHead).encoded(maximumBytes: maximumBytes)
            predecessor = .init(record: record, reference: .init(sha256: OwnedBootstrapCodec.hash(record),
                byteCount: Int64(record.count), recordCount: (existingHead?.recordCount ?? 0) + 1,
                chainByteCount: (existingHead?.chainByteCount ?? 0) + Int64(record.count)))
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
            existingHistory: existingHistory, existingHead: existingHead,
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

    static func sourceTreeFingerprint(_ entries: [SyncAccountRecoveryInventory.Entry]) throws -> Data {
        OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.encode(liveProofs(entries)))
    }

    static func hasSourceJournal(_ entries: [SyncAccountRecoveryInventory.Entry], journalRelativePath: String) -> Bool {
        let prefix = "working-set/" + journalRelativePath
        let hidden = OwnedBootstrapCodec.parent(prefix) + "/." + String(prefix.split(separator: "/").last!)
        return entries.contains {
            $0.relativePath == prefix || $0.relativePath.hasPrefix(prefix + ".") || $0.relativePath.hasPrefix(hidden)
        }
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

    enum SelectedRecoveryFormat { case none, legacy, owned }

    /// Routing information only. Parsing never grants a bootstrap capability;
    /// the selected native recovery implementation validates its full evidence.
    func selectedRecoveryFormat() throws -> SelectedRecoveryFormat {
        try validateContext(context)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let entries = try access.entries()
            guard entries.contains(where: { $0.relativePath == namespace + "/active.json" }) else {
                guard !entries.contains(where: { $0.relativePath == namespace || $0.relativePath.hasPrefix(namespace + "/") }) else {
                    throw SyncBootstrapError.sourceChanged
                }
                return .none
            }
            let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
            guard let bytes = try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) else {
                throw SyncBootstrapError.sourceChanged
            }
            struct Binding: Decodable { let version: Int; let context: SyncBootstrapContext; let livePath: String; let journalPath: String }
            let binding = try JSONDecoder().decode(Binding.self, from: OwnedBootstrapCodec.envelopePayload(bytes, maximumBytes: maximumBytes))
            guard binding.context.accountIDHash == account.accountIDHash, OwnedBootstrapCodec.samePath(binding.livePath, livePath),
                  OwnedBootstrapCodec.samePath(binding.journalPath, journalRelativePath), [1, 2, 3].contains(binding.version) else {
                throw SyncBootstrapError.corrupt
            }
            try validateContext(context); try access.validate()
            return binding.version == 3 ? .owned : .legacy
        }
    }

    func install(_ prepared: SyncBootstrapPreparation) throws {
        try validateContext(context)
        try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let phase = try InstallOwner(owner: self, access: access, prepared: prepared)
            try phase.install()
        }
    }

    func commit(_ prepared: SyncBootstrapPreparation) throws -> SyncBootstrapReceipt {
        try validateContext(context)
        return try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes) { access in
            let phase = try InstallOwner(owner: self, access: access, prepared: prepared)
            return try phase.commit()
        }
    }

    /// Storage's missing-live admission is proof-only. It uses the same private
    /// placement/source validator as installation and rollback, without issuing
    /// a phase owner to its caller or synchronizing/publishing any selector.
    static func validateMissingWorkingSetRecovery(storage: SyncAccountStorage, paths: SyncAccountStorage.Paths,
        account: SyncAccountIdentity, access: SyncAccountStorage.RecoveryAccess, maximumBytes: Int) throws {
        let live = paths.workingSet.deletingLastPathComponent().standardizedFileURL
            .appendingPathComponent(paths.workingSet.lastPathComponent, isDirectory: true)
        let namespace = ".KnitNote-SyncBootstrap/" + account.accountIDHash + "/"
            + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(Data(live.path.utf8)))
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        guard let bytes = try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes),
              try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == nil else {
            throw SyncBootstrapError.sourceChanged
        }
        let manifest = try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: maximumBytes)
        switch manifest.body { case .prepared, .rollingBack: break; default: throw SyncBootstrapError.invalidPhase }
        let control = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
        guard control.nextBytes == nil else { throw SyncBootstrapError.sourceChanged }
        switch (manifest.sourceProof, control.state) {
        case (.missingArchive, .sourceSpent): break
        case (.archive, nil):
            guard control.mainBytes == nil else { throw SyncBootstrapError.sourceChanged }
        default: throw SyncBootstrapError.sourceChanged
        }
        let owner = try Self(storage: storage, paths: paths, account: account, context: manifest.context,
            maximumBytes: maximumBytes, validateContext: { _ in })
        let phase = try InstallOwner(owner: owner, access: access, selected: bytes)
        let entries = try phase.validatePlacement()
        guard !entries.contains(where: { $0.relativePath == "working-set" }),
              try phase.validatePlacement() == entries,
              try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == control else {
            throw SyncBootstrapError.sourceChanged
        }
    }

    /// The prepared/installed issuer is a distinct synchronous phase owner.
    /// It cannot allocate preparation outputs or expose a capability outside
    /// this account ownership scope.
    private final class InstallOwner {
        let owner: SyncBootstrapOwnedTransaction
        let access: SyncAccountStorage.RecoveryAccess
        var manifest: BootstrapManifestV3
        var bytes: Data
        let prepared: BootstrapManifestV3.PreparedBody
        let root: String
        let initialEntries: [SyncAccountRecoveryInventory.Entry]

        convenience init(owner: SyncBootstrapOwnedTransaction, access: SyncAccountStorage.RecoveryAccess,
            prepared token: SyncBootstrapPreparation) throws {
            let directory = try POSIX.directory(owner.namespace, from: access.accountDescriptor)
            guard let bytes = try POSIX.read("active.json", parent: directory.value, maximumBytes: owner.maximumBytes) else { throw SyncBootstrapError.corrupt }
            try self.init(owner: owner, access: access, selected: bytes)
            guard manifest.context == owner.context, manifest.id == token.transactionID,
                  SyncBootstrapTransaction.sameStoragePath(token.originalBackupRoot,
                    owner.paths.accountRoot.appendingPathComponent(manifest.transactionRelativePath + "/Original")) else { throw SyncBootstrapError.sourceChanged }
            try owner.synchronizeSelected(bytes, access: access)
        }

        /// Historical context is admitted only by recovery/terminal handling;
        /// forward install/commit must pass the token initializer above.
        convenience init(owner: SyncBootstrapOwnedTransaction, access: SyncAccountStorage.RecoveryAccess,
            recovering bytes: Data) throws {
            try self.init(owner: owner, access: access, selected: bytes)
            try owner.synchronizeSelected(bytes, access: access)
        }

        init(owner: SyncBootstrapOwnedTransaction, access: SyncAccountStorage.RecoveryAccess, selected bytes: Data) throws {
            self.owner = owner; self.access = access
            let manifest = try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: owner.maximumBytes)
            guard let body = manifest.body.preparedBody,
                  manifest.context.accountIDHash == owner.account.accountIDHash,
                  manifest.livePath == owner.livePath, manifest.journalPath == owner.journalRelativePath else { throw SyncBootstrapError.sourceChanged }
            self.manifest = manifest; self.bytes = bytes; prepared = body; root = manifest.transactionRelativePath
            initialEntries = try access.entries()
        }

        func read(_ path: String) throws -> Data? {
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(path), from: access.accountDescriptor)
            return try POSIX.read(String(path.split(separator: "/").last!), parent: parent.value, maximumBytes: owner.maximumBytes)
        }
        func entries() throws -> [SyncAccountRecoveryInventory.Entry] {
            try access.validate()
            guard try read(owner.namespace + "/active.json") == bytes else { throw SyncBootstrapError.sourceChanged }
            let entries = try owner.validateHistory(manifest, access: access)
            try owner.validatePreparedDerivative(manifest, bytes: bytes, entries: entries, access: access)
            func immutable(_ entries: [SyncAccountRecoveryInventory.Entry]) -> [SyncAccountRecoveryInventory.Entry] {
                entries.filter { entry in
                    if [owner.namespace + "/active.json", owner.namespace + "/active-next.json"].contains(entry.relativePath) { return false }
                    return !["working-set", root + "/Staged", root + "/Displaced", root + "/Failed"].contains {
                        entry.relativePath == $0 || entry.relativePath.hasPrefix($0 + "/")
                    }
                }
            }
            guard immutable(entries) == immutable(initialEntries) else { throw SyncBootstrapError.sourceChanged }
            return entries
        }
        func source(_ entries: [SyncAccountRecoveryInventory.Entry]) throws -> SyncAccountControlObservation {
            let control = try SyncAccountRecoveryControlFile(synchronize: POSIX.synchronize).observe(access: access)
            guard control.nextBytes == nil,
                  try BootstrapManifestV3.formerSourceDigest(control.state) == prepared.formerSourceSHA256 else {
                throw SyncBootstrapError.sourceChanged
            }
            switch (manifest.sourceProof, control.state) {
            case (.archive, nil):
                guard prepared.sourceControlSHA256 == nil else { throw SyncBootstrapError.sourceChanged }
            case (.missingArchive, .absentSource):
                guard control.mainBytes.map(OwnedBootstrapCodec.hash) == prepared.sourceControlSHA256 else { throw SyncBootstrapError.sourceChanged }
                try owner.validateSource(manifest, access: access)
            case (.missingArchive, .sourceSpent(let value, let id, let digest)):
                guard id == manifest.id, digest == (try manifest.normalizedPreparedDigest()),
                      let main = control.mainBytes,
                      try SyncAccountRecoveryControlFile.sourceSpentPredecessor(main) == prepared.sourceControlSHA256,
                      value.accountIDHash == owner.account.accountIDHash, value.accountRoot == owner.paths.accountRoot,
                      value.archiveURL == owner.paths.workingSet.appendingPathComponent("projects-v1.json"),
                      value.journalURL == owner.paths.workingSet.appendingPathComponent(owner.journalRelativePath),
                      value.baselineSHA256 == prepared.pendingSnapshotSHA256,
                      try POSIX.identity(access.accountDescriptor) == .init(device: value.accountDevice, inode: value.accountInode) else { throw SyncBootstrapError.sourceChanged }
            default: throw SyncBootstrapError.sourceChanged
            }
            guard try originalBaseline(entries) == prepared.pendingSnapshotSHA256 else { throw SyncBootstrapError.sourceChanged }
            return control
        }

        /// Native journal reads use the immutable Original location, while
        /// source URLs and the baseline domain retain their exact old spelling.
        private func originalBaseline(_ entries: [SyncAccountRecoveryInventory.Entry]) throws -> Data {
            let original = root + "/Original"
            guard SyncBootstrapOwnedTransaction.proofs(entries, under: original) == manifest.original else { throw SyncBootstrapError.sourceChanged }
            let projected = entries.filter { $0.relativePath != "working-set" && !$0.relativePath.hasPrefix("working-set/") }
                + entries.filter { $0.relativePath == original || $0.relativePath.hasPrefix(original + "/") }.map {
                    SyncAccountRecoveryInventory.Entry(relativePath: "working-set" + $0.relativePath.dropFirst(original.count),
                        isDirectory: $0.isDirectory, byteCount: $0.byteCount, sha256: $0.sha256, device: $0.device, inode: $0.inode)
                }
            let journal = FileSyncMutationJournal(url: owner.paths.workingSet.appendingPathComponent(manifest.journalPath))
            let pending = try journal.recoverySnapshotOfOwnedOriginal(accountRoot: owner.paths.accountRoot,
                manifest: manifest, access: access, maximumBytes: owner.maximumBytes)
            var files = try pending.compactMap(\.attachmentSource).map { value -> SyncPendingRecoveryPacket.File in
                guard value.fileURL.path.hasPrefix(owner.paths.accountRoot.path + "/") else { throw SyncBootstrapError.sourceChanged }
                return .init(relativePath: String(value.fileURL.path.dropFirst(owner.paths.accountRoot.path.count + 1)),
                    byteCount: value.byteCount, sha256: value.contentSHA256, bytes: Data())
            }
            var ledger: Data?, markers: [SyncRecordVersion] = []
            if manifest.original[".sync-deletions/ledger.json"] != nil {
                guard let bytes = try read(original + "/.sync-deletions/ledger.json") else { throw SyncBootstrapError.sourceChanged }
                let prefix = ".sync-deletions/"
                let proofs = Dictionary(uniqueKeysWithValues: manifest.original.compactMap { path, proof -> (String, SyncBootstrapOutputProof)? in
                    guard path.hasPrefix(prefix), proof.bytes >= 0 else { return nil }
                    return (String(path.dropFirst(prefix.count)), .init(byteCount: proof.bytes, sha256: proof.digest))
                })
                let export = try SyncDeletionLedger.projectedRecoveryExport(archiveURL: owner.paths.workingSet.appendingPathComponent("projects-v1.json"),
                    manifestBytes: bytes, files: proofs, pending: pending, maximumBytes: owner.maximumBytes,
                    archiveSHA256: { guard let hash = self.manifest.original["projects-v1.json"]?.digest else { throw SyncBootstrapError.sourceChanged }; return hash })
                ledger = export.manifest; markers = export.pendingMarkerVersions
                files += export.files.map { .init(relativePath: "working-set/.sync-deletions/" + $0.retainedRelativePath,
                    byteCount: $0.byteCount, sha256: $0.sha256, bytes: Data()) }
            }
            return try SyncAccountSourceBaseline.digest(entries: projected, accountRoot: owner.paths.accountRoot,
                journalURL: owner.paths.workingSet.appendingPathComponent(manifest.journalPath), mutations: pending,
                selectedFiles: files, deletionLedger: ledger, pendingMarkerVersions: markers)
        }

        func validatePlacement() throws -> [SyncAccountRecoveryInventory.Entry] {
            let entries = try entries()
            _ = try source(entries)
            func directory(_ path: String, identity: BootstrapManifestV3.InstallRootIdentity) throws -> Bool {
                guard let entry = entries.first(where: { $0.relativePath == path }) else { return false }
                guard entry.isDirectory, entry.device == identity.device, entry.inode == identity.inode else { throw SyncBootstrapError.sourceChanged }
                return true
            }
            let displaced = try directory(root + "/Displaced", identity: prepared.originalLiveRoot)
            let staged = try directory(root + "/Staged", identity: prepared.stagedRoot)
            let failed = try directory(root + "/Failed", identity: prepared.stagedRoot)
            let live = entries.first { $0.relativePath == "working-set" }
            if displaced {
                guard SyncBootstrapOwnedTransaction.proofs(entries, under: root + "/Displaced") == manifest.original else { throw SyncBootstrapError.sourceChanged }
                if let live {
                    guard !staged, !failed, live.isDirectory, live.device == prepared.stagedRoot.device,
                          live.inode == prepared.stagedRoot.inode else { throw SyncBootstrapError.sourceChanged }
                    try validatePrefix(at: "working-set", entries: entries)
                } else { guard staged != failed else { throw SyncBootstrapError.sourceChanged } }
            } else {
                guard let live, live.isDirectory, live.device == prepared.originalLiveRoot.device,
                      live.inode == prepared.originalLiveRoot.inode, staged != failed,
                      SyncBootstrapOwnedTransaction.proofs(entries, under: "working-set") == manifest.original else { throw SyncBootstrapError.sourceChanged }
            }
            if staged { guard SyncBootstrapOwnedTransaction.proofs(entries, under: root + "/Staged") == prepared.installed else { throw SyncBootstrapError.sourceChanged } }
            if failed { try validatePrefix(at: root + "/Failed", entries: entries) }
            return entries
        }

        func persist(_ body: BootstrapManifestV3.Body) throws {
            let before = try validatePlacement()
            var next = manifest; next.body = body
            let encoded = try next.encoded(maximumBytes: owner.maximumBytes)
            try owner.publish(encoded, replacing: bytes, access: access) {
                let current = try self.validatePlacement()
                let active = self.owner.namespace + "/active-next.json"
                guard current.filter({ $0.relativePath != active }) == before.filter({ $0.relativePath != active }) else { throw SyncBootstrapError.sourceChanged }
            }
            manifest = next; bytes = encoded
        }

        func move(_ step: SyncBootstrapInstallPhases.Move) throws {
            _ = try validatePlacement()
            let from: String, to: String
            switch step {
            case .liveToDisplaced: from = "working-set"; to = root + "/Displaced"
            case .stagedToLive: from = root + "/Staged"; to = "working-set"
            case .liveToFailed: from = "working-set"; to = root + "/Failed"
            case .displacedToLive: from = root + "/Displaced"; to = "working-set"
            }
            let sourceParent = try POSIX.directory(OwnedBootstrapCodec.parent(from), from: access.accountDescriptor)
            let targetParent = try POSIX.directory(OwnedBootstrapCodec.parent(to), from: access.accountDescriptor)
            let sourceName = String(from.split(separator: "/").last!), targetName = String(to.split(separator: "/").last!)
            var status = stat()
            guard fstatat(targetParent.value, targetName, &status, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
                  renameat(sourceParent.value, sourceName, targetParent.value, targetName) == 0 else { throw SyncBootstrapError.sourceChanged }
            try owner.io.synchronize(sourceParent.value); try owner.io.synchronize(targetParent.value)
        }
        func boundary(_ point: SyncBootstrapBoundary) throws {
            switch point {
            case .afterLiveMove: try owner.boundary(.afterLiveMove)
            case .afterStagedMove: try owner.boundary(.afterStagedMove)
            case .afterInstalled: try owner.boundary(.afterInstalled)
            case .afterRollbackIntent: try owner.boundary(.afterRollbackIntent)
            case .afterFailedMove: try owner.boundary(.afterFailedMove)
            case .afterOriginalRestore: try owner.boundary(.afterOriginalRestore)
            default: throw SyncBootstrapError.invalidPhase
            }
        }
        func install() throws {
            guard case .prepared = manifest.body else { throw SyncBootstrapError.invalidPhase }
            let entries = try validatePlacement()
            guard SyncBootstrapOwnedTransaction.proofs(entries, under: "working-set") == manifest.original,
                  entries.contains(where: { $0.relativePath == root + "/Staged" }) else { throw SyncBootstrapError.sourceChanged }
            try owner.boundary(.beforeSourceSpend)
            let file = SyncAccountRecoveryControlFile(synchronize: owner.io.controlSynchronize)
            let observed = try source(entries)
            if case let .absentSource(value) = observed.state {
                _ = try file.replace(observed, with: .sourceSpent(value, transactionID: manifest.id,
                    preparedManifestSHA256: manifest.normalizedPreparedDigest()), access: access) {
                    guard try self.access.entries() == entries,
                          try file.observe(access: self.access).mainBytes == observed.mainBytes,
                          try self.originalBaseline(entries) == self.prepared.pendingSnapshotSHA256 else { throw SyncBootstrapError.sourceChanged }
                }
            } else { try file.synchronize(observed, access: access) }
            do {
                try owner.boundary(.afterSourceSpend)
                try SyncBootstrapInstallPhases.install(move: move,
                    persistInstalled: { try self.persist(.installed(self.prepared)) }, boundary: boundary)
            } catch {
                let first = error
                try rollback()
                throw first
            }
        }

        func rollback() throws {
            if case .committed = manifest.body { throw SyncBootstrapError.alreadyCommitted }
            _ = try validatePlacement()
            if case .rolledBack = manifest.body { return }
            try SyncBootstrapInstallPhases.rollback(persistIntent: { try self.persist(.rollingBack(self.prepared)) },
                hasDisplaced: { try self.entries().contains { $0.relativePath == self.root + "/Displaced" } },
                validateDisplaced: { _ = try self.validatePlacement() },
                hasLive: { try self.entries().contains { $0.relativePath == "working-set" } }, move: move,
                validateRestored: { _ = try self.validatePlacement() }, persistTerminal: {
                    let entries = try self.validatePlacement()
                    let frozen = entries.filter { $0.relativePath == self.root || $0.relativePath.hasPrefix(self.root + "/") }
                    try self.owner.synchronizeEntries(frozen, access: self.access)
                    guard try self.validatePlacement() == entries else { throw SyncBootstrapError.sourceChanged }
                    try self.persist(.rolledBack(.init(prepared: self.prepared, frozenTransactionEntries: frozen)))
                }, boundary: boundary)
        }

        func validatePrefix(at location: String, entries: [SyncAccountRecoveryInventory.Entry], complete: Bool = false) throws {
            try SyncBootstrapOwnedTransaction.validateCommitPrefix(manifest, at: location, entries: entries,
                complete: complete, read: read)
        }
        private func temporary(_ path: String, _ id: UUID) -> String {
            let parent = OwnedBootstrapCodec.parent(path), name = String(path.split(separator: "/").last!)
            return (parent.isEmpty ? "" : parent + "/") + "." + name + "." + id.uuidString + ".tmp"
        }

        func commit() throws -> SyncBootstrapReceipt {
            let entries = try validatePlacement()
            if case .committed = manifest.body { return try receipt() }
            guard case .installed = manifest.body,
                  SyncBootstrapOwnedTransaction.proofs(entries, under: "working-set") == prepared.installed else { throw SyncBootstrapError.invalidPhase }
            do {
                let journal = FileSyncMutationJournal(url: owner.paths.workingSet.appendingPathComponent(manifest.journalPath))
                try journal.withOwnedCommitCoordination(prepared.mutations) {
                    let locked = try self.validatePlacement()
                    guard SyncBootstrapOwnedTransaction.proofs(locked, under: "working-set") == self.prepared.installed else { throw SyncBootstrapError.sourceChanged }
                    // Recheck the initial installed journal under both native
                    // locks. Source validation reads only immutable Original.
                    for (index, operation) in self.prepared.commitProgram.operations.enumerated() {
                        _ = try self.validatePlacement()
                        try self.execute(operation)
                        try self.owner.boundary(.afterJournalOperation(index: index))
                    }
                    try self.validatePrefix(at: "working-set", entries: self.access.entries(), complete: true)
                }
                let result = try receipt()
                try owner.boundary(.afterReceipt)
                try validatePrefix(at: "working-set", entries: access.entries(), complete: true)
                try persist(.committed(prepared))
                return result
            } catch {
                let first = error; try rollback(); throw first
            }
        }
        private func receipt() throws -> SyncBootstrapReceipt {
            guard let bytes = try read("working-set/SyncMetadata/bootstrap-receipt.json") else { throw SyncBootstrapError.corrupt }
            let result = try JSONDecoder().decode(SyncBootstrapReceipt.self, from: bytes)
            guard result.transactionID == manifest.id, result.accountIDHash == owner.account.accountIDHash,
                  result.sourceProof == manifest.sourceProof else { throw SyncBootstrapError.corrupt }
            return result
        }
        private func execute(_ op: BootstrapManifestV3.CommitOperation) throws {
            let path: String
            switch op {
            case let .synchronize(value), let .directory(value), let .reuse(value, _), let .replace(value, _, _, _),
                 let .copyAttachment(value, _, _, _): path = value
            case .appendSegment: path = prepared.commitProgram.journalRelativePath + ".segment"
            }
            let full = "working-set/" + path
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(full), from: access.accountDescriptor)
            let name = String(path.split(separator: "/").last!)
            switch op {
            case .directory:
                guard mkdirat(parent.value, name, 0o700) == 0 else { throw SyncBootstrapError.sourceChanged }
                try owner.io.synchronize(parent.value)
            case .synchronize:
                let current = try access.entries().first { $0.relativePath == full }
                guard let current else { throw SyncBootstrapError.sourceChanged }
                let fd = try POSIX.Descriptor(openat(parent.value, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                    | (current.isDirectory ? O_DIRECTORY : O_NONBLOCK)))
                try POSIX.match(fd.value, name: name, parent: parent.value, directory: current.isDirectory)
                try owner.io.synchronize(fd.value)
            case let .reuse(_, proof):
                guard let bytes = try read(full), POSIX.proof(bytes) == proof.value else { throw SyncBootstrapError.sourceChanged }
            case let .replace(_, old, bytes, id): try replace(path: path, old: old?.value, bytes: bytes, id: id)
            case let .copyAttachment(_, version, expected, id):
                guard let bytes = try read(root + "/Attachments/" + version.uuidString), POSIX.proof(bytes) == expected.value else { throw SyncBootstrapError.sourceChanged }
                try replace(path: path, old: nil, bytes: bytes, id: id)
            case let .appendSegment(expected, frames):
                let old = try read(full)
                guard old.map(POSIX.proof) == expected?.value else { throw SyncBootstrapError.sourceChanged }
                let fd = try POSIX.Descriptor(openat(parent.value, name, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
                    | (old == nil ? O_CREAT | O_EXCL : 0), 0o600))
                try POSIX.match(fd.value, name: name, parent: parent.value, directory: false)
                try owner.io.write(fd.value, frames); try owner.io.synchronize(fd.value)
                if old == nil { try owner.io.synchronize(parent.value) }
                guard try read(full) == (old ?? Data()) + frames else { throw SyncBootstrapError.sourceChanged }
            }
        }
        private func replace(path: String, old: SyncBootstrapOutputProof?, bytes: Data, id: UUID) throws {
            let full = "working-set/" + path
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(full), from: access.accountDescriptor)
            let name = String(path.split(separator: "/").last!), temp = String(temporary(path, id).split(separator: "/").last!)
            guard try read(full).map(POSIX.proof) == old else { throw SyncBootstrapError.sourceChanged }
            let fd = try POSIX.Descriptor(openat(parent.value, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
            try owner.io.write(fd.value, bytes); try owner.io.synchronize(fd.value)
            try POSIX.match(fd.value, name: temp, parent: parent.value, directory: false)
            guard try POSIX.read(temp, parent: parent.value, maximumBytes: owner.maximumBytes) == bytes,
                  try read(full).map(POSIX.proof) == old,
                  renameat(parent.value, temp, parent.value, name) == 0 else { throw SyncBootstrapError.sourceChanged }
            try owner.io.synchronize(parent.value)
        }
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

    /// Preparing recovery freezes outputs before exact terminal source handoff.
    /// Installed states use the shared rollback and committed receipt validators.
    func recover() throws -> SyncCanonicalBootstrapHandoff? {
        try validateContext(context)
        let committed: Bool = try storage.withRecoveryOwnership(paths: paths, account: account, maximumBytes: maximumBytes,
            createControl: true) { access in
            let entries = try access.entries()
            guard entries.contains(where: { $0.relativePath == namespace + "/active.json" }) else {
                guard !entries.contains(where: { $0.relativePath == namespace || $0.relativePath.hasPrefix(namespace + "/") }) else {
                    throw SyncBootstrapError.sourceChanged
                }
                return false
            }
            let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
            guard let bytes = try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) else {
                throw SyncBootstrapError.sourceChanged
            }
            struct Version: Decodable { let version: Int }
            let version = try JSONDecoder().decode(Version.self, from: OwnedBootstrapCodec.envelopePayload(bytes)).version
            if version != 3 {
                let source = try SyncBootstrapTransaction.legacyHistorySource(bytes)
                if case .missingArchive = source.sourceProof {
                    let control = SyncAccountRecoveryControlFile(synchronize: io.controlSynchronize)
                    let observed = try control.observe(access: access)
                    let journal = FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath))
                    if observed.mainBytes == nil, observed.nextBytes == nil {
                        try control.initializeLegacyRollback(access: access, paths: paths, account: account,
                            journal: journal, maximumBytes: maximumBytes)
                    } else {
                        guard case let .absentSource(value) = observed.state, observed.nextBytes == nil,
                              case let .bootstrapRollback(id, path, digest) = value.origin,
                              id == source.id, path == namespace + "/active.json", digest == OwnedBootstrapCodec.hash(bytes) else {
                            throw SyncBootstrapError.sourceChanged
                        }
                        _ = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
                            journal: journal, archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                            control: observed, maximumBytes: maximumBytes)
                        try control.synchronize(observed, access: access)
                    }
                } else { try recoverLegacyDerivative(bytes, entries: entries, access: access) }
                return false
            }
            let manifest = try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: maximumBytes)
            switch manifest.body {
            case .preparing:
                let issuer = try Issuer(owner: self, access: access, selected: manifest, exactBytes: bytes, baseline: nil)
                try issuer.abort()
            case .abortedPreparation:
                // Do not report an unresolved later selector as recovered.
                guard try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == nil else {
                    throw SyncBootstrapError.invalidPhase
                }
                try synchronizeSelected(bytes, access: access)
                try validateSource(manifest, access: access)
                _ = try validateHistory(manifest, access: access)
            case .prepared, .installed, .rollingBack:
                let control = try SyncAccountRecoveryControlFile(synchronize: POSIX.synchronize).observe(access: access)
                if case .absentSource = control.state {
                    try rollbackUnspent(manifest, bytes: bytes, access: access)
                } else {
                    let phase = try InstallOwner(owner: self, access: access, recovering: bytes)
                    try phase.rollback()
                }
            case .rolledBack:
                try synchronizeSelected(bytes, access: access)
            case .committed:
                _ = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
                    journal: FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath)),
                    archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                    control: SyncAccountRecoveryControlFile(synchronize: POSIX.synchronize).observe(access: access), maximumBytes: maximumBytes)
                return true
            }
            let terminal = try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes)
            if let terminal { try handoffTerminal(terminal, access: access) }
            return false
        }
        guard committed else { return nil }
        return try .recoveredOwned(.capture(storage: storage, paths: paths, account: account,
            maximumBytes: maximumBytes, validateContext: { try self.validateContext(self.context) }))
    }

    private func recoverLegacyDerivative(_ bytes: Data, entries: [SyncAccountRecoveryInventory.Entry],
        access: SyncAccountStorage.RecoveryAccess) throws {
        let nextPath = namespace + "/active-next.json"
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        let next = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes)
        if let next {
            guard let nextEntry = entries.first(where: { $0.relativePath == nextPath }), !nextEntry.isDirectory,
                  POSIX.proof(next) == .init(byteCount: nextEntry.byteCount, sha256: nextEntry.sha256) else {
                throw SyncBootstrapError.invalidPhase
            }
        } else {
            guard !entries.contains(where: { $0.relativePath == nextPath }) else { throw SyncBootstrapError.sourceChanged }
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
        if let next, (try? JSONSerialization.jsonObject(with: next, options: [.fragmentsAllowed])) != nil, next != bytes {
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
        if next == nil {
            // A healthy legacy terminal is already selected. Validate the full
            // existing capture without manufacturing another publication.
            _ = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
                journal: FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath)),
                archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                control: control, maximumBytes: maximumBytes)
        }
        try access.validate()
        guard try access.entries() == entries,
              try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == control else {
            throw SyncBootstrapError.sourceChanged
        }
        try synchronizeSelected(bytes, access: access)
        if next == nil {
            guard try access.entries() == entries,
                  try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access) == control else {
                throw SyncBootstrapError.sourceChanged
            }
            return
        }
        try publish(bytes, replacing: bytes, access: access) {
            try access.validate()
            let derivative = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: self.maximumBytes)
            guard try access.entries().filter({ $0.relativePath != nextPath }) == filtered,
                  derivative == next || derivative == bytes,
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
        try io.synchronize(file.value)
        for path in ([namespace] + OwnedBootstrapCodec.parents(namespace).reversed() + [""]) {
            let fd = try POSIX.directory(path, from: access.accountDescriptor)
            try io.synchronize(fd.value)
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
        let admittedNext = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes)
        try revalidate()
        // An existing derivative may be replaced only by the owner of the exact
        // current main after its complete source/history checks.
        let next = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes)
        guard next == admittedNext, next == nil || old != nil else { throw SyncBootstrapError.sourceChanged }
        let flags = O_WRONLY | O_NOFOLLOW | O_CLOEXEC | (next == nil ? O_CREAT | O_EXCL : 0)
        let file = try POSIX.Descriptor(openat(directory.value, "active-next.json", flags, 0o600))
        try POSIX.match(file.value, name: "active-next.json", parent: directory.value, directory: false)
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == old,
              try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == (next ?? Data()) else {
            throw SyncBootstrapError.sourceChanged
        }
        if next != nil, ftruncate(file.value, 0) != 0 { throw SyncAccountStorageError.unavailable }
        try boundary(.selector(.afterNextCreation))
        try POSIX.match(file.value, name: "active-next.json", parent: directory.value, directory: false)
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == old,
              try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == Data() else {
            throw SyncBootstrapError.sourceChanged
        }
        try io.write(file.value, bytes)
        try boundary(.selector(.afterNextWrite))
        try io.synchronize(file.value)
        try boundary(.selector(.afterNextSynchronize))
        try revalidate()
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == old,
              try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == bytes else {
            throw SyncBootstrapError.sourceChanged
        }
        try POSIX.match(file.value, name: "active-next.json", parent: directory.value, directory: false)
        try boundary(.selector(.beforeRename))
        try POSIX.match(file.value, name: "active-next.json", parent: directory.value, directory: false)
        guard try POSIX.read("active.json", parent: directory.value, maximumBytes: maximumBytes) == old,
              try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) == bytes else {
            throw SyncBootstrapError.sourceChanged
        }
        guard renameat(directory.value, "active-next.json", directory.value, "active.json") == 0 else {
            throw SyncAccountStorageError.unavailable
        }
        try boundary(.selector(.afterRename))
        // First establish the rename's namespace/ancestry durability, then
        // perform the exact selected readback and synchronization again.
        for path in ([namespace] + OwnedBootstrapCodec.parents(namespace).reversed() + [""]) {
            let fd = try POSIX.directory(path, from: access.accountDescriptor)
            try io.synchronize(fd.value)
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
        case let .prepared(value), let .rollingBack(value): binding = (value.sourceControlSHA256, value.pendingSnapshotSHA256)
        case let .rolledBack(value): binding = (value.prepared.sourceControlSHA256, value.prepared.pendingSnapshotSHA256)
        default: throw SyncBootstrapError.invalidPhase
        }
        let observer = SyncAccountRecoveryControlFile(synchronize: { _ in })
        let control = try observer.observe(access: access)
        let exactOrigin: Bool
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        if case let .absentSource(source) = control.state,
           case let .bootstrapRollback(id, path, digest) = source.origin,
           id == manifest.id, path == namespace + "/active.json",
           let encoded = try POSIX.read("active.json", parent: directory.value,
               maximumBytes: maximumBytes), digest == OwnedBootstrapCodec.hash(encoded),
           try BootstrapManifestV3.decodeEnvelope(encoded) == manifest,
           { if case .abortedPreparation = manifest.body { return true }; if case .rolledBack = manifest.body { return true }; return false }() {
            exactOrigin = true
        } else { exactOrigin = false }
        guard control.nextBytes == nil, control.mainBytes.map(OwnedBootstrapCodec.hash) == binding.0 || exactOrigin else {
            throw SyncBootstrapError.sourceChanged
        }
        if let prepared = manifest.body.preparedBody, !exactOrigin {
            guard try BootstrapManifestV3.formerSourceDigest(control.state) == prepared.formerSourceSHA256 else {
                throw SyncBootstrapError.sourceChanged
            }
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

    private func handoffTerminal(_ bytes: Data, access: SyncAccountStorage.RecoveryAccess) throws {
        let selected = try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: maximumBytes)
        switch selected.body { case .abortedPreparation, .rolledBack: break; default: throw SyncBootstrapError.invalidPhase }
        // Archive provenance stays archive provenance; there is no invented
        // absentSource for a completed abort of an archive bootstrap.
        if case .archive = selected.sourceProof {
            _ = try SyncAccountRecoveryInventory.capture(access: access, paths: paths, account: account,
                journal: FileSyncMutationJournal(url: paths.workingSet.appendingPathComponent(journalRelativePath)),
                archiveURL: paths.workingSet.appendingPathComponent("projects-v1.json"),
                control: SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access), maximumBytes: maximumBytes)
            return
        }
        let file = SyncAccountRecoveryControlFile(synchronize: io.controlSynchronize)
        let observation = try file.observe(access: access)
        let source: SyncAccountSourceState
        if case let .sourceSpent(value, _, _) = observation.state {
            guard case .rolledBack = selected.body else { throw SyncBootstrapError.sourceChanged }
            let phase = try InstallOwner(owner: self, access: access, recovering: bytes)
            _ = try phase.validatePlacement()
            source = value
        } else {
            try validateSource(selected, access: access)
            guard case let .absentSource(value) = observation.state else { throw SyncBootstrapError.sourceChanged }
            source = value
        }
        let entries = try validateHistory(selected, access: access)
        let origin = SyncAccountSourceOrigin.bootstrapRollback(transactionID: selected.id,
            activeRelativePath: namespace + "/active.json", activeEnvelopeSHA256: OwnedBootstrapCodec.hash(bytes))
        if source.origin == origin {
            try file.synchronize(observation, access: access)
            return
        }
        let replacement = SyncAccountSourceState(authorityID: source.authorityID, generation: UUID(),
            accountIDHash: source.accountIDHash, accountRoot: source.accountRoot,
            accountDevice: source.accountDevice, accountInode: source.accountInode,
            archiveURL: source.archiveURL, journalURL: source.journalURL,
            baselineSHA256: source.baselineSHA256, origin: origin)
        _ = try file.replace(observation, with: .absentSource(replacement), access: access) {
            try access.validate()
            guard try access.entries() == entries,
                  try file.observe(access: access).mainBytes == observation.mainBytes else { throw SyncBootstrapError.sourceChanged }
            let dependencies = try SyncAccountRecoveryInventory.captureSourceDependencies(paths: self.paths,
                journal: FileSyncMutationJournal(url: source.journalURL), archiveURL: source.archiveURL,
                entries: entries, maximumBytes: self.maximumBytes)
            guard dependencies.baseline == source.baselineSHA256 else { throw SyncBootstrapError.sourceChanged }
        }
    }

    /// Only exact successors of this prepared lineage can be an interrupted
    /// publication. Incomplete bytes must prefix one of those same envelopes;
    /// a bounded regular file alone never proves ownership.
    private func validatePreparedDerivative(_ selected: BootstrapManifestV3, bytes: Data,
        entries: [SyncAccountRecoveryInventory.Entry], access: SyncAccountStorage.RecoveryAccess) throws {
        let directory = try POSIX.directory(namespace, from: access.accountDescriptor)
        guard let next = try POSIX.read("active-next.json", parent: directory.value, maximumBytes: maximumBytes) else { return }
        guard let entry = entries.first(where: { $0.relativePath == namespace + "/active-next.json" }),
              !entry.isDirectory, POSIX.proof(next) == .init(byteCount: entry.byteCount, sha256: entry.sha256),
              let prepared = selected.body.preparedBody else { throw SyncBootstrapError.sourceChanged }
        if next == bytes { return }
        let root = selected.transactionRelativePath
        let frozen = entries.filter { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }
        let successors: [BootstrapManifestV3.Body]
        switch selected.body {
        case .prepared: successors = [.installed(prepared), .rollingBack(prepared)]
        case .installed: successors = [.committed(prepared), .rollingBack(prepared)]
        case .rollingBack: successors = [.rolledBack(.init(prepared: prepared, frozenTransactionEntries: frozen))]
        default: successors = []
        }
        let complete = (try? JSONSerialization.jsonObject(with: next, options: [.fragmentsAllowed])) != nil
        if complete { _ = try BootstrapManifestV3.decodeEnvelope(next, maximumBytes: maximumBytes) }
        if bytes.starts(with: next) { return }
        // Native publication emits these canonical bytes. Structural String
        // equality would accept byte-distinct Unicode paths under another hash.
        for body in [selected.body] + successors {
            var candidate = selected; candidate.body = body
            if let encoded = try? candidate.encoded(maximumBytes: maximumBytes),
               complete ? encoded == next : encoded.starts(with: next) { return }
        }
        throw SyncBootstrapError.sourceChanged
    }

    /// Prepared recovery retains its initial source. It must not consume that
    /// source just to enter an install-recovery route.
    private func rollbackUnspent(_ selected: BootstrapManifestV3, bytes: Data,
        access: SyncAccountStorage.RecoveryAccess) throws {
        guard let prepared = selected.body.preparedBody else { throw SyncBootstrapError.invalidPhase }
        try validatePreparedDerivative(selected, bytes: bytes, entries: access.entries(), access: access)
        try synchronizeSelected(bytes, access: access)
        try validateSource(selected, access: access)
        let entries = try validateHistory(selected, access: access)
        let root = selected.transactionRelativePath
        guard let original = entries.first(where: { $0.relativePath == "working-set" && $0.isDirectory }),
              original.device == prepared.originalLiveRoot.device, original.inode == prepared.originalLiveRoot.inode,
              !entries.contains(where: { $0.relativePath == root + "/Displaced" || $0.relativePath == root + "/Failed" }),
              let staged = entries.first(where: { $0.relativePath == root + "/Staged" && $0.isDirectory }),
              staged.device == prepared.stagedRoot.device, staged.inode == prepared.stagedRoot.inode,
              Self.proofs(entries, under: root + "/Original") == selected.original,
              Self.proofs(entries, under: root + "/Staged") == prepared.installed else { throw SyncBootstrapError.sourceChanged }
        var current = selected, currentBytes = bytes
        func revalidate() throws {
            try self.validateSource(current, access: access)
            _ = try self.validateHistory(current, access: access)
            try self.validatePreparedDerivative(current, bytes: currentBytes, entries: access.entries(), access: access)
            guard try access.entries().filter({ $0.relativePath != self.namespace + "/active.json"
                && $0.relativePath != self.namespace + "/active-next.json" }) == entries.filter({
                    $0.relativePath != self.namespace + "/active.json" && $0.relativePath != self.namespace + "/active-next.json"
                }) else { throw SyncBootstrapError.sourceChanged }
        }
        try SyncBootstrapInstallPhases.rollback(persistIntent: {
            var next = current; next.body = .rollingBack(prepared)
            let encoded = try next.encoded(maximumBytes: self.maximumBytes)
            try self.publish(encoded, replacing: currentBytes, access: access, revalidate: revalidate)
            current = next; currentBytes = encoded
        }, hasDisplaced: { false }, validateDisplaced: { throw SyncBootstrapError.sourceChanged },
        hasLive: { true }, move: { _ in throw SyncBootstrapError.sourceChanged },
        validateRestored: revalidate, persistTerminal: {
            let frozen = entries.filter { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }
            try self.synchronizeEntries(frozen, access: access)
            try revalidate()
            var next = current; next.body = .rolledBack(.init(prepared: prepared, frozenTransactionEntries: frozen))
            let encoded = try next.encoded(maximumBytes: self.maximumBytes)
            try self.publish(encoded, replacing: currentBytes, access: access, revalidate: revalidate)
            current = next; currentBytes = encoded
        }, boundary: { point in
            if point == .afterRollbackIntent { try self.boundary(.afterRollbackIntent) }
        })
    }

    /// Exact physical certification shared by the phase owner and later capture.
    /// Authenticated decode verifies the frozen proof; it cannot recreate an
    /// old segment's bytes from its digest after plaintext cleanup.
    static func validateCommitPrefix(_ manifest: BootstrapManifestV3, at location: String,
        entries: [SyncAccountRecoveryInventory.Entry], complete: Bool,
        read: (String) throws -> Data?) throws {
        guard let prepared = manifest.body.preparedBody else { throw SyncBootstrapError.invalidPhase }
        let root = manifest.transactionRelativePath
        let actual = proofs(entries, under: location)
        var state = prepared.installed, known: [String: Data] = [:]
        func proof(_ bytes: Data) -> BootstrapManifestV3.FileProof { .init(bytes: Int64(bytes.count), digest: OwnedBootstrapCodec.hash(bytes)) }
        func temporary(_ path: String, _ id: UUID) -> String {
            let parent = OwnedBootstrapCodec.parent(path), name = String(path.split(separator: "/").last!)
            return (parent.isEmpty ? "" : parent + "/") + "." + name + "." + id.uuidString + ".tmp"
        }
        func partial(_ path: String, _ bytes: Data) -> Bool {
            guard let found = actual[path], found.bytes >= 0, found.bytes <= bytes.count else { return false }
            var candidate = state; candidate[path] = proof(Data(bytes.prefix(Int(found.bytes))))
            return candidate == actual
        }
        func initial(_ path: String) throws -> Data {
            if let bytes = known[path] { return bytes }
            guard let expected = state[path] else { return Data() }
            guard let bytes = try read(root + "/Original/" + path), proof(bytes) == expected else { throw SyncBootstrapError.sourceChanged }
            return bytes
        }
        if !complete, actual == state { return }
        for op in prepared.commitProgram.operations {
            switch op {
            case .synchronize, .reuse: break
            case let .directory(path): state[path + "/"] = .init(bytes: -1, digest: Data())
            case let .replace(path, _, bytes, id):
                if !complete, partial(temporary(path, id), bytes) { return }
                state[path] = proof(bytes); known[path] = bytes
            case let .copyAttachment(path, version, expected, id):
                guard let bytes = try read(root + "/Attachments/" + version.uuidString), POSIX.proof(bytes) == expected.value else { throw SyncBootstrapError.sourceChanged }
                if !complete, partial(temporary(path, id), bytes) { return }
                state[path] = proof(bytes); known[path] = bytes
            case let .appendSegment(_, frames):
                let path = prepared.commitProgram.journalRelativePath + ".segment"
                let before = try initial(path), bytes = before + frames
                if !complete, let current = actual[path], current.bytes >= before.count, current.bytes <= bytes.count {
                    var candidate = state; candidate[path] = proof(Data(bytes.prefix(Int(current.bytes))))
                    if candidate == actual { return }
                }
                state[path] = proof(bytes); known[path] = bytes
            }
            if !complete, actual == state { return }
        }
        guard actual == state else { throw SyncBootstrapError.sourceChanged }
    }

    private static func proofs(_ entries: [SyncAccountRecoveryInventory.Entry], under root: String)
        -> [String: BootstrapManifestV3.FileProof] {
        let prefix = root + "/"
        return Dictionary(uniqueKeysWithValues: entries.filter { $0.relativePath.hasPrefix(prefix) }.map {
            (String($0.relativePath.dropFirst(prefix.count)) + ($0.isDirectory ? "/" : ""),
             .init(bytes: $0.isDirectory ? -1 : $0.byteCount, digest: $0.sha256))
        })
    }

    private func synchronizeEntries(_ entries: [SyncAccountRecoveryInventory.Entry],
        access: SyncAccountStorage.RecoveryAccess) throws {
        for entry in entries.filter({ !$0.isDirectory }) + entries.filter({ $0.isDirectory }).reversed() {
            let parent = try POSIX.directory(OwnedBootstrapCodec.parent(entry.relativePath), from: access.accountDescriptor)
            let name = String(entry.relativePath.split(separator: "/").last!)
            let fd = try POSIX.Descriptor(openat(parent.value, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                | (entry.isDirectory ? O_DIRECTORY : O_NONBLOCK)))
            try POSIX.match(fd.value, name: name, parent: parent.value, directory: entry.isDirectory)
            var status = stat()
            guard fstat(fd.value, &status) == 0, UInt64(status.st_dev) == entry.device,
                  UInt64(status.st_ino) == entry.inode else { throw SyncBootstrapError.sourceChanged }
            try io.synchronize(fd.value)
            try POSIX.match(fd.value, name: name, parent: parent.value, directory: entry.isDirectory)
        }
        for path in [namespace] + OwnedBootstrapCodec.parents(namespace).reversed() + [""] {
            let fd = try POSIX.directory(path, from: access.accountDescriptor)
            try io.synchronize(fd.value)
        }
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
                          value.sourceControlSHA256 == preparing.sourceControlSHA256,
                          value.pendingSnapshotSHA256 == preparing.pendingSnapshotSHA256,
                          try value.formerSourceSHA256 == BootstrapManifestV3.formerSourceDigest(
                            SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access).state),
                          try value.immutableOutputSHA256 == BootstrapManifestV3.immutableOutputDigest(entries: entries,
                            transactionRelativePath: manifest.transactionRelativePath),
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
                    try owner.boundary(.beforeValidation(.backupSource(index: packageIndex, final: false)))
                    try service.validateFrozenPackageSource(package, source: actual)
                    try owner.boundary(.afterValidation(.backupSource(index: packageIndex, final: false)))
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
                    try owner.boundary(.beforeValidation(.backupSource(index: packageIndex, final: true)))
                    try service.validateFrozenPackageSource(package, source: frozenTree(role))
                    try owner.boundary(.afterValidation(.backupSource(index: packageIndex, final: true)))
                    try owner.boundary(.beforeValidation(.backupInspection(index: packageIndex)))
                    _ = try service.inspectPackage(at: owner.paths.accountRoot.appendingPathComponent(
                        rolePath(package.role, package.packageID.uuidString + ".knitnote-backup")))
                    try owner.boundary(.afterValidation(.backupInspection(index: packageIndex)))
                    helpers[index] = locations
                case let .validateLocal(projection, expected):
                    try owner.boundary(.beforeValidation(.localMaterialization))
                    let actual = try ProjectArchiveSyncMapper.materialize(records: projection.records,
                        attachments: stagedSources(program), baseArchive: expected)
                    guard SyncBootstrapTransaction.sameArchive(actual.archive, expected, checkingVersion: false) else { throw SyncBootstrapError.sourceChanged }
                    try owner.boundary(.afterValidation(.localMaterialization))
                case let .validateMaterialization(projection):
                    try owner.boundary(.beforeValidation(.mergedMaterialization))
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
                    try owner.boundary(.afterValidation(.mergedMaterialization))
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
                            try owner.boundary(.beforeValidation(.deletion(step: localIndex)))
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
                            try owner.boundary(.afterValidation(.deletion(step: localIndex)))
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
            let control = try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: access)
            guard control.nextBytes == nil,
                  control.mainBytes.map(OwnedBootstrapCodec.hash) == preparing.sourceControlSHA256 else {
                throw SyncBootstrapError.sourceChanged
            }
            let prepared = try BootstrapManifestV3(id: manifest.id, context: manifest.context,
                livePath: manifest.livePath, journalPath: manifest.journalPath, sourceProof: manifest.sourceProof,
                original: manifest.original, historyHead: preparing.predecessor?.reference ?? manifest.historyHead,
                body: .prepared(.init(installed: installed, mutations: program.mutations,
                    preparationSHA256: OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.envelopePayload(bytes)),
                    sourceControlSHA256: preparing.sourceControlSHA256,
                    formerSourceSHA256: BootstrapManifestV3.formerSourceDigest(control.state),
                    pendingSnapshotSHA256: preparing.pendingSnapshotSHA256,
                    immutableOutputSHA256: BootstrapManifestV3.immutableOutputDigest(entries: entries,
                        transactionRelativePath: manifest.transactionRelativePath),
                    commitProgram: program.commitProgram, originalLiveRoot: liveIdentity, stagedRoot: stagedIdentity)))
            try owner.publish(prepared.encoded(maximumBytes: owner.maximumBytes), replacing: bytes, access: access) {
                try self.validate()
                guard try SyncAccountRecoveryControlFile(synchronize: { _ in }).observe(access: self.access) == control else {
                    throw SyncBootstrapError.sourceChanged
                }
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
