import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncCanonicalCheckpointTests {
    @Test func checkpointRoundTripPreservesCommitIdentity() throws {
        let account = try SyncAccountIdentity(containerIdentifier: "test.container", userRecordName: "A")
        let value = try SyncCanonicalCheckpoint(accountIDHash: account.accountIDHash,
            commitID: UUID(), archiveSHA256: Data(repeating: 7, count: 32),
            records: [], legacyRecordIDsToDelete: [])
        let bytes = try value.encoded()
        #expect(try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: bytes).validated() == value)
        #expect(try value.encoded() == bytes)
    }

    @Test func invalidHashesDuplicateRecordsAndInvalidRecordSchemaAreRejected() throws {
        let account = try account()
        for hash in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), account.accountIDHash + "0"] {
            #expect(throws: (any Error).self) {
                try SyncCanonicalCheckpoint(accountIDHash: hash, commitID: UUID(),
                    archiveSHA256: Data(repeating: 1, count: 32), records: [], legacyRecordIDsToDelete: [])
            }
        }
        #expect(throws: (any Error).self) {
            try SyncCanonicalCheckpoint(accountIDHash: account.accountIDHash, commitID: UUID(),
                archiveSHA256: Data(count: 31), records: [], legacyRecordIDsToDelete: [])
        }
        let record = SyncRecord.fixture()
        #expect(throws: (any Error).self) { try checkpoint(records: [record, record]) }
        #expect(throws: (any Error).self) { try checkpoint(records: [.fixture(schemaVersion: 2)]) }
    }

    @Test func orderingIsCanonicalAndEveryEnvelopeFieldHasIntegrityProtection() throws {
        let a = SyncRecord.fixture(kind: .yarn), b = SyncRecord.fixture(kind: .project)
        let first = try checkpoint(records: [a, b], legacy: [a.id, b.id])
        let second = try SyncCanonicalCheckpoint(accountIDHash: first.accountIDHash,
            commitID: first.commitID, archiveSHA256: first.archiveSHA256,
            records: [b, a], legacyRecordIDsToDelete: [b.id, a.id])
        #expect(try first.encoded() == second.encoded())
        #expect(first.records.map(\.id.kind) == [.project, .yarn])
        let original = try #require(JSONSerialization.jsonObject(with: first.encoded()) as? [String: Any])
        for (key, replacement) in [
            ("formatVersion", 2 as Any), ("accountIDHash", String(repeating: "0", count: 64)),
            ("commitID", UUID().uuidString), ("archiveSHA256", Data(count: 32).base64EncodedString()),
            ("records", [] as [Any]), ("legacyRecordIDsToDelete", [] as [Any]),
            ("remoteBatchReceipts", [] as [Any]),
            ("integritySHA256", Data(count: 32).base64EncodedString())
        ] {
            var altered = original; altered[key] = replacement
            let bytes = try JSONSerialization.data(withJSONObject: altered, options: [.sortedKeys])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: bytes) }
        }
    }

    @Test func encodedEnvelopeRejectsAboveCapAndAcceptsExactCap() throws {
        // Many individually legal scalars exceed the aggregate limit only once
        // envelope overhead is included. ASCII has exact one-byte JSON growth.
        var fields: [String: SyncFieldVersion<SyncScalar>] = [:]
        for i in 0..<399 { fields["p\(i)"] = .init(value: .string(String(repeating: "x", count: 250_000)), stamp: .fixture) }
        fields["tail"] = .init(value: .string(""), stamp: .fixture)
        let initial = try checkpoint(records: [.fixture(fields: fields)])
        let initialBytes = try initial.encoded().count
        fields["tail"] = .init(value: .string(String(repeating: "x", count: 100_000_000 - initialBytes)), stamp: .fixture)
        let exact = try SyncCanonicalCheckpoint(accountIDHash: initial.accountIDHash,
            commitID: initial.commitID, archiveSHA256: initial.archiveSHA256,
            records: [.fixture(id: initial.records[0].id.uuid, fields: fields)], legacyRecordIDsToDelete: [])
        #expect(try exact.encoded().count == 100_000_000)
        if case let .string(tail) = fields["tail"]?.value {
            fields["tail"] = .init(value: .string(tail + "x"), stamp: .fixture)
        }
        let over = try checkpoint(records: [.fixture(fields: fields)])
        #expect(throws: (any Error).self) { try over.encoded() }
    }

    private func account(_ name: String = "A") throws -> SyncAccountIdentity {
        try .init(containerIdentifier: "test.container", userRecordName: name)
    }

    @Test func exactPredecessorAbsenceAndCandidateRetry() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        #expect(try store.load() == nil)
        let first = try checkpoint(), second = try checkpoint(), third = try checkpoint()
        try store.install(first, replacing: nil)
        #expect(try store.load() == first)
        let firstBytes = try Data(contentsOf: f.canonical)
        #expect(throws: (any Error).self) { try store.install(second, replacing: nil) }
        #expect(throws: (any Error).self) { try store.install(second, replacing: Data(count: 32)) }
        #expect(try Data(contentsOf: f.canonical) == firstBytes)
        try store.install(second, replacing: Data(SHA256.hash(data: firstBytes)))
        try store.install(second, replacing: Data(SHA256.hash(data: firstBytes)))
        #expect(try store.load()?.commitID == second.commitID)
        #expect(throws: (any Error).self) { try store.install(third, replacing: Data(SHA256.hash(data: firstBytes))) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.metadata.path) == ["canonical.json"])
    }

    @Test func wrongAccountAndCorruptCurrentDoNotAuthorizeReplacement() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        let foreign = try SyncCanonicalCheckpoint(accountIDHash: account("B").accountIDHash,
            commitID: UUID(), archiveSHA256: Data(count: 32), records: [], legacyRecordIDsToDelete: [])
        #expect(throws: (any Error).self) { try store.install(foreign, replacing: nil) }
        for bytes in [try foreign.encoded(), Data("broken".utf8)] {
            try bytes.write(to: f.canonical)
            #expect(throws: (any Error).self) { try store.load() }
            #expect(throws: (any Error).self) { try store.install(checkpoint(), replacing: Data(SHA256.hash(data: bytes))) }
            #expect(try Data(contentsOf: f.canonical) == bytes)
        }
    }

    @Test func storageReadCapIncludesWhitespaceBeforeDecode() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        let value = try checkpoint()
        var bytes = try value.encoded()
        bytes.append(Data(repeating: 32, count: 100_000_000 - bytes.count))
        try bytes.write(to: f.canonical)
        #expect(try store.load() == value)
        let fd = open(f.canonical.path, O_WRONLY | O_APPEND); defer { close(fd) }
        #expect(write(fd, " ", 1) == 1)
        #expect(throws: SyncRegularFileReadError.tooLarge) { try store.load() }
    }

    @Test func failuresPreservePredecessorOrCommittedCandidateAndRetryBarriers() throws {
        for boundary in SyncDurableFileWriteBoundary.allCases {
            let f = try Fixture(); defer { f.remove() }
            let base = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
            let first = try checkpoint(), second = try checkpoint()
            try base.install(first, replacing: nil)
            let original = try Data(contentsOf: f.canonical), hash = Data(SHA256.hash(data: original))
            let faulted = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {},
                beforeBoundary: { if $0 == boundary { throw Fault.injected } })
            #expect(throws: Fault.injected) { try faulted.install(second, replacing: hash) }
            #expect(try Data(contentsOf: f.canonical) == (boundary == .beforeDirectorySync ? second.encoded() : original))
            try base.install(second, replacing: hash)
            #expect(try base.load()?.commitID == second.commitID)
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.metadata.path) == ["canonical.json"])
            // Exact byte equality still crosses both durability barriers.
            for retryBoundary in [SyncDurableFileWriteBoundary.beforeFileSync, .beforeDirectorySync] {
                let retry = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {},
                    beforeBoundary: { if $0 == retryBoundary { throw Fault.injected } })
                #expect(throws: Fault.injected) { try retry.install(second, replacing: hash) }
                #expect(try base.load() == second)
            }
        }
    }

    @Test func revokedOwnershipAtEveryBoundaryPreventsFurtherTransitions() throws {
        for boundary in SyncDurableFileWriteBoundary.allCases {
            let f = try Fixture(); defer { f.remove() }
            var authorized = true
            let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(),
                validateOwnership: { if !authorized { throw Fault.revoked } },
                beforeBoundary: { if $0 == boundary { authorized = false } })
            let value = try checkpoint()
            #expect(throws: Fault.revoked) { try store.install(value, replacing: nil) }
            #expect(FileManager.default.fileExists(atPath: f.canonical.path) == (boundary == .beforeDirectorySync))
            #expect(throws: Fault.revoked) { try store.load() }
            #expect(throws: Fault.revoked) { try store.install(value, replacing: nil) }
        }
    }

    @Test func symlinkFIFOHardlinkAndDirectoryCurrentAreRejected() throws {
        for type in ["symlink", "fifo", "hardlink", "directory"] {
            let f = try Fixture(); defer { f.remove() }
            let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
            let outside = f.root.appendingPathComponent("other")
            let bytes = try checkpoint().encoded(); try bytes.write(to: outside)
            switch type {
            case "symlink": #expect(symlink(outside.path, f.canonical.path) == 0)
            case "fifo": #expect(mkfifo(f.canonical.path, 0o600) == 0)
            case "hardlink": #expect(link(outside.path, f.canonical.path) == 0)
            default: try FileManager.default.createDirectory(at: f.canonical, withIntermediateDirectories: false)
            }
            #expect(throws: (any Error).self) { try store.load() }
            #expect(throws: (any Error).self) { try store.install(checkpoint(), replacing: nil) }
            #expect(try Data(contentsOf: outside) == bytes)
        }
    }

    @Test func parentReplacementAndFileReplacementDuringWriteAreRejected() throws {
        for replacement in ["parent", "file", "same-bytes-file"] {
            let replaceParent = replacement == "parent"
            let f = try Fixture(); defer { f.remove() }
            let initial = try checkpoint(), candidate = try checkpoint(), alien = try checkpoint()
            let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
            try store.install(initial, replacing: nil)
            let before = try initial.encoded()
            let foreign = try replacement == "same-bytes-file" ? before : alien.encoded()
            let moved = f.root.appendingPathComponent("old-metadata")
            let swapping = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {},
                beforeBoundary: { boundary in
                    guard boundary == .beforeRename else { return }
                    if replaceParent {
                        try FileManager.default.moveItem(at: f.metadata, to: moved)
                        try FileManager.default.createDirectory(at: f.metadata, withIntermediateDirectories: false)
                    }
                    try foreign.write(to: f.canonical, options: .atomic)
                })
            #expect(throws: (any Error).self) { try swapping.install(candidate, replacing: Data(SHA256.hash(data: before))) }
            #expect(try Data(contentsOf: f.canonical) == foreign)
            if replaceParent { #expect(try Data(contentsOf: moved.appendingPathComponent("canonical.json")) == before) }
        }
    }

    @Test func replacedAncestorAndSymlinkAncestryAreRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        let moved = f.root.appendingPathExtension("moved"); defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: f.root, to: moved)
        #expect(symlink(moved.path, f.root.path) == 0)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.install(checkpoint(), replacing: nil) }
        #expect(throws: (any Error).self) {
            try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        }
    }

    @Test func fixedTemporaryRecoveryRequiresExactCandidateAndPreservesUnknownFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        let value = try checkpoint(), unrelated = try checkpoint()
        let temp = f.metadata.appendingPathComponent(".canonical-next.json")
        let unknown = f.metadata.appendingPathComponent(".canonical.someone-else.tmp")
        try Data("unknown".utf8).write(to: unknown)
        for bytes in [Data("partial".utf8), try unrelated.encoded()] {
            try bytes.write(to: temp)
            #expect(throws: (any Error).self) { try store.install(value, replacing: nil) }
            #expect(try Data(contentsOf: temp) == bytes)
            #expect(try store.load() == nil)
        }
        try value.encoded().write(to: temp)
        try store.install(value, replacing: nil)
        #expect(try store.load() == value)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(try Data(contentsOf: unknown) == Data("unknown".utf8))
        let third = try checkpoint()
        try third.encoded().write(to: temp)
        let committed = try Data(contentsOf: f.canonical)
        #expect(throws: (any Error).self) { try store.install(third, replacing: nil) }
        #expect(try Data(contentsOf: f.canonical) == committed)
        #expect(try Data(contentsOf: temp) == third.encoded())
    }

    @Test func substitutedTemporaryIsNeverRenamedOrCleanedAsOwned() throws {
        let f = try Fixture(); defer { f.remove() }
        let baseline = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {})
        let first = try checkpoint(), second = try checkpoint()
        try baseline.install(first, replacing: nil)
        let temp = f.metadata.appendingPathComponent(".canonical-next.json")
        let original = try Data(contentsOf: f.canonical), unknown = Data("substituted".utf8)
        let store = try SyncCanonicalCheckpointStore(liveRoot: f.root, account: account(), validateOwnership: {},
            beforeBoundary: { if $0 == .beforeRename { try unknown.write(to: temp, options: .atomic) } })
        #expect(throws: (any Error).self) { try store.install(second, replacing: Data(SHA256.hash(data: original))) }
        #expect(try Data(contentsOf: temp) == unknown)
        #expect(try Data(contentsOf: f.canonical) == original)
    }

    @Test func completeRecordHistoryAndCounterWatchStateRoundTrip() throws {
        let project = SyncRecord.fixture()
        let counterID = UUID(), processed = UUID()
        let state = SyncCounterReminderState(
            counter: ProjectCounter(id: counterID, defaultOrdinal: 1, value: 27, mutationRevision: 12),
            reminders: [], preparedCommand: nil, processedCommandIDs: [processed], occurrence: nil)
        let stamp = SyncMutationStamp(logicalRevision: 12, modifiedAt: Date(timeIntervalSince1970: 80), deviceID: "original-device")
        let counter = SyncRecord(schemaVersion: 1, id: .init(kind: .projectCounter, uuid: counterID),
            createdAt: Date(timeIntervalSince1970: 1), entityRevision: 12,
            payload: .init(fields: [:], atomicDomain: .init(value: .projectCounter(state), stamp: stamp)),
            relationships: [.init(role: "project", target: project.id)], deletedAt: .init(value: nil, stamp: stamp))
        let slot = SyncAttachmentSlot(owner: project.id, role: "project-photo", slotID: "cover")
        let predecessor = UUID()
        let attachment = try SyncAttachmentVersion.issuing(slot: slot, contentSHA256: Data(repeating: 6, count: 32),
            byteCount: 9, mediaType: "image/jpeg", displayFilename: "照片.jpg", replacesVersionID: predecessor)
        let photo = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: attachment.versionID),
            createdAt: Date(timeIntervalSince1970: 2), entityRevision: 12,
            payload: .init(fields: [:], attachment: attachment), relationships: [.init(role: "owner", target: project.id)],
            deletedAt: .init(value: Date(timeIntervalSince1970: 80), stamp: stamp))
        let value = try checkpoint(records: [photo, counter, project], legacy: [.init(kind: .knittingReminder, uuid: UUID())])
        let decoded = try JSONDecoder().decode(SyncCanonicalCheckpoint.self, from: value.encoded())
        #expect(decoded == value)
        guard case let .projectCounter(decodedState)? = decoded.records.first(where: { $0.id == counter.id })?.payload.atomicDomain?.value else {
            Issue.record("Missing complete counter state"); return
        }
        #expect(decodedState.processedCommandIDs == [processed])
        #expect(decoded.records.first(where: { $0.id == photo.id })?.payload.attachment?.replacesVersionID == predecessor)
        #expect(decoded.records.first(where: { $0.id == photo.id })?.deletedAt == photo.deletedAt)
        #expect(decoded.records.first(where: { $0.id == counter.id })?.entityRevision == 12)
    }

    private enum Fault: Error { case injected, revoked }

    private struct Fixture {
        let root: URL
        var metadata: URL { root.appendingPathComponent("SyncMetadata") }
        var canonical: URL { metadata.appendingPathComponent("canonical.json") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func checkpoint(records: [SyncRecord] = [], legacy: Set<SyncEntityID> = []) throws -> SyncCanonicalCheckpoint {
        try .init(accountIDHash: account().accountIDHash, commitID: UUID(),
            archiveSHA256: Data(repeating: 7, count: 32), records: records, legacyRecordIDsToDelete: legacy)
    }
}

private extension SyncMutationStamp {
    static var fixture: Self { .init(logicalRevision: 2, modifiedAt: Date(timeIntervalSince1970: 0), deviceID: "test") }
}

private extension SyncRecord {
    static func fixture(kind: SyncEntityKind = .project, schemaVersion: Int = 1, id: UUID = UUID(),
                        fields: [String: SyncFieldVersion<SyncScalar>] = [:]) -> Self {
        .init(schemaVersion: schemaVersion, id: .init(kind: kind, uuid: id),
            createdAt: Date(timeIntervalSince1970: 0), entityRevision: 2,
            payload: .init(fields: fields), relationships: [], deletedAt: .init(value: nil, stamp: .fixture))
    }
}
