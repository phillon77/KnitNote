import Foundation

/// Pure codec-derived lifetime accounting. These descriptions never certify
/// physical validation, create source authority, or issue write capabilities.
enum SyncBootstrapRecoveryBudget {
    struct Scenario {
        let name: String
        let inventoryBytes: Int
        let recoveryEnvelopeBytes: Int
        let nextRetryPreparingBytes: Int?
    }
    struct Result {
        let preparingEnvelope: Data
        let maximumRecoveryEnvelopeBytes: Int
        let scenarios: [Scenario]
    }

    static func compose(inventory: SyncAccountRecoveryInventory, control: SyncAccountControlObservation,
        context: SyncBootstrapContext, original: [String: BootstrapManifestV3.FileProof],
        sourceProof: SyncBootstrapSourceProof, builder: SyncBootstrapOwnedProgramBuilder,
        reservation: SyncBootstrapOutputPlan, deletion: SyncDeletionCaptureProgram,
        commit: BootstrapManifestV3.CommitProgram, mutations: [SyncMutation], finalPending: [SyncMutation],
        finalJournalFiles: [String: BootstrapManifestV3.OutputProof],
        namespace: String, predecessor: BootstrapManifestV3.PendingHistoryRecord?,
        pendingSnapshotSHA256: Data, existingHistory: [Data] = [], existingHead: BootstrapHistoryRef? = nil,
        maximumBytes: Int) throws -> Result {
        typealias M = BootstrapManifestV3
        typealias E = SyncAccountRecoveryInventory.Entry
        let digest = Data(repeating: 255, count: 32)
        let root = namespace + "/" + reservation.transactionID.uuidString
        let activePath = namespace + "/active.json"
        let nextPath = namespace + "/active-next.json"
        let allocation = M.OutputAllocation(transactionID: reservation.transactionID,
            allowedRoles: M.Role.allCases.filter { role in reservation.reservations.keys.contains { $0.rawValue == role.directoryName } },
            roleLimits: M.Role.allCases.compactMap { role in
                guard let outputRole = SyncBootstrapOutputRole(rawValue: role.directoryName),
                      let value = reservation.reservations[outputRole] else { return nil }
                return .init(role: role, maximumEntryCount: value.maximumEntryCount,
                    reservedEncodedProofBytes: Int64(value.reservedEncodedProofBytes))
            })
        let preparation = M.Preparing(sourceControlSHA256: control.mainBytes.map(OwnedBootstrapCodec.hash),
            pendingSnapshotSHA256: pendingSnapshotSHA256, outputAllocation: allocation, predecessor: predecessor)
        let preparing = M(id: reservation.transactionID, context: context,
            livePath: inventory.archiveURL.deletingLastPathComponent().standardizedFileURL.path,
            journalPath: commit.journalRelativePath, sourceProof: sourceProof, original: original,
            historyHead: existingHead, body: .preparing(preparation))
        guard namespace == OwnedBootstrapCodec.parent(preparing.transactionRelativePath) else {
            throw SyncBootstrapError.corrupt
        }
        let preparingBytes = try preparing.encoded(maximumBytes: maximumBytes)
        let suppliedHistory = existingHistory.map { bytes in
            SyncBootstrapHistory.SuppliedRecord(relativePath: namespace + "/History/"
                + OwnedBootstrapCodec.hex(OwnedBootstrapCodec.hash(bytes)) + ".json", bytes: bytes)
        }
        _ = try SyncBootstrapHistory.validate(current: preparing, records: suppliedHistory,
            accountEntries: inventory.entries, maximumBytes: maximumBytes)
        let preparationDigest = OwnedBootstrapCodec.hash(try OwnedBootstrapCodec.encode(preparing))
        let head = predecessor?.reference ?? existingHead
        let history = predecessor.map { [$0.record] + existingHistory } ?? existingHistory
        var scaffold = inventory.entries.filter { $0.relativePath != activePath && $0.relativePath != nextPath }
        var occupied = Set(scaffold.map(\.relativePath))
        var sequence: UInt64 = 0
        func entry(_ path: String, directory: Bool, count: Int64 = 0, hash: Data? = nil) -> E {
            sequence += 1
            return .init(relativePath: path, isDirectory: directory, byteCount: directory ? 0 : count,
                sha256: directory ? Data() : (hash ?? digest), device: UInt64.max, inode: UInt64.max - sequence)
        }
        for value in reservation.potentialEntries where !value.relativePath.hasPrefix(root + "/") && value.relativePath != root {
            if occupied.insert(value.relativePath).inserted { scaffold.append(entry(value.relativePath, directory: true)) }
        }
        if let predecessor {
            let directory = namespace + "/History"
            if occupied.insert(directory).inserted { scaffold.append(entry(directory, directory: true)) }
            let path = directory + "/" + OwnedBootstrapCodec.hex(predecessor.reference.sha256) + ".json"
            if occupied.insert(path).inserted {
                scaffold.append(entry(path, directory: false, count: Int64(predecessor.record.count),
                    hash: predecessor.reference.sha256))
            }
        }
        let originalLive = try require(inventory.entries.first { $0.relativePath == "working-set" && $0.isDirectory })
        var completed: [E] = [entry(root, directory: true)]
        for role in SyncBootstrapOutputRole.allCases {
            guard let tree = builder.trees[role] else { continue }
            for path in tree.directories.sorted(by: OwnedBootstrapCodec.pathOrder) {
                completed.append(entry(root + "/" + role.rawValue + (path.isEmpty ? "" : "/" + path), directory: true))
            }
            for path in tree.files.keys.sorted() {
                let proof = tree.files[path]!.proof
                completed.append(entry(root + "/" + role.rawValue + "/" + path,
                    directory: false, count: proof.byteCount, hash: proof.sha256))
            }
        }
        completed.sort { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
        let stagedRoot = try require(completed.first { $0.relativePath == root + "/Staged" })
        let staged = try require(builder.trees[.staged])
        var installed = Dictionary(uniqueKeysWithValues: staged.files.map { ($0.key, M.FileProof(bytes: $0.value.proof.byteCount, digest: $0.value.proof.sha256)) })
        for path in staged.directories where !path.isEmpty { installed[path + "/"] = .init(bytes: -1, digest: Data()) }
        let prepared = try M.PreparedBody(installed: installed, mutations: mutations, preparationSHA256: preparationDigest,
            sourceControlSHA256: preparation.sourceControlSHA256, formerSourceSHA256: M.formerSourceDigest(control.state),
            pendingSnapshotSHA256: pendingSnapshotSHA256,
            immutableOutputSHA256: M.immutableOutputDigest(entries: completed, transactionRelativePath: root),
            commitProgram: commit, originalLiveRoot: .init(device: originalLive.device, inode: originalLive.inode),
            stagedRoot: .init(device: stagedRoot.device, inode: stagedRoot.inode))
        var manifest = M(id: preparing.id, context: context, livePath: preparing.livePath,
            journalPath: preparing.journalPath, sourceProof: sourceProof, original: original,
            historyHead: head, body: preparing.body)
        var abortedEntries = reservation.potentialEntries.filter { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }
            .map { entry($0.relativePath, directory: $0.isDirectory, count: $0.byteCount) }
        abortedEntries.sort { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
        manifest.body = .abortedPreparation(.init(preparationSHA256: preparationDigest,
            sourceControlSHA256: preparation.sourceControlSHA256, pendingSnapshotSHA256: pendingSnapshotSHA256,
            outputAllocation: allocation, frozenOutputEntries: abortedEntries))
        let abortSize = try manifest.prospectiveEnvelopeByteCount()
        let abortManifest = manifest
        manifest.body = .rolledBack(.init(prepared: prepared, frozenTransactionEntries: completed))
        let rollbackSize = try manifest.prospectiveEnvelopeByteCount()
        let rollbackManifest = manifest
        // Continuation below composes mutually exclusive postinstall placements.
        return try postinstall(inventory: inventory, control: control, preparing: preparing,
            preparingBytes: preparingBytes, prepared: prepared, head: head, history: history,
            builder: builder, deletion: deletion, finalPending: finalPending, scaffold: scaffold,
            completed: completed, finalJournalFiles: finalJournalFiles,
            abortedEntries: abortedEntries, abortManifest: abortManifest,
            abortSize: abortSize, rollbackManifest: rollbackManifest, rollbackSize: rollbackSize,
            stagedRoot: stagedRoot, maximumBytes: maximumBytes)
    }

    private static func postinstall(inventory: SyncAccountRecoveryInventory, control: SyncAccountControlObservation,
        preparing: BootstrapManifestV3, preparingBytes: Data, prepared: BootstrapManifestV3.PreparedBody,
        head: BootstrapHistoryRef?, history: [Data], builder: SyncBootstrapOwnedProgramBuilder,
        deletion: SyncDeletionCaptureProgram, finalPending: [SyncMutation],
        scaffold: [SyncAccountRecoveryInventory.Entry], completed: [SyncAccountRecoveryInventory.Entry],
        finalJournalFiles: [String: BootstrapManifestV3.OutputProof],
        abortedEntries: [SyncAccountRecoveryInventory.Entry], abortManifest: BootstrapManifestV3, abortSize: Int,
        rollbackManifest: BootstrapManifestV3, rollbackSize: Int,
        stagedRoot: SyncAccountRecoveryInventory.Entry, maximumBytes: Int) throws -> Result {
        typealias M = BootstrapManifestV3
        typealias E = SyncAccountRecoveryInventory.Entry
        let root = preparing.transactionRelativePath
        let namespace = OwnedBootstrapCodec.parent(root)
        let activePath = namespace + "/active.json", nextPath = namespace + "/active-next.json"
        let commit = prepared.commitProgram
        let digest = Data(repeating: 255, count: 32)
        let staged = try require(builder.trees[.staged])
        var liveFiles = staged.files.mapValues(\.proof)
        var liveDirectories = staged.directories
        var failureFiles = liveFiles
        var failureDirectories = liveDirectories
        func temporary(_ path: String, _ id: UUID) -> String {
            let parent = OwnedBootstrapCodec.parent(path), name = String(path.split(separator: "/").last!)
            return (parent.isEmpty ? "" : parent + "/") + "." + name + "." + id.uuidString + ".tmp"
        }
        func retain(_ path: String, _ proof: SyncBootstrapOutputProof) {
            if let old = failureFiles[path], old.byteCount > proof.byteCount { return }
            failureFiles[path] = .init(byteCount: proof.byteCount, sha256: digest)
        }
        for operation in commit.operations {
            switch operation {
            case let .directory(path): liveDirectories.insert(path); failureDirectories.insert(path)
            case let .replace(path, _, bytes, id):
                let proof = SyncBootstrapOwnedProgramBuilder.proof(bytes)
                liveFiles[path] = proof; retain(path, proof); retain(temporary(path, id), proof)
            case let .copyAttachment(path, _, value, id):
                liveFiles[path] = value.value; retain(path, value.value); retain(temporary(path, id), value.value)
            case let .appendSegment(_, frames):
                let path = commit.journalRelativePath + ".segment"
                let count = try add(Int(liveFiles[path]?.byteCount ?? 0), frames.count)
                guard count <= 64 * 1_024 * 1_024 else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
                let proof = SyncBootstrapOutputProof(byteCount: Int64(count), sha256: digest)
                liveFiles[path] = proof; retain(path, proof)
            case .reuse, .synchronize: break
            }
        }
        // Native successful projection has the exact append/compaction hashes.
        // The failed tree separately retains conservative torn-prefix proofs.
        for (path, proof) in finalJournalFiles {
            guard liveFiles[path]?.byteCount == proof.byteCount else { throw SyncBootstrapError.corrupt }
            liveFiles[path] = proof.value
        }
        var sequence = UInt64(scaffold.count + completed.count + abortedEntries.count)
        func entry(_ path: String, directory: Bool, count: Int64 = 0, hash: Data? = nil) -> E {
            sequence += 1
            return .init(relativePath: path, isDirectory: directory, byteCount: directory ? 0 : count,
                sha256: directory ? Data() : (hash ?? digest), device: UInt64.max, inode: UInt64.max - sequence)
        }
        func placed(_ prefix: String, directories: Set<String>, files: [String: SyncBootstrapOutputProof]) -> [E] {
            let dirs = directories.map { entry(prefix + ($0.isEmpty ? "" : "/" + $0), directory: true) }
            let values = files.map { entry(prefix + "/" + $0.key, directory: false, count: $0.value.byteCount, hash: $0.value.sha256) }
            return (dirs + values).sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
        }
        let remaining = completed.filter { $0.relativePath != root + "/Staged" && !$0.relativePath.hasPrefix(root + "/Staged/") }
        var failed = placed(root + "/Failed", directories: failureDirectories, files: failureFiles)
        failed = failed.map { value in
            guard value.relativePath == root + "/Failed" else { return value }
            return E(relativePath: value.relativePath, isDirectory: true, byteCount: 0, sha256: Data(),
                device: stagedRoot.device, inode: stagedRoot.inode)
        }
        let failedTree = (remaining + failed).sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) }
        var manifest = rollbackManifest
        manifest.body = .rolledBack(.init(prepared: prepared, frozenTransactionEntries: failedTree))
        let failedSize = try manifest.prospectiveEnvelopeByteCount()
        let failedManifest = manifest
        manifest.body = .committed(prepared)
        let committedSize = try manifest.prospectiveEnvelopeByteCount()
        let committedLive = placed("working-set", directories: liveDirectories, files: liveFiles)
        let displaced = inventory.entries.filter { $0.relativePath == "working-set" || $0.relativePath.hasPrefix("working-set/") }.map {
            E(relativePath: root + "/Displaced" + String($0.relativePath.dropFirst("working-set".count)),
                isDirectory: $0.isDirectory, byteCount: $0.byteCount, sha256: $0.sha256, device: $0.device, inode: $0.inode)
        }
        let committedBase = scaffold.filter { $0.relativePath != "working-set" && !$0.relativePath.hasPrefix("working-set/") }
        let committedEntries = committedBase + remaining + displaced + committedLive
        let oldPacketCount = try inventory.packet.encoded().count
        let finalFiles = try packetFiles(finalPending, root: inventory.accountRoot)
        let finalPacketCount = try SyncPendingRecoveryPacket.projectedEncodedByteCount(account: inventory.account,
            accountRoot: inventory.accountRoot, mutations: finalPending, files: finalFiles)
        let ledgerBytes: Data?
        if let bytes = deletion.finalManifestBytes { ledgerBytes = bytes }
        else if case let .present(bytes, _, _) = deletion.expectedInitialLedger { ledgerBytes = bytes }
        else { ledgerBytes = nil }
        let archiveProof = try require(prepared.installed["projects-v1.json"])
        let export = try ledgerBytes.map { bytes in
            try SyncDeletionLedger.projectedRecoveryExport(archiveURL: inventory.archiveURL, manifestBytes: bytes,
                files: deletion.finalFiles, pending: finalPending, maximumBytes: maximumBytes,
                archiveSHA256: { archiveProof.digest })
        }
        let deletionFiles = export?.files.map {
            SyncPendingRecoveryPacket.File(relativePath: "working-set/.sync-deletions/" + $0.retainedRelativePath,
                byteCount: $0.byteCount, sha256: $0.sha256, bytes: Data())
        } ?? []
        var scenarios: [Scenario] = []
        let placements: [(String, M, Int, [E], [E], Bool)] = [
            ("abortedPreparing", abortManifest, abortSize, abortedEntries, scaffold + abortedEntries, false),
            ("preparedRolledBack", rollbackManifest, rollbackSize, completed, scaffold + completed, false),
            ("journalFailedRolledBack", failedManifest, failedSize, failedTree, scaffold + failedTree, false),
            ("committed", manifest, committedSize, remaining + displaced, committedEntries, true)
        ]
        for (name, terminal, terminalSize, tree, entries, committed) in placements {
            guard terminalSize <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
            var scenarioEntries = entries
            scenarioEntries.append(entry(activePath, directory: false, count: Int64(terminalSize)))
            scenarioEntries.append(entry(nextPath, directory: false, count: Int64(max(terminalSize, preparingBytes.count))))
            let state = try futureSource(inventory: inventory, control: control, terminal: terminal,
                committed: committed, archiveProof: archiveProof)
            let evidence = SyncAccountRecoveryInventory.BootstrapEvidence(activeEnvelope: Data(), historyRecords: history)
            let inventorySize = try inventory.projectedEncodedByteCount(
                entries: scenarioEntries.sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) },
                packetByteCount: committed ? finalPacketCount : oldPacketCount,
                deletionFiles: committed ? deletionFiles : inventory.deletionFiles,
                sourceAuthority: state.authority, bootstrapEvidence: evidence,
                deletionLedgerBytes: committed ? export?.manifest : inventory.deletionLedger,
                markers: committed ? (export?.pendingMarkerVersions ?? []) : inventory.pendingMarkerVersions,
                futureActiveEnvelopeByteCount: terminalSize,
                futureRollbackEnvelopeByteCount: state.hasRollbackEnvelope ? terminalSize : nil)
            let envelopeSize = try envelopeCount(inventorySize, control: state.control)
            guard envelopeSize <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
            scenarios.append(.init(name: name, inventoryBytes: inventorySize,
                recoveryEnvelopeBytes: envelopeSize, nextRetryPreparingBytes: nil))
            if !committed {
                let retry = try retryBound(inventory: inventory, preparing: preparing, terminal: terminal,
                    terminalSize: terminalSize, tree: tree, entries: scenarioEntries, head: head, history: history,
                    state: state, packetBytes: oldPacketCount, maximumBytes: maximumBytes)
                scenarios.append(.init(name: name + "NextRetry", inventoryBytes: retry.inventory,
                    recoveryEnvelopeBytes: retry.envelope, nextRetryPreparingBytes: retry.preparing))
            }
        }
        return .init(preparingEnvelope: preparingBytes,
            maximumRecoveryEnvelopeBytes: scenarios.map(\.recoveryEnvelopeBytes).max()!, scenarios: scenarios)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw SyncBootstrapError.corrupt }; return value
    }

    private static func envelopeCount(_ inventoryBytes: Int, control: SyncAccountControlObservation) throws -> Int {
        try SyncAccountRecoveryTransaction.projectedEnvelopeByteCount(inventoryByteCount: inventoryBytes,
            captureID: UUID(), accountDevice: UInt64.max, accountInode: UInt64.max,
            temporarySession: ".decrypted-temporary/00000000-0000-0000-0000-000000000001", control: control)
    }

    private static func retryBound(inventory: SyncAccountRecoveryInventory, preparing: BootstrapManifestV3,
        terminal: BootstrapManifestV3, terminalSize: Int, tree: [SyncAccountRecoveryInventory.Entry],
        entries: [SyncAccountRecoveryInventory.Entry], head: BootstrapHistoryRef?, history: [Data],
        state: (authority: SyncAccountRecoverySourceAuthority, control: SyncAccountControlObservation, hasRollbackEnvelope: Bool),
        packetBytes: Int, maximumBytes: Int) throws -> (inventory: Int, envelope: Int, preparing: Int) {
        let digest = Data(repeating: 255, count: 32)
        let record = BootstrapHistoryRecordV1(version: 1, accountIDHash: inventory.account.accountIDHash,
            livePath: terminal.livePath, journalPath: terminal.journalPath, transactionID: terminal.id,
            terminalEnvelope: Data(), treeEntries: tree, previous: head)
        let recordSize = try record.prospectiveEnvelopeByteCount(terminalByteCount: terminalSize)
        let (recordCount, overflow) = (head?.recordCount ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        let reference = BootstrapHistoryRef(sha256: digest, byteCount: Int64(recordSize),
            recordCount: recordCount,
            chainByteCount: Int64(try add(Int(head?.chainByteCount ?? 0), recordSize)))
        guard case let .preparing(initial) = preparing.body else { throw SyncBootstrapError.corrupt }
        let retry = BootstrapManifestV3(id: preparing.id, context: preparing.context, livePath: preparing.livePath,
            journalPath: preparing.journalPath, sourceProof: preparing.sourceProof, original: preparing.original,
            historyHead: head, body: .preparing(.init(sourceControlSHA256: state.control.mainBytes.map { _ in digest },
                pendingSnapshotSHA256: initial.pendingSnapshotSHA256, outputAllocation: initial.outputAllocation,
                predecessor: .init(record: Data(), reference: reference))))
        let retrySize = try retry.prospectiveEnvelopeByteCount(pendingRecordByteCount: recordSize)
        guard retrySize <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        let namespace = OwnedBootstrapCodec.parent(preparing.transactionRelativePath)
        let selectorCount = max(terminalSize, retrySize)
        var future = entries.map { entry -> SyncAccountRecoveryInventory.Entry in
            guard entry.relativePath == namespace + "/active.json" || entry.relativePath == namespace + "/active-next.json" else { return entry }
            return .init(relativePath: entry.relativePath, isDirectory: false, byteCount: Int64(selectorCount),
                sha256: digest, device: UInt64.max, inode: entry.inode)
        }
        let historyRoot = namespace + "/History"
        if !future.contains(where: { $0.relativePath == historyRoot }) {
            future.append(.init(relativePath: historyRoot, isDirectory: true, byteCount: 0, sha256: Data(),
                device: UInt64.max, inode: UInt64.max))
        }
        future.append(.init(relativePath: historyRoot + "/" + OwnedBootstrapCodec.hex(digest) + ".json",
            isDirectory: false, byteCount: Int64(recordSize), sha256: digest, device: UInt64.max, inode: UInt64.max - 1))
        let count = try inventory.projectedEncodedByteCount(
            entries: future.sorted { OwnedBootstrapCodec.pathOrder($0.relativePath, $1.relativePath) },
            packetByteCount: packetBytes, deletionFiles: inventory.deletionFiles, sourceAuthority: state.authority,
            bootstrapEvidence: .init(activeEnvelope: Data(), historyRecords: [Data()] + history),
            futureActiveEnvelopeByteCount: selectorCount,
            futureRollbackEnvelopeByteCount: state.hasRollbackEnvelope ? selectorCount : nil,
            futureHistoryRecordByteCounts: [recordSize])
        let envelope = try envelopeCount(count, control: state.control)
        guard envelope <= maximumBytes else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        return (count, envelope, retrySize)
    }

    private static func packetFiles(_ mutations: [SyncMutation], root: URL) throws -> [SyncPendingRecoveryPacket.File] {
        var values: [String: SyncPendingRecoveryPacket.File] = [:]
        for source in mutations.compactMap(\.attachmentSource) {
            guard source.fileURL.path.hasPrefix(root.path + "/") else { throw SyncBootstrapError.unsafePath }
            let path = String(source.fileURL.path.dropFirst(root.path.count + 1))
            if let old = values[path], old.byteCount != source.byteCount || old.sha256 != source.contentSHA256 { throw SyncBootstrapError.corrupt }
            values[path] = .init(relativePath: path, byteCount: source.byteCount, sha256: source.contentSHA256, bytes: Data())
        }
        return values.keys.sorted().map { values[$0]! }
    }

    private static func futureSource(inventory: SyncAccountRecoveryInventory, control: SyncAccountControlObservation,
        terminal: BootstrapManifestV3, committed: Bool, archiveProof: BootstrapManifestV3.FileProof)
        throws -> (authority: SyncAccountRecoverySourceAuthority, control: SyncAccountControlObservation, hasRollbackEnvelope: Bool) {
        let digest = Data(repeating: 255, count: 32)
        // Selection controls are excluded from Entry inventories. Check their
        // independent actual wire cap instead of adding them to file entries.
        let intent = SyncAccountRecoveryIntent(formatVersion: 1, accountIDHash: inventory.account.accountIDHash,
            accountRoot: inventory.accountRoot, archiveURL: inventory.archiveURL, journalURL: inventory.journalURL,
            vaultID: UUID(), captureID: UUID(), envelopeSHA256: digest, packetSHA256: digest,
            inventoryFingerprint: digest, phase: .sealed)
        _ = try SyncAccountRecoveryControlFile.encode(.selectedRecovery(intent, predecessorSHA256: digest),
            predecessorSHA256: digest)
        if case let .absent(evidence)? = inventory.sourceAuthority {
            // Every capturable absent-source terminal, including an abort,
            // requires the later owner's durable terminal-origin handoff.
            // Capacity templates below use real control codecs; their paired
            // maximum-width slots are not a validated observation or authority.
            let prior = evidence.state
            let spent = try SyncAccountRecoveryControlFile.encode(.sourceSpent(prior, transactionID: terminal.id,
                preparedManifestSHA256: digest), predecessorSHA256: control.mainBytes.map(OwnedBootstrapCodec.hash))
            if committed {
                return (.archive(relativePath: "working-set/projects-v1.json", sha256: archiveProof.digest),
                    .init(mainBytes: spent, nextBytes: spent, state: nil), false)
            }
            let source = SyncAccountSourceState(authorityID: UUID(), generation: UUID(), accountIDHash: prior.accountIDHash,
                accountRoot: prior.accountRoot, accountDevice: prior.accountDevice, accountInode: prior.accountInode,
                archiveURL: prior.archiveURL, journalURL: prior.journalURL, baselineSHA256: prior.baselineSHA256,
                origin: .bootstrapRollback(transactionID: terminal.id,
                    activeRelativePath: OwnedBootstrapCodec.parent(terminal.transactionRelativePath) + "/active.json",
                    activeEnvelopeSHA256: digest))
            let bytes = try SyncAccountRecoveryControlFile.encode(.absentSource(source), predecessorSHA256: digest)
            return (.absent(.init(state: source, rollbackEnvelope: Data())),
                .init(mainBytes: bytes, nextBytes: spent, state: nil), true)
        }
        let proof = committed ? archiveProof : try require(terminal.original["projects-v1.json"])
        return (.archive(relativePath: "working-set/projects-v1.json", sha256: proof.digest), control, false)
    }
    static func add(_ values: Int...) throws -> Int {
        try values.reduce(0) { total, value in
            let sum = total.addingReportingOverflow(value)
            guard value >= 0, !sum.overflow, sum.partialValue <= 100_000_000 else {
                throw SyncAccountRecoveryTransaction.Error.tooLarge
            }
            return sum.partialValue
        }
    }

    static func base64Bytes(_ count: Int) throws -> Int {
        guard (0...100_000_000).contains(count) else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        return try add(((count + 2) / 3) * 4)
    }

    /// Exact maximum for an arbitrary Data value under the owned codec's slash
    /// escaping, excluding quotes. Structured JSON uses this conservatively.
    static func escapedBase64Maximum(_ count: Int) throws -> Int {
        guard (0...100_000_000).contains(count) else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        let slashCount = (count / 3) * 4 + ((count % 3) * 4) / 3
        return try add(base64Bytes(count), slashCount)
    }

    static func ownedEnvelopeMaximum(payloadByteCount: Int) throws -> Int {
        // The checksum is itself unknown future binary and therefore uses the
        // maximum slash spelling. Payload is structured JSON: this is a proved
        // conservative codec bound, not a jointly attainable serialized size.
        let overhead = try OwnedBootstrapCodec.encode(OwnedBootstrapCodec.Envelope(payload: Data(),
            digest: Data(repeating: 255, count: 32))).count
        return try add(overhead, escapedBase64Maximum(payloadByteCount))
    }
    /// Overhead is the actual empty-Data envelope encoded without escaping slashes,
    /// as used by the recovery codec; Base64 then occupies four bytes per group.
    static func inventoryAllowance(maximumEnvelopeBytes: Int, fixedOverheadBytes: Int) throws -> Int {
        guard (0...100_000_000).contains(maximumEnvelopeBytes), fixedOverheadBytes >= 0 else {
            throw SyncAccountRecoveryTransaction.Error.tooLarge
        }
        let remaining = maximumEnvelopeBytes.subtractingReportingOverflow(fixedOverheadBytes)
        guard !remaining.overflow, remaining.partialValue >= 0 else {
            throw SyncAccountRecoveryTransaction.Error.tooLarge
        }
        let raw = (remaining.partialValue / 4).multipliedReportingOverflow(by: 3)
        guard !raw.overflow else { throw SyncAccountRecoveryTransaction.Error.tooLarge }
        return raw.partialValue
    }
}
