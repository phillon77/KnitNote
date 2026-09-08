import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite(.serialized) @MainActor struct SyncDeletionCaptureProgramTests {
    static func request(root: URL, media: Bool = false) throws -> SyncDeletionCaptureRequest {
        let archive: ProjectArchive
        if media {
            _ = try BackupFixture.writeCompleteArchive(to: root)
            archive = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: root.appendingPathComponent("projects-v1.json")))
        } else { archive = .init(version: ProjectArchive.currentVersion, projects: [try StoredProject(name: "Deleted")]) }
        let package = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "sender")
        let stamp = SyncMutationStamp(logicalRevision: 20, modifiedAt: Date(timeIntervalSince1970: 200), deviceID: "sender")
        let deleted = package.records.map { original -> SyncRecord in
            var record = original
            record.deletedAt = .init(value: stamp.modifiedAt, stamp: stamp)
            let children = package.records.filter { item in
                item.relationships.contains { $0.target == record.id && ["project", "owner"].contains($0.role) }
            }.map(\.id)
            if record.id.kind != .attachment && !children.isEmpty { record.payload.deletionCascade = .init(value: children, stamp: stamp) }
            return record
        }
        return .init(domain: .init(rootIDs: Set(deleted.filter { $0.relationships.isEmpty }.map(\.id)), ownedRecords: deleted,
            supportingParentIDs: [], removedReminders: [:], restorableRecordIDs: Set(deleted.map(\.id))),
            exactRemovalVersions: try deleted.map { try .init(record: $0) }, deletedAt: stamp.modifiedAt,
            currentRecords: deleted, currentArchive: .init(version: ProjectArchive.currentVersion, projects: []),
            attachments: package.attachments.mapValues { .init(byteCount: $0.byteCount, sha256: $0.contentSHA256) },
            restoreRelativePaths: package.attachments.mapValues { String($0.fileURL.path.dropFirst(root.path.count + 1)) },
            supportingAttachments: [:], counterReminderContext: .init())
    }
    static func allocation(_ request: SyncDeletionCaptureRequest) throws -> SyncDeletionCaptureAllocation {
        let heads = try SyncAttachmentLineage(records: request.domain.ownedRecords).headsBySlot.values.flatMap { $0 }
        return .init(stagedEntryID: UUID(), liveValidationID: UUID(), restoredValidationID: UUID(),
            restoredAttachmentIDs: Dictionary(uniqueKeysWithValues: heads.filter { request.domain.selectedLiveIDs.contains($0.id) }.map { ($0.id.uuid, UUID()) }))
    }
    static func frozen(_ program: SyncDeletionCaptureProgram) throws -> SyncDeletionFrozenLedger {
        .present(manifestBytes: try #require(program.finalManifestBytes), directories: program.finalDirectories, files: program.finalFiles)
    }
    static func withoutMedia(_ request: SyncDeletionCaptureRequest) throws -> SyncDeletionCaptureRequest {
        let earlier = SyncMutationStamp(logicalRevision: 19, modifiedAt: request.deletedAt.addingTimeInterval(-1), deviceID: "sender")
        let records = request.domain.ownedRecords.filter { $0.id.kind != .attachment }.map { original -> SyncRecord in
            var record = original
            record.deletedAt = .init(value: earlier.modifiedAt, stamp: earlier)
            if let cascade = record.payload.deletionCascade {
                record.payload.deletionCascade = .init(value: cascade.value.filter { $0.kind != .attachment }, stamp: earlier)
            }
            return record
        }
        return .init(domain: .init(rootIDs: request.domain.rootIDs, ownedRecords: records, supportingParentIDs: [],
            removedReminders: [:], restorableRecordIDs: Set(records.map(\.id))),
            exactRemovalVersions: try records.map { try .init(record: $0) }, deletedAt: request.deletedAt,
            currentRecords: records + request.currentRecords.filter { $0.id.kind == .attachment }, currentArchive: request.currentArchive,
            attachments: [:], restoreRelativePaths: [:], supportingAttachments: [:], counterReminderContext: .init())
    }
    @Test func absentLedgerRetainsEmptyStageAndThreeSnapshotsWithUnfulfilledValidations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.request(root: root), allocation = try Self.allocation(request)
        var calls = 0
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request], allocations: [allocation], temporaryID: { calls += 1; return UUID() })
        #expect(calls == 3)
        #expect(program.steps.filter { if case .validate = $0 { true } else { false } }.count == 2)
        #expect(program.finalDirectories.contains(allocation.stagedEntryID.uuidString))
        #expect(program.finalFiles.count == 2)
        #expect(program.captures.count == 1)
        #expect(program.captures[0].retainedEntry.id == allocation.stagedEntryID)
        #expect(program.captures[0].retainedEntry.domain == request.domain)
        #expect(program.finalManifestBytes == program.captures[0].finalManifestBytes)
        let ledgerRoot = root.appendingPathComponent("ordinary")
        let ledger = try SyncDeletionLedger(root: ledgerRoot)
        #expect(try Data(contentsOf: ledgerRoot.appendingPathComponent("ledger.json")) == program.initialManifestBytes)
        let id = try ledger.captureIncomingDeleted(domain: request.domain, exactRemovalVersions: request.exactRemovalVersions,
            attachments: [:], restoreRelativePaths: [:], deletedAt: request.deletedAt, currentRecords: request.currentRecords,
            currentArchive: request.currentArchive, sourceRoots: [root])
        let ordinary = try #require(try ledger.recentlyDeleted().first)
        #expect(ordinary.id == id)
        #expect(ordinary.domain == program.captures[0].retainedEntry.domain)
        #expect(ordinary.exactRemovalVersions == program.captures[0].retainedEntry.exactRemovalVersions)
        #expect(ordinary.deletedAt == program.captures[0].retainedEntry.deletedAt)
        let replayRoot = root.appendingPathComponent("snapshot-replay")
        _ = try SyncDeletionLedger(root: replayRoot)
        try program.captures[0].stagedManifestBytes.write(to: replayRoot.appendingPathComponent("ledger.json"))
        #expect(try SyncDeletionLedger(root: replayRoot).recentlyDeleted().isEmpty)
        try program.captures[0].finalManifestBytes.write(to: replayRoot.appendingPathComponent("ledger.json"))
        #expect(try SyncDeletionLedger(root: replayRoot).recentlyDeleted() == [program.captures[0].retainedEntry])
    }
    @Test func noRequestsDoNotValidateLedgerOrAllocateIDs() throws {
        let bad = SyncDeletionFrozenLedger.present(manifestBytes: Data([1]), directories: [], files: [:])
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: bad, requests: [], allocations: [], temporaryID: { Issue.record("unexpected ID"); return UUID() })
        #expect(program.steps.isEmpty)
        #expect(program.finalManifestBytes == nil)
    }
    @Test func emptyRequestsRejectMismatchedAllocationCountWithoutIDs() throws {
        var calls = 0
        #expect(throws: (any Error).self) {
            try SyncDeletionLedger.planIncomingCaptures(initial: .present(manifestBytes: Data([1]), directories: [], files: [:]),
                requests: [], allocations: [.init(stagedEntryID: UUID(), liveValidationID: UUID(), restoredValidationID: UUID(), restoredAttachmentIDs: [:])],
                temporaryID: { calls += 1; return UUID() })
        }
        #expect(calls == 0)
    }

    @Test func capturesPreserveUnrelatedGroupsAcrossEncodedSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try Self.request(root: root), b = try Self.request(root: root)
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [a, b], allocations: [Self.allocation(a), Self.allocation(b)])
        let replay = root.appendingPathComponent("replay")
        _ = try SyncDeletionLedger(root: replay)
        try program.captures[1].stagedManifestBytes.write(to: replay.appendingPathComponent("ledger.json"))
        #expect(try SyncDeletionLedger(root: replay).recentlyDeleted() == [program.captures[0].retainedEntry])
        try program.captures[1].finalManifestBytes.write(to: replay.appendingPathComponent("ledger.json"))
        #expect(try SyncDeletionLedger(root: replay).recentlyDeleted() == program.captures.map(\.retainedEntry))
    }
    @Test func mediaCopiesAndMultipleCaptureReferencesAreBoundToEarlierWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.request(root: root, media: true)
        let a = try Self.allocation(request), b = try Self.allocation(request)
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request, request], allocations: [a, b])
        #expect(program.captures[1].retainedEntry.id == a.stagedEntryID)
        #expect(program.finalDirectories.contains(b.stagedEntryID.uuidString))
        var writes: [Int: SyncBootstrapOutputProof] = [:]
        for (index, step) in program.steps.enumerated() {
            switch step {
            case let .output(output):
                if case let .write(_, _, mode, _) = output.action {
                    let proof: SyncBootstrapOutputProof
                    switch mode { case let .create(p): proof = p; case let .replace(_, p): proof = p }
                    writes[index] = proof
                    switch try #require(output.content) {
                    case let .bytes(data): #expect(proof == .init(byteCount: Int64(data.count), sha256: Data(SHA256.hash(data: data))))
                    case let .copy(source, sourceProof):
                        #expect(proof == sourceProof)
                        if case let .earlierOutput(previous) = source { #expect(previous < index); #expect(writes[previous] == proof) }
                    }
                } else { #expect(output.content == nil) }
            case let .validate(job):
                for source in job.sources.values { #expect(source < index); #expect(writes[source] != nil) }
            }
        }
        #expect(program.steps.contains { if case let .output(o) = $0, case .reuseExact = o.action { true } else { false } })
    }

    @Test func invalidFrozenTreesAndAllocationsRejectBeforeTemporaryIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.request(root: root), allocation = try Self.allocation(request)
        let initial = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request], allocations: [allocation])
        let bytes = try #require(initial.finalManifestBytes)
        var variants: [SyncDeletionFrozenLedger] = [
            .present(manifestBytes: bytes, directories: [""], files: [:]),
            .present(manifestBytes: Data([1]), directories: [""], files: ["ledger.json": SyncDeletionCaptureProgramBuilder.proof(Data([1]))])
        ]
        for bad in ["lock", "proof", "size", "parent", "case", "unicode", "type", "unsafe"] {
            var files = initial.finalFiles, dirs = initial.finalDirectories
            switch bad {
            case "lock": files[".ledger.json.lock"] = .init(byteCount: 1, sha256: Data(repeating: 1, count: 32))
            case "proof": files["ledger.json"] = .init(byteCount: Int64(bytes.count), sha256: Data(repeating: 1, count: 32))
            case "size": files["historic"] = .init(byteCount: 100_000_001, sha256: Data(repeating: 1, count: 32))
            case "parent": files["missing/file"] = .init(byteCount: 0, sha256: Data(repeating: 1, count: 32))
            case "case": dirs.insert("Case"); dirs.insert("case")
            case "unicode": dirs.insert("caf\u{e9}"); files["cafe\u{301}/file"] = .init(byteCount: 0, sha256: Data(repeating: 1, count: 32))
            case "type": dirs.insert("ledger.json")
            default: files["../escape"] = .init(byteCount: 0, sha256: Data(repeating: 1, count: 32))
            }
            variants.append(.present(manifestBytes: bytes, directories: dirs, files: files))
        }
        for variant in variants {
            var calls = 0
            #expect(throws: (any Error).self) {
                try SyncDeletionLedger.planIncomingCaptures(initial: variant, requests: [request], allocations: [Self.allocation(request)], temporaryID: { calls += 1; return UUID() })
            }
            #expect(calls == 0)
        }
        var calls = 0
        #expect(throws: (any Error).self) { try SyncDeletionLedger.planIncomingCaptures(initial: .absent,
            requests: [request, request], allocations: [allocation, allocation], temporaryID: { calls += 1; return UUID() }) }
        #expect(calls == 0)
        #expect(throws: (any Error).self) { try SyncDeletionLedger.planIncomingCaptures(initial: .absent,
            requests: [request], allocations: [], temporaryID: { calls += 1; return UUID() }) }
        #expect(calls == 0)
        let repeated = UUID()
        #expect(throws: (any Error).self) { try SyncDeletionLedger.planIncomingCaptures(initial: .absent,
            requests: [request], allocations: [allocation], temporaryID: { repeated }) }
    }

    @Test func exactSizeHistoricalFilesAndFullPrefixBudgetArePreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.request(root: root)
        let original = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request], allocations: [Self.allocation(request)])
        var files = original.finalFiles
        files["historical.bin"] = .init(byteCount: 100_000_000, sha256: Data(repeating: 3, count: 32))
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: .present(manifestBytes: try #require(original.finalManifestBytes),
            directories: original.finalDirectories.union(["unreferenced"]), files: files), requests: [request], allocations: [Self.allocation(request)])
        #expect(program.finalFiles["historical.bin"] == files["historical.bin"])
        #expect(program.finalDirectories.contains("unreferenced"))
        var actions: [SyncBootstrapOutputAction] = [.directory(role: .staged, path: ""), .directory(role: .validationMerged, path: "")]
        for path in original.finalDirectories.union(["unreferenced"]).sorted(by: { $0.count < $1.count }) {
            actions.append(.directory(role: .staged, path: path.isEmpty ? ".sync-deletions" : ".sync-deletions/" + path))
        }
        for (path, proof) in files { actions.append(.write(role: .staged, path: ".sync-deletions/" + path, mode: .create(proof), temporaryID: UUID())) }
        actions += program.steps.compactMap { if case let .output(o) = $0 { o.action } else { nil } }
        let plan = try SyncBootstrapOutputPlanner.plan(accountIDHash: String(repeating: "a", count: 64),
            livePathSHA256: String(repeating: "b", count: 64), transactionID: UUID(), actions: actions)
        #expect(plan.actionCount == actions.count)
        #expect(throws: (any Error).self) { try SyncBootstrapOutputPlanner.plan(accountIDHash: String(repeating: "a", count: 64),
            livePathSHA256: String(repeating: "b", count: 64), transactionID: UUID(), actions: actions, maximumMetadataBytes: 10) }
    }

    @Test func priorRetainedFallbackUsesInitialAndEarlierOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try Self.request(root: root, media: true), stripped = try Self.withoutMedia(media)
        let first = try Self.allocation(media), second = try Self.allocation(media)
        let combined = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [media, stripped], allocations: [first, second])
        #expect(combined.captures[1].retainedEntry.files.count == media.attachments.count)
        let initial = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [media], allocations: [first])
        let later = try SyncDeletionLedger.planIncomingCaptures(initial: Self.frozen(initial), requests: [stripped], allocations: [second])
        #expect(later.steps.contains { step in
            if case let .output(output) = step, case let .copy(source, _)? = output.content, case .initialRetained = source { true } else { false }
        })
        let initialFree = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [stripped], allocations: [Self.allocation(stripped)])
        let created = try SyncDeletionLedger.planIncomingCaptures(initial: Self.frozen(initialFree), requests: [media], allocations: [Self.allocation(media)])
        let priorID = initialFree.captures[0].retainedEntry.id
        #expect(created.captures[0].retainedEntry.files.allSatisfy { $0.retainedRelativePath.hasPrefix(priorID.uuidString + "/") })
        #expect(created.steps.contains { step in
            if case let .output(output) = step, case let .write(.staged, path, .create, _) = output.action {
                return path.hasPrefix(".sync-deletions/" + priorID.uuidString + "/")
            }
            return false
        })
        var conflicting = initialFree.finalFiles
        let target = priorID.uuidString + "/" + (try #require(media.attachments.keys.first)).uuidString + ".retained"
        conflicting[target] = .init(byteCount: 1, sha256: Data(repeating: 4, count: 32))
        var calls = 0
        #expect(throws: (any Error).self) { try SyncDeletionLedger.planIncomingCaptures(initial: .present(manifestBytes: try #require(initialFree.finalManifestBytes),
            directories: initialFree.finalDirectories, files: conflicting), requests: [media], allocations: [Self.allocation(media)], temporaryID: { calls += 1; return UUID() }) }
        #expect(calls == 0)
    }

    @Test func supportingScratchRequiresRealMapperReadsForBothValidationJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = try Self.request(root: root, media: true)
        let photoPath = try #require(removed.restoreRelativePaths.first { $0.value.hasPrefix("ProjectPhotos/") }?.value)
        var liveProject = try StoredProject(name: "Live supporting photo")
        liveProject.setPhotoFilename(URL(fileURLWithPath: photoPath).lastPathComponent)
        let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [liveProject])
        let live = try ProjectArchiveSyncMapper.export(archive: archive, liveRoot: root, deviceID: "local")
        let request = SyncDeletionCaptureRequest(domain: removed.domain, exactRemovalVersions: removed.exactRemovalVersions,
            deletedAt: removed.deletedAt, currentRecords: removed.currentRecords + live.records, currentArchive: archive,
            attachments: removed.attachments, restoreRelativePaths: removed.restoreRelativePaths,
            supportingAttachments: live.attachments.mapValues { .init(byteCount: $0.byteCount, sha256: $0.contentSHA256) }, counterReminderContext: .init())
        let allocation = try Self.allocation(request)
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request], allocations: [allocation])
        var sourceURLs = live.attachments.mapValues(\.fileURL)
        for (id, path) in request.restoreRelativePaths { sourceURLs[id] = root.appendingPathComponent(path) }
        var scratch: [Int: SyncAttachmentSource] = [:]
        var jobs = 0
        for (index, step) in program.steps.enumerated() {
            if case let .output(output) = step,
               case let .write(.validationMerged, path, _, _) = output.action,
               case let .copy(.incoming(_, attachmentID), proof)? = output.content {
                #expect(path.hasPrefix("DeletionValidation/"))
                let destination = root.appendingPathComponent("scratch").appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: try #require(sourceURLs[attachmentID]), to: destination)
                scratch[index] = .init(fileURL: destination, contentSHA256: proof.sha256, byteCount: proof.byteCount, isJournalStaged: true)
            }
            if case let .validate(job) = step {
                jobs += 1
                let sources = try job.sources.mapValues { try #require(scratch[$0]) }
                #expect(!sources.isEmpty)
                if let context = job.counterReminderContext {
                    _ = try SyncMergeEngine().merge(local: job.records, remote: [], pendingLocal: [], counterReminderContext: context)
                }
                let result = try ProjectArchiveSyncMapper.materialize(records: job.records, attachments: sources, baseArchive: job.baseArchive)
                switch job.comparison {
                case let .liveArchive(expected): #expect(result.archive.projects == expected.projects)
                case let .restorationPaths(expected):
                    let actual = Dictionary(uniqueKeysWithValues: result.files.map { ($0.version.slot, $0.relativePath) })
                    #expect(expected.allSatisfy { actual[$0.key] == $0.value })
                }
                let source = try #require(sources.values.first)
                let bytes = try Data(contentsOf: source.fileURL)
                try FileManager.default.removeItem(at: source.fileURL)
                #expect(throws: (any Error).self) { try ProjectArchiveSyncMapper.materialize(records: job.records, attachments: sources, baseArchive: job.baseArchive) }
                try bytes.write(to: source.fileURL)
            }
        }
        #expect(jobs == 2)
        #expect(scratch.count == live.attachments.count * 2 + request.attachments.count)
        #expect(!program.finalDirectories.contains { $0.contains("DeletionValidation") })
    }

    @Test func interruptedPurgeRejectsWithoutChangingPhysicalTree() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.request(root: root, media: true)
        let ledger = try SyncDeletionLedger(root: root.appendingPathComponent("ledger"))
        let sources = try Dictionary(uniqueKeysWithValues: request.attachments.map { id, proof in
            (id, try SyncAttachmentSource(fileURL: root.appendingPathComponent(request.restoreRelativePaths[id]!), contentSHA256: proof.sha256, byteCount: proof.byteCount))
        })
        _ = try ledger.captureIncomingDeleted(domain: request.domain, exactRemovalVersions: request.exactRemovalVersions,
            attachments: sources, restoreRelativePaths: request.restoreRelativePaths, deletedAt: request.deletedAt,
            currentRecords: request.currentRecords, currentArchive: request.currentArchive, sourceRoots: [root])
        #expect(throws: (any Error).self) {
            try ledger.purge(now: request.deletedAt.addingTimeInterval(2_592_000), references: .init(acknowledgedRemovalVersionIDs: Set(request.exactRemovalVersions.map(\.versionID))),
                afterIntent: { throw SyncDeletionLedgerError.unavailable })
        }
        var dirs: Set<String> = [""], files: [String: SyncBootstrapOutputProof] = [:]
        var bytes: [String: Data] = [:], dates: [String: Date] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: ledger.root.path) {
            let url = ledger.root.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            dates[path] = attributes[.modificationDate] as? Date
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { dirs.insert(path) }
            else { let data = try Data(contentsOf: url); bytes[path] = data; files[path] = SyncDeletionCaptureProgramBuilder.proof(data) }
        }
        var calls = 0
        #expect(throws: (any Error).self) { try SyncDeletionLedger.planIncomingCaptures(initial: .present(manifestBytes: try #require(bytes["ledger.json"]),
            directories: dirs, files: files), requests: [request], allocations: [Self.allocation(request)], temporaryID: { calls += 1; return UUID() }) }
        #expect(calls == 0)
        for (path, data) in bytes { #expect(try Data(contentsOf: ledger.root.appendingPathComponent(path)) == data) }
        for (path, date) in dates { #expect(try FileManager.default.attributesOfItem(atPath: ledger.root.appendingPathComponent(path).path)[.modificationDate] as? Date == date) }
        let reopened = try SyncDeletionLedger(root: ledger.root)
        #expect(try reopened.recentlyDeleted().isEmpty)
        #expect(try !reopened.pendingDeletionMarkerVersions().isEmpty)
    }

    @Test func exactEnvelopeLimitUsesSuppliedBytesAndRejectsOneExtraByteBeforeIDs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try Self.request(root: root)
        let initial = try SyncDeletionLedger.planIncomingCaptures(initial: .absent, requests: [request], allocations: [Self.allocation(request)])
        var bytes = try #require(initial.finalManifestBytes)
        bytes.append(Data(repeating: 32, count: 100_000_000 - bytes.count))
        var files = initial.finalFiles
        files["ledger.json"] = SyncDeletionCaptureProgramBuilder.proof(bytes)
        let program = try SyncDeletionLedger.planIncomingCaptures(initial: .present(manifestBytes: bytes, directories: initial.finalDirectories, files: files),
            requests: [request], allocations: [Self.allocation(request)])
        #expect(program.initialManifestBytes == nil)
        #expect(program.steps.contains { if case let .output(o) = $0, case let .write(_, _, .replace(expected, _), _) = o.action { expected.byteCount == 100_000_000 } else { false } })
        bytes.append(32)
        files["ledger.json"] = SyncDeletionCaptureProgramBuilder.proof(bytes)
        var calls = 0
        #expect(throws: (any Error).self) { try SyncDeletionLedger.planIncomingCaptures(initial: .present(manifestBytes: bytes, directories: initial.finalDirectories, files: files),
            requests: [request], allocations: [Self.allocation(request)], temporaryID: { calls += 1; return UUID() }) }
        #expect(calls == 0)
    }
}
