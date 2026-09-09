import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) struct SyncPublicationEvidenceOutputProgramTests {
    @Test func emptySaveStillWritesCompactHeadAndLock() throws {
        // Break caught: treating empty save as a no-op or allocating a temp for the lock.
        var allocations = 0
        let program = try SyncAttachmentPublicationEvidenceFile.planSave(
            .init(), initial: .init(directories: [""], files: []),
            temporaryID: { allocations += 1; return UUID() }
        )
        #expect(allocations == 1)
        #expect(program.actions.count == 3)
        #expect(program.actions[0] == .directory(role: .staged, path: "SyncMetadata"))
        #expect(program.actions[1] == .lock(role: .staged,
            path: "SyncMetadata/.attachment-versions.json.lock", expectedExisting: nil))
        #expect(try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self,
            from: program.compactHeadBytes).allVersions.isEmpty)
    }

    @Test func plannedBytesMatchOrdinarySaveForLegacyAndRecordBackedLineage() throws {
        // Break caught: a second codec or different candidate selection changes real saved bytes.
        for records in [false, true] {
            let evidence = try fixture(records: records)
            #expect(try SyncAttachmentPublicationEvidenceFile.ownedSelectedExistingPaths(evidence)
                == Set([authorityPath(2), authorityPath(3), tombstonePath(3), watchPath]))
            let actual = try ordinaryTree(evidence)
            var calls = 0
            let program = try SyncAttachmentPublicationEvidenceFile.planSave(evidence,
                initial: .init(directories: [""], files: []), temporaryID: { calls += 1; return fixedID(9) })
            #expect(calls == 5) // two authorities, tombstone, Watch and head; same UUID is legal across paths
            #expect(Set(program.finalDirectories) == Set(actual.directories))
            #expect(program.finalFiles.count == actual.files.count)
            for item in program.finalFiles {
                let saved = try #require(actual.files.first { $0.path == item.path })
                #expect(item.bytes == saved.bytes)
                #expect(item.proof == saved.proof)
            }
            let writes = program.steps.compactMap { step -> SyncPublicationEvidenceOutputProgram.Output? in
                if case let .output(output) = step, case .write = output.action { return output }; return nil
            }
            #expect(writes.count == 5)
            for output in writes {
                let bytes = try #require(output.bytes)
                if case let .write(_, path, .create(p), _) = output.action {
                    #expect(p == proof(bytes))
                    #expect(actual.files.first { $0.path == path }?.bytes == bytes)
                } else { Issue.record("new tree must create") }
            }
            #expect(program.compactHeadBytes == actual.files.first { $0.path == head }?.bytes)
            let syncPaths = program.steps.compactMap { step -> String? in
                if case let .synchronizeParentDirectory(path) = step { return path }; return nil
            }
            #expect(syncPaths == ["SyncMetadata", authorityRoot, authorityRoot + "/20",
                tombstoneRoot, tombstoneRoot + "/20", watchRoot, watchRoot + "/20"])
            #expect(program.actions.compactMap(immutablePath) == [authorityPath(2), authorityPath(3), tombstonePath(3), watchPath])
        }
    }

    @Test func semanticReuseRetainsNoncanonicalBytesAndBareTombstone() throws {
        // Break caught: semantic equality being mistaken for byte equality, or full-record-only tombstones.
        let evidence = try fixture()
        let initial = try ordinaryTree(evidence)
        let files = try initial.files.map { file -> SyncPublicationEvidenceFrozenTree.File in
            guard file.path != lock, file.path != head else { return file }
            let existingBytes = try #require(file.bytes)
            var json = try #require(JSONSerialization.jsonObject(with: existingBytes) as? [String: Any])
            if file.path == tombstonePath(3) { json.removeValue(forKey: "record") }
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            #expect(bytes != file.bytes)
            return .init(path: file.path, proof: proof(bytes), bytes: bytes)
        }
        var calls = 0
        let program = try SyncAttachmentPublicationEvidenceFile.planSave(evidence,
            initial: .init(directories: initial.directories, files: files), temporaryID: { calls += 1; return fixedID(9) })
        #expect(calls == 1)
        #expect(program.actions.first == .lock(role: .staged, path: lock, expectedExisting: proof(Data())))
        var reuses = 0
        for (index, step) in program.steps.enumerated() {
            guard case let .output(output) = step, case let .reuseExact(_, path, p) = output.action else { continue }
            reuses += 1
            let old = try #require(files.first { $0.path == path })
            #expect(output.bytes == nil)
            #expect(p == old.proof)
            #expect(program.finalFiles.first { $0.path == path }?.bytes == old.bytes)
            guard case let .synchronizeParentDirectory(syncPath) = program.steps[index + 1] else {
                Issue.record("reuse requires parent synchronization"); continue
            }
            #expect(syncPath == path)
        }
        #expect(reuses == 4)
    }

    @Test func selectedSemanticFailuresAllocateNoTemporaries() throws {
        // Break caught: planning installs/reuses conflicting or unread selected immutable evidence.
        let evidence = try fixture(), initial = try ordinaryTree(evidence)
        for change in ["missing", "corrupt", "nil-record", "snapshot", "watch", "wrong-id"] {
            let files = try initial.files.map { file -> SyncPublicationEvidenceFrozenTree.File in
                let target = change == "watch" ? watchPath : authorityPath(2)
                guard file.path == target else { return file }
                if change == "missing" { return .init(path: file.path, proof: file.proof, bytes: nil) }
                if change == "corrupt" { return item(file.path, Data("corrupt".utf8)) }
                let existingBytes = try #require(file.bytes)
                var json = try #require(JSONSerialization.jsonObject(with: existingBytes) as? [String: Any])
                if change == "nil-record" { json.removeValue(forKey: "record") }
                if change == "snapshot" {
                    var record = try #require(json["record"] as? [String: Any])
                    record["createdAt"] = 999
                    json["record"] = record
                }
                if change == "wrong-id" {
                    // A fully self-consistent envelope for another ID must fail
                    // the expected-path binding, not an internal record mismatch.
                    let other = try #require(initial.files.first { $0.path == authorityPath(3) }?.bytes)
                    return item(file.path, other)
                }
                if change == "watch" {
                    var p = try #require(json["proof"] as? [String: Any])
                    p["rejection"] = "counterMissing"; json["proof"] = p
                }
                return item(file.path, try JSONSerialization.data(withJSONObject: json))
            }
            var calls = 0
            do {
                _ = try SyncAttachmentPublicationEvidenceFile.planSave(evidence,
                    initial: .init(directories: initial.directories, files: files), temporaryID: { calls += 1; return UUID() })
                Issue.record("accepted \(change)")
            } catch {
                if change == "missing" { #expect(error as? SyncPublicationEvidenceOutputError == .missingSelectedBytes) }
                else { #expect(error as? SyncPublicationTransactionFileError == .corrupt) }
            }
            #expect(calls == 0)
        }
        let legacy = try ordinaryTree(fixture(records: false))
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            try SyncAttachmentPublicationEvidenceFile.planSave(evidence, initial: legacy)
        }
        let mismatchedProof = initial.files.map { file in
            file.path == authorityPath(2) ? SyncPublicationEvidenceFrozenTree.File(path: file.path, proof: proof(Data()), bytes: file.bytes) : file
        }
        var calls = 0
        #expect(throws: SyncPublicationEvidenceOutputError.invalidProof) {
            try SyncAttachmentPublicationEvidenceFile.planSave(evidence, initial: .init(directories: initial.directories, files: mismatchedProof),
                temporaryID: { calls += 1; return UUID() })
        }
        #expect(calls == 0)
    }

    @Test func malformedOldHeadAndUnselectedHistoryArePreservedOrOverwrittenWithoutDecode() throws {
        let old = item(head, Data("old malformed head".utf8))
        let historical = item(authorityRoot + "/ff/history.json", Data("unselected malformed JSON".utf8))
        let hidden = item(".hidden", Data([1, 2]))
        let initial = SyncPublicationEvidenceFrozenTree(directories: ["", "SyncMetadata", authorityRoot, authorityRoot + "/ff", authorityRoot + "/ee"], files: [old, historical, hidden])
        let program = try SyncAttachmentPublicationEvidenceFile.planSave(.init(), initial: initial)
        #expect(program.finalDirectories == initial.directories)
        #expect(program.finalFiles.first { $0.path == historical.path }?.bytes == historical.bytes)
        #expect(program.finalFiles.first { $0.path == hidden.path }?.proof == hidden.proof)
        guard case let .write(_, path, .replace(expected, new), _) = program.actions.last else {
            Issue.record("head must replace"); return
        }
        #expect(path == head)
        #expect(expected == old.proof)
        #expect(new == proof(program.compactHeadBytes))
    }

    @Test func treeAndProofRejectionsPrecedeTemporaryAllocation() throws {
        // Break caught: dictionaries erase raw duplicates/aliases or allow undeclared parents.
        let empty = proof(Data())
        let invalid: [SyncPublicationEvidenceFrozenTree] = [
            .init(directories: [], files: []), .init(directories: ["", ""], files: []),
            .init(directories: ["", "A", "a"], files: []),
            .init(directories: ["", "é", "e\u{301}"], files: []),
            .init(directories: ["", "é"], files: [item("e\u{301}/child", Data())]),
            .init(directories: ["", "A"], files: [item("a", Data())]),
            .init(directories: [""], files: [item("x", Data()), item("x", Data())]),
            .init(directories: ["", "missing/child"], files: []),
            .init(directories: [""], files: [item("missing/child", Data())]),
            .init(directories: ["", "../escape"], files: []),
            .init(directories: ["", "SyncMetadata", head], files: []),
            .init(directories: ["", "SyncMetadata", lock], files: []),
            .init(directories: ["", "SyncMetadata"], files: [item(lock, Data([1]))]),
            .init(directories: ["", "SyncMetadata"], files: [item(authorityRoot, Data())]),
            .init(directories: [""], files: [.init(path: "x", proof: empty, bytes: Data([1]))]),
            .init(directories: [""], files: [.init(path: "x", proof: .init(byteCount: -1, sha256: empty.sha256), bytes: nil)]),
            .init(directories: [""], files: [.init(path: "x", proof: .init(byteCount: 0, sha256: Data([1])), bytes: nil)]),
            .init(directories: [""], files: [.init(path: "x", proof: .init(byteCount: 100_000_001, sha256: empty.sha256), bytes: nil)])
        ]
        for tree in invalid {
            var calls = 0
            #expect(throws: SyncPublicationEvidenceOutputError.self) {
                try SyncAttachmentPublicationEvidenceFile.planSave(.init(), initial: tree,
                    temporaryID: { calls += 1; return UUID() })
            }
            #expect(calls == 0)
        }
        let admitted = try SyncAttachmentPublicationEvidenceFile.planSave(.init(), initial: .init(directories: [""],
            files: [.init(path: "large", proof: .init(byteCount: 100_000_000, sha256: empty.sha256), bytes: nil)]))
        #expect(admitted.finalFiles.first { $0.path == "large" }?.bytes == nil)
    }

    @Test func selectedDestinationAndShardCannotHaveWrongTypes() throws {
        let candidate = try fixture()
        let wrongShard = SyncPublicationEvidenceFrozenTree(directories: ["", "SyncMetadata", authorityRoot], files: [item(authorityRoot + "/20", Data())])
        let wrongDestination = SyncPublicationEvidenceFrozenTree(directories: ["", "SyncMetadata", authorityRoot, authorityRoot + "/20", authorityPath(2)], files: [])
        for tree in [wrongShard, wrongDestination] {
            var calls = 0
            #expect(throws: SyncPublicationEvidenceOutputError.invalidTree) {
                try SyncAttachmentPublicationEvidenceFile.planSave(candidate, initial: tree, temporaryID: { calls += 1; return UUID() })
            }
            #expect(calls == 0)
        }
    }

    @Test func temporaryCollisionIncludesInitialFilesAndAliases() throws {
        for name in [".attachment-versions.json.\(fixedID(9).uuidString).tmp", ".ATTACHMENT-VERSIONS.JSON.\(fixedID(9).uuidString).TMP"] {
            var calls = 0
            #expect(throws: SyncPublicationEvidenceOutputError.collision) {
                try SyncAttachmentPublicationEvidenceFile.planSave(.init(), initial: .init(directories: ["", "SyncMetadata"],
                    files: [item("SyncMetadata/" + name, Data())]), temporaryID: { calls += 1; return fixedID(9) })
            }
            #expect(calls == 1)
        }
    }

    @Test func invalidDecodedCandidateMapsToCorruptBeforeTemporaryAllocation() throws {
        // Break caught: leaking ordinary validation errors from the new pure input boundary.
        let bytes = try JSONEncoder().encode(fixture(records: false))
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var versions = try #require(json["versions"] as? [[String: Any]])
        versions[0]["mediaType"] = ""
        json["versions"] = versions
        let invalid = try JSONDecoder().decode(SyncAttachmentPublicationEvidence.self, from: JSONSerialization.data(withJSONObject: json))
        var calls = 0
        #expect(throws: SyncPublicationTransactionFileError.corrupt) {
            try SyncAttachmentPublicationEvidenceFile.planSave(invalid, initial: .init(directories: [""], files: []),
                temporaryID: { calls += 1; return UUID() })
        }
        #expect(calls == 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: SyncAttachmentVersionError.invalidMetadata) {
            try SyncAttachmentPublicationEvidenceFile(url: root.appendingPathComponent("attachment-versions.json")).save(invalid)
        }
    }

    @Test func exactImmutableEnvelopeCapsAndCompactHeadCountGuard() throws {
        // Real valid envelopes padded with legal JSON whitespace exercise shared bounded decoders.
        let evidence = try fixture(), tree = try ordinaryTree(evidence)
        for (path, cap) in [(authorityPath(2), 16 * 1_024 * 1_024), (tombstonePath(3), 16 * 1_024 * 1_024), (watchPath, 1_024 * 1_024)] {
            for extra in [0, 1] {
                let files = try tree.files.map { file -> SyncPublicationEvidenceFrozenTree.File in
                    guard file.path == path else { return file }
                    var bytes = try #require(file.bytes)
                    bytes.append(Data(repeating: 32, count: cap + extra - bytes.count))
                    return item(path, bytes)
                }
                var calls = 0
                if extra == 0 {
                    let p = try SyncAttachmentPublicationEvidenceFile.planSave(evidence,
                        initial: .init(directories: tree.directories, files: files), temporaryID: { calls += 1; return UUID() })
                    #expect(p.finalFiles.first { $0.path == path }?.proof.byteCount == Int64(cap))
                    #expect(calls == 1)
                } else {
                    #expect(throws: SyncPublicationTransactionFileError.corrupt) {
                        try SyncAttachmentPublicationEvidenceFile.planSave(evidence,
                            initial: .init(directories: tree.directories, files: files), temporaryID: { calls += 1; return UUID() })
                    }
                    #expect(calls == 0)
                }
            }
        }
        try SyncAttachmentPublicationEvidenceFile.validateCompactHeadByteCount(64 * 1_024 * 1_024)
        #expect(throws: SyncPublicationTransactionFileError.corrupt) { try SyncAttachmentPublicationEvidenceFile.validateCompactHeadByteCount(64 * 1_024 * 1_024 + 1) }
        #expect(throws: SyncPublicationTransactionFileError.corrupt) { try SyncAttachmentPublicationEvidenceFile.validateCompactHeadByteCount(-1) }
    }

    @Test func completeCopyPrefixComposesOnceAndChangedDependenciesFail() throws {
        let evidence = try fixture(), actual = try ordinaryTree(evidence)
        let tree = SyncPublicationEvidenceFrozenTree(directories: actual.directories + ["unrelated"],
            files: actual.files + [item("unrelated/.hidden", Data("untouched".utf8))])
        let program = try SyncAttachmentPublicationEvidenceFile.planSave(evidence, initial: tree, temporaryID: { fixedID(99) })
        let prefix = prefixActions(tree)
        let plan = try finite(prefix + program.actions)
        #expect(plan.actionCount == prefix.count + program.actions.count)
        for file in program.finalFiles {
            #expect(plan.potentialEntries.contains { $0.relativePath.hasSuffix("/Staged/" + file.path) && $0.byteCount >= file.proof.byteCount })
        }
        #expect(plan.potentialEntries.contains { $0.relativePath.hasSuffix("/.attachment-versions.json.\(fixedID(99).uuidString).tmp") })
        #expect(plan.reservations[.staged]?.maximumEntryCount == plan.potentialEntries.filter { $0.relativePath.contains("/Staged") }.count)
        #expect(throws: SyncBootstrapOutputPlanner.Error.missingParent) { try finite(program.actions) }
        let missingHead = prefix.filter { actionPath($0) != head }
        #expect(throws: SyncBootstrapOutputPlanner.Error.invalidTransition) { try finite(missingHead + program.actions) }
        let changed = prefix.map { action -> SyncBootstrapOutputAction in
            if case let .write(role, path, _, id) = action, path == authorityPath(2) {
                return .write(role: role, path: path, mode: .create(proof(Data("changed".utf8))), temporaryID: id)
            }; return action
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.invalidTransition) { try finite(changed + program.actions) }
        #expect(throws: SyncBootstrapOutputPlanner.Error.missingParent) { try finite(Array(prefix.dropFirst()) + program.actions) }
        let tempCollision = prefix.map { action -> SyncBootstrapOutputAction in
            if case let .write(role, path, mode, _) = action, path == head { return .write(role: role, path: path, mode: mode, temporaryID: fixedID(99)) }; return action
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.collision) { try finite(tempCollision + program.actions) }
        let changedParent = prefix.map { action -> SyncBootstrapOutputAction in
            if case .directory(.staged, "SyncMetadata") = action { return .directory(role: .staged, path: "syncmetadata") }; return action
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.missingParent) { try finite(changedParent + program.actions) }
    }

    @Test @MainActor func deletionHelperAndPublicationComposeOverCompleteProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try SyncDeletionCaptureProgramTests.request(root: root)
        let deletion = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request],
            allocations: [SyncDeletionCaptureProgramTests.allocation(request)])
        let frozen = SyncPublicationEvidenceFrozenTree(
            directories: [""] + deletion.finalDirectories.map { $0.isEmpty ? ".sync-deletions" : ".sync-deletions/" + $0 },
            files: deletion.finalFiles.map { .init(path: ".sync-deletions/" + $0.key, proof: $0.value, bytes: nil) })
        let publication = try SyncAttachmentPublicationEvidenceFile.planSave(.init(), initial: frozen)
        let deletionActions = deletion.steps.compactMap { step -> SyncBootstrapOutputAction? in
            if case let .output(output) = step { return output.action }; return nil
        }
        let prefix: [SyncBootstrapOutputAction] = [.directory(role: .staged, path: ""), .directory(role: .validationMerged, path: "")]
        let plan = try finite(prefix + deletionActions + publication.actions)
        #expect(plan.actionCount == prefix.count + deletionActions.count + publication.actions.count)
        for file in frozen.files {
            #expect(publication.finalFiles.first { $0.path == file.path }?.proof == file.proof)
        }
        #expect(plan.potentialEntries.contains { $0.relativePath.hasSuffix("/Staged/.sync-deletions/ledger.json") })
    }

    private var head: String { "SyncMetadata/attachment-versions.json" }
    private var lock: String { "SyncMetadata/.attachment-versions.json.lock" }
    private var authorityRoot: String { "SyncMetadata/attachment-versions.attachment-records" }
    private var tombstoneRoot: String { "SyncMetadata/attachment-versions.attachment-tombstones" }
    private var watchRoot: String { "SyncMetadata/attachment-versions.watch-proofs" }
    private var watchPath: String { watchRoot + "/20/" + fixedID(4).uuidString.lowercased() + ".json" }
    private func authorityPath(_ n: Int) -> String { authorityRoot + "/20/" + fixedID(n).uuidString.lowercased() + ".json" }
    private func tombstonePath(_ n: Int) -> String { tombstoneRoot + "/20/" + fixedID(n).uuidString.lowercased() + ".json" }
    private func fixedID(_ n: Int) -> UUID { UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))! }
    private func proof(_ bytes: Data) -> SyncBootstrapOutputProof { .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes))) }
    private func item(_ path: String, _ bytes: Data) -> SyncPublicationEvidenceFrozenTree.File { .init(path: path, proof: proof(bytes), bytes: bytes) }
    private func fixture(records: Bool = true) throws -> SyncAttachmentPublicationEvidence {
        let slot = SyncAttachmentSlot(owner: .init(kind: .project, uuid: fixedID(1)), role: "project-photo", slotID: "primary")
        let first = try SyncAttachmentVersion.issuing(slot: slot, contentSHA256: proof(Data("first".utf8)).sha256, byteCount: 5,
            mediaType: "image/jpeg", displayFilename: "first.jpg", versionID: fixedID(2))
        let second = try SyncAttachmentVersion.issuing(slot: slot, contentSHA256: proof(Data("second".utf8)).sha256, byteCount: 6,
            mediaType: "image/jpeg", displayFilename: "second.jpg", replacesVersionID: first.versionID, versionID: fixedID(3))
        let attached: [SyncRecord] = [first, second].map { version in
            let deleted = version.versionID == second.versionID
            let stamp = SyncMutationStamp(logicalRevision: deleted ? 2 : 1, modifiedAt: Date(timeIntervalSince1970: deleted ? 2 : 1), deviceID: "evidence-test")
            return .init(schemaVersion: 1, id: .init(kind: .attachment, uuid: version.versionID), createdAt: Date(timeIntervalSince1970: 1),
                entityRevision: 1, payload: .init(fields: [:], attachment: version), relationships: [.init(role: "owner", target: slot.owner)],
                deletedAt: .init(value: deleted ? stamp.modifiedAt : nil, stamp: stamp))
        }
        let command = WatchCounterCommand(id: fixedID(4), projectID: fixedID(1), counterID: fixedID(5), operation: .increment, createdAt: Date(timeIntervalSince1970: 1))
        let watch = try SyncProcessedWatchCommandProof(id: command.id, rejection: .projectMissing, commandIdentity: .init(command),
            preparedCommand: nil, effectProof: nil, processingStamp: .init(logicalRevision: 0, modifiedAt: Date(timeIntervalSince1970: 3), deviceID: "evidence-test"))
        return .init(versions: [second, first], deletedVersionIDs: [second.versionID], watchCommandProofs: [watch],
            attachmentRecords: records ? attached : [], storageVersion: records ? 2 : 1)
    }
    private func ordinaryTree(_ evidence: SyncAttachmentPublicationEvidence) throws -> SyncPublicationEvidenceFrozenTree {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("SyncMetadata"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try SyncAttachmentPublicationEvidenceFile(url: root.appendingPathComponent(head)).save(evidence)
        var dirs = [""], files: [SyncPublicationEvidenceFrozenTree.File] = []
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]))
        for case let url as URL in enumerator {
            let normalizedPath = url.resolvingSymlinksInPath().path
            let normalizedRoot = root.resolvingSymlinksInPath().path
            #expect(normalizedPath.hasPrefix(normalizedRoot + "/"))
            let path = String(normalizedPath.dropFirst(normalizedRoot.count + 1))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true { dirs.append(path) }
            else { #expect(values.isRegularFile == true); files.append(item(path, try Data(contentsOf: url))) }
        }
        return .init(directories: dirs, files: files)
    }
    private func actionPath(_ action: SyncBootstrapOutputAction) -> String {
        switch action {
        case let .directory(_, p), let .write(_, p, _, _), let .reuseExact(_, p, _), let .lock(_, p, _): return p
        }
    }
    private func immutablePath(_ action: SyncBootstrapOutputAction) -> String? {
        let path = actionPath(action)
        switch action { case .write, .reuseExact: return path == head ? nil : path; default: return nil }
    }
    private func prefixActions(_ tree: SyncPublicationEvidenceFrozenTree) -> [SyncBootstrapOutputAction] {
        tree.directories.sorted { $0.utf8.count < $1.utf8.count }.map { .directory(role: .staged, path: $0) }
        + tree.files.enumerated().map { index, file in .write(role: .staged, path: file.path, mode: .create(file.proof), temporaryID: fixedID(100 + index)) }
    }
    private func finite(_ actions: [SyncBootstrapOutputAction]) throws -> SyncBootstrapOutputPlan {
        try SyncBootstrapOutputPlanner.plan(accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
            transactionID: fixedID(90), actions: actions)
    }
}
