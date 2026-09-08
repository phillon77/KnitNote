import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

struct SyncBootstrapOwnedManifestTests {
    @Test func formerSourceWitnessIsExactRequiredOnlyForMissingArchive() throws {
        var object = fixture("prepared")
        object["original"] = [String: Any]()
        object["sourceProof"] = ["kind": "missingArchive", "treeSHA256":
            OwnedBootstrapCodec.hash(try json([String: Any]())).base64EncodedString()]
        func value(_ digest: Any?) -> [String: Any] {
            var copy = object, body = prepared
            body["sourceControlSHA256"] = hash
            if let digest { body["formerSourceSHA256"] = digest }
            copy["body"] = ["phase": "prepared", "prepared": body]
            return copy
        }
        let selected = try decode(value(hash))
        #expect(try BootstrapManifestV3.decodeEnvelope(selected.encoded()) == selected)
        reject(value(nil)); reject(value(NSNull())); reject(value("AA=="))
        #expect(try decode(value(Data(repeating: 2, count: 32).base64EncodedString())).normalizedPreparedDigest()
            != selected.normalizedPreparedDigest())
        reject(changedBody("prepared") { $0["formerSourceSHA256"] = hash })
        reject(changedBody("prepared") { $0["formerSourceSHA256"] = NSNull() })
    }
    @Test func preparedRequiresImmutableOutputDigest() throws {
        let object = changedBody("prepared") { $0["immutableOutputSHA256"] = hash }
        _ = try decode(object)
        reject(changedBody("prepared") { $0.removeValue(forKey: "immutableOutputSHA256") })
        for value: Any in [NSNull(), Data(repeating: 1, count: 31).base64EncodedString()] {
            reject(changedBody("prepared") { $0["immutableOutputSHA256"] = value })
        }
    }
    private let id = "11111111-1111-4111-8111-111111111111"
    private let hash = Data(repeating: 1, count: 32).base64EncodedString()
    private let live = "/private/tmp/owned-fixture/working-set"
    private var proof: [String: Any] { ["bytes": 1, "digest": hash] }
    private var outputProof: [String: Any] { ["byteCount": 1, "sha256": hash] }
    private var allocation: [String: Any] {
        ["transactionID": id, "allowedRoles": ["original", "staged"], "roleLimits": [
            ["role": "original", "maximumEntryCount": 4, "reservedEncodedProofBytes": 4096],
            ["role": "staged", "maximumEntryCount": 4, "reservedEncodedProofBytes": 4096]]]
    }
    private var preparing: [String: Any] { ["pendingSnapshotSHA256": hash, "outputAllocation": allocation] }
    private var prepared: [String: Any] {
        ["installed": ["projects-v1.json": proof], "mutations": [], "preparationSHA256": hash, "pendingSnapshotSHA256": hash,
         "immutableOutputSHA256": hash,
         "commitProgram": ["journalRelativePath": "SyncMetadata/journal.json", "initialJournalDirectories": [],
             "initialJournalFiles": [:], "operations": []],
         "originalLiveRoot": ["device": 1, "inode": 2], "stagedRoot": ["device": 1, "inode": 3]]
    }
    private var root: String {
        let pathHash = SHA256.hash(data: Data(live.utf8)).map { String(format: "%02x", $0) }.joined()
        return ".KnitNote-SyncBootstrap/" + String(repeating: "a", count: 64) + "/" + pathHash + "/" + id
    }
    private func entry(_ path: String, directory: Bool = true) -> [String: Any] {
        ["relativePath": path, "isDirectory": directory, "byteCount": directory ? 0 : 1,
         "sha256": directory ? "" : hash, "device": 1, "inode": path.count + 10]
    }
    private var frozen: [[String: Any]] {
        [entry(root), entry(root + "/Original"), entry(root + "/Original/projects-v1.json", directory: false)]
    }
    private func fixture(_ phase: String = "preparing") -> [String: Any] {
        let payload: [String: Any]
        switch phase {
        case "preparing": payload = preparing
        case "abortedPreparation": payload = ["preparationSHA256": hash, "pendingSnapshotSHA256": hash,
            "outputAllocation": allocation, "frozenOutputEntries": []]
        case "rolledBack": payload = ["prepared": prepared, "frozenTransactionEntries": frozen]
        default: payload = prepared
        }
        return ["version": 3, "id": id, "context": ["accountIDHash": String(repeating: "a", count: 64),
            "epoch": id, "freezeID": id], "livePath": live, "journalPath": "SyncMetadata/journal.json",
            "sourceProof": ["kind": "archive", "sha256": hash], "original": ["projects-v1.json": proof],
            "body": ["phase": phase, phase: payload]]
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func decode(_ object: [String: Any]) throws -> BootstrapManifestV3 {
        try JSONDecoder().decode(BootstrapManifestV3.self, from: json(object))
    }
    private func reject(_ object: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: (any Error).self, sourceLocation: sourceLocation) { try decode(object) }
    }
    private func changed(_ phase: String = "preparing", _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var object = fixture(phase); edit(&object); return object
    }
    private func changedBody(_ phase: String = "preparing", _ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        changed(phase) { object in
            var body = object["body"] as! [String: Any]
            var payload = body[phase] as! [String: Any]; edit(&payload)
            body[phase] = payload; object["body"] = body
        }
    }

    // Removing the v3-only version check must fail this test at runtime.
    @Test func preparedPreservesExactSourceWitnessAcrossNormalizedPhases() throws {
        let value = changedBody("prepared") { $0["sourceControlSHA256"] = hash }
        let manifest = try decode(value)
        let encoded = try manifest.encoded()
        #expect(try BootstrapManifestV3.decodeEnvelope(encoded) == manifest)
        reject(changedBody("prepared") { $0.removeValue(forKey: "pendingSnapshotSHA256") })
        reject(changedBody("prepared") { $0["pendingSnapshotSHA256"] = "AA==" })
        reject(changedBody("prepared") { $0["sourceControlSHA256"] = NSNull() })
        reject(changedBody("prepared") { $0["sourceControlSHA256"] = "AA==" })
    }

    @Test func existingNoncanonicalAttachmentRequiresExactInstalledInitialProof() throws {
        let parent = "SyncMetadata/.journal.json.attachments"
        let path = parent + "/prior-source-é.bin"
        func value(path: String = "SyncMetadata/.journal.json.attachments/prior-source-é.bin",
                   operation: [String: Any]? = nil, omitInitial: Bool = false,
                   installedProof: [String: Any]? = nil) -> [String: Any] {
            changedBody("prepared") { body in
                body["installed"] = ["projects-v1.json": proof, "SyncMetadata/": ["bytes": -1, "digest": ""],
                    parent + "/": ["bytes": -1, "digest": ""], path: installedProof ?? proof]
                body["commitProgram"] = ["journalRelativePath": "SyncMetadata/journal.json",
                    "initialJournalDirectories": ["SyncMetadata", parent],
                    "initialJournalFiles": omitInitial ? [:] : [path: outputProof],
                    "operations": [operation ?? ["kind": "reuse", "path": path, "proof": outputProof]]]
            }
        }
        _ = try decode(value())
        _ = try decode(value(operation: ["kind": "synchronize", "path": path]))
        reject(value(omitInitial: true))
        reject(value(installedProof: ["bytes": 2, "digest": hash]))
        reject(value(operation: ["kind": "reuse", "path": path, "proof": ["byteCount": 2, "sha256": hash]]))
        reject(value(operation: ["kind": "reuse", "path": path.decomposedStringWithCanonicalMapping, "proof": outputProof]))
        reject(value(operation: ["kind": "copyAttachment", "path": path, "sourceVersionID": id, "proof": outputProof, "temporaryID": id]))
        reject(value(operation: ["kind": "replace", "path": path, "old": outputProof, "bytes": "AA==", "temporaryID": id]))
        reject(value(operation: ["kind": "reuse", "path": parent + "/new.bin", "proof": outputProof]))
    }

    @Test func rejectsUnknownVersion() { reject(changed { $0["version"] = 4 }) }

    @Test(arguments: ["preparing", "prepared", "installed", "committed", "rollingBack", "rolledBack", "abortedPreparation"])
    func allPhasesRoundTripThroughChecksummedEnvelope(_ phase: String) throws {
        let manifest = try decode(fixture(phase))
        let encoded = try manifest.encoded()
        let restored = try BootstrapManifestV3.decodeEnvelope(encoded)
        #expect(try restored.encoded() == encoded)
        let outer = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(outer.keys) == ["payload", "digest"])
        let payload = try #require(Data(base64Encoded: outer["payload"] as! String))
        #expect(outer["digest"] as? String == Data(SHA256.hash(data: payload)).base64EncodedString())
    }

    @Test func exactKeysAndNullsRejectAtEveryOwnedBoundary() {
        for key in ["version", "id", "context", "livePath", "journalPath", "sourceProof", "original", "body"] {
            reject(changed { $0[key] = NSNull() })
        }
        reject(changed { $0["installed"] = [:] })
        reject(changed { $0["historyHead"] = NSNull() })
        reject(changed { $0["context"] = ["accountIDHash": String(repeating: "a", count: 64), "epoch": id, "freezeID": id, "trusted": true] })
        reject(changed { $0["body"] = ["phase": "preparing", "preparing": preparing, "prepared": prepared] })
        reject(changed { $0["body"] = ["phase": "future", "future": preparing] })
        reject(changedBody { $0["sourceControlSHA256"] = NSNull() })
        reject(changedBody { $0["predecessor"] = NSNull() })
        reject(changedBody { $0["installed"] = [:] })
        reject(changedBody("prepared") { $0["frozenTransactionEntries"] = frozen })
        reject(changedBody("rolledBack") { $0.removeValue(forKey: "frozenTransactionEntries") })
        reject(changed { $0["original"] = ["projects-v1.json": ["bytes": 1, "digest": hash, "trusted": true]] })
    }

    @Test func sourceAndProofContradictionsReject() throws {
        reject(changed { $0["sourceProof"] = ["kind": "archive", "sha256": "AA=="] })
        reject(changed { $0["sourceProof"] = ["kind": "archive", "sha256": hash, "treeSHA256": hash] })
        reject(changed { $0["original"] = [:] })
        reject(changed { $0["original"] = ["projects-v1.json/": ["bytes": -1, "digest": ""]] })
        reject(changed { $0["original"] = ["projects-v1.json": ["bytes": -1, "digest": hash]] })
        reject(changed { $0["original"] = ["projects-v1.json": ["bytes": 100_000_001, "digest": hash]] })
        reject(changed { $0["sourceProof"] = ["kind": "missingArchive", "treeSHA256": hash] })
        // Literal SHA256 of sorted-key JSON {}. No source-control omission on absence.
        let emptyDigest = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
        let digest = stride(from: 0, to: emptyDigest.count, by: 2).map { i in
            UInt8(emptyDigest.dropFirst(i).prefix(2), radix: 16)!
        }
        var absent = fixture(); absent["original"] = [String: Any]()
        absent["sourceProof"] = ["kind": "missingArchive", "treeSHA256": Data(digest).base64EncodedString()]
        reject(absent)
        absent["body"] = ["phase": "preparing", "preparing": preparing.merging(["sourceControlSHA256": hash]) { _, new in new }]
        _ = try decode(absent)
    }

    @Test func pathsAllocationsAndRootsRejectContradictions() {
        for path in ["../journal", "/journal", "a//b", "a/./b", "a/../b", "a\\b", "a/", "a\u{0}b"] {
            reject(changed { $0["journalPath"] = path })
        }
        for path in ["working-set", "/a/../b", "/a//b", "/a/", "/"] { reject(changed { $0["livePath"] = path }) }
        reject(changed { $0["original"] = ["projects-v1.json": proof, "../bad": proof] })
        reject(changed { $0["original"] = ["projects-v1.json": proof, "A": proof, "a": proof] })
        reject(changedBody { $0["outputAllocation"] = allocation.merging(["transactionID": "22222222-2222-4222-8222-222222222222"]) { _, new in new } })
        reject(changedBody { $0["outputAllocation"] = allocation.merging(["allowedRoles": ["original", "original"]]) { _, new in new } })
        reject(changedBody { $0["outputAllocation"] = allocation.merging(["allowedRoles": ["Failed"]]) { _, new in new } })
        reject(changedBody { $0["outputAllocation"] = allocation.merging(["roleLimits": []]) { _, new in new } })
        reject(changedBody("prepared") { $0["originalLiveRoot"] = ["device": 0, "inode": 2] })
        reject(changedBody("prepared") { $0["stagedRoot"] = ["device": 1, "inode": 2] })
        reject(changedBody("prepared") { $0["commitProgram"] = ["journalRelativePath": "other.json", "initialJournalDirectories": [], "initialJournalFiles": [:], "operations": []] })
    }

    @Test func unicodeEquivalentParentSpellingCannotAliasPortableProofTrees() {
        // Swift dictionary lookup considers these spellings equivalent; the
        // filesystem proof must still retain its exact declared parent bytes.
        reject(changed { $0["original"] = ["projects-v1.json": proof,
            "\u{e9}/": ["bytes": -1, "digest": ""], "e\u{301}/file": proof] })
        reject(changedBody("abortedPreparation") { $0["frozenOutputEntries"] = [entry(root), entry(root + "/Original"),
            entry(root + "/Original/\u{e9}"), entry(root + "/Original/e\u{301}/file", directory: false)] })
    }

    @Test func frozenOriginalRequiresExactCrossTreeUTF8Spelling() throws {
        func rollback(originalName: String, frozenName: String) -> [String: Any] {
            var object = changedBody("rolledBack") { $0["frozenTransactionEntries"] = frozen + [entry(root + "/Original/" + frozenName, directory: false)] }
            object["original"] = ["projects-v1.json": proof, originalName: proof]
            return object
        }
        for name in ["\u{e9}", "e\u{301}"] { _ = try decode(rollback(originalName: name, frozenName: name)) }
        reject(rollback(originalName: "\u{e9}", frozenName: "e\u{301}"))
        reject(rollback(originalName: "e\u{301}", frozenName: "\u{e9}"))
    }

    @Test func journalBindingsAndInitialProjectionRequireExactUTF8Spelling() throws {
        func journal(manifestPath: String, programPath: String, installedDirectory: String? = nil,
                     initialDirectory: String? = nil, installedFile: String? = nil, initialFile: String? = nil) -> [String: Any] {
            var object = changedBody("prepared") { body in
                var installed: [String: Any] = ["projects-v1.json": proof]
                if let installedDirectory { installed[installedDirectory + "/"] = ["bytes": -1, "digest": ""] }
                if let installedFile { installed[installedFile] = proof }
                body["installed"] = installed
                body["commitProgram"] = ["journalRelativePath": programPath,
                    "initialJournalDirectories": initialDirectory.map { [$0] } ?? [],
                    "initialJournalFiles": initialFile.map { [$0: outputProof] } ?? [:], "operations": []]
            }
            object["journalPath"] = manifestPath
            return object
        }
        for name in ["\u{e9}", "e\u{301}"] {
            let path = name + "/pending.json", file = path + ".checkpoint"
            _ = try decode(journal(manifestPath: path, programPath: path, installedDirectory: name,
                initialDirectory: name, installedFile: file, initialFile: file))
        }
        reject(journal(manifestPath: "SyncMetadata/\u{e9}.json", programPath: "SyncMetadata/e\u{301}.json"))
        reject(journal(manifestPath: "\u{e9}/pending.json", programPath: "\u{e9}/pending.json",
            installedDirectory: "e\u{301}", initialDirectory: "\u{e9}"))
        reject(journal(manifestPath: "\u{e9}/pending.json", programPath: "\u{e9}/pending.json",
            installedDirectory: "\u{e9}", initialDirectory: "e\u{301}"))
        reject(journal(manifestPath: "SyncMetadata/\u{e9}.json", programPath: "SyncMetadata/\u{e9}.json",
            installedDirectory: "SyncMetadata", initialDirectory: "SyncMetadata",
            installedFile: "SyncMetadata/e\u{301}.json.checkpoint", initialFile: "SyncMetadata/\u{e9}.json.checkpoint"))
        reject(journal(manifestPath: "SyncMetadata/\u{e9}.json", programPath: "SyncMetadata/\u{e9}.json",
            installedDirectory: "SyncMetadata", initialDirectory: "SyncMetadata",
            installedFile: "SyncMetadata/\u{e9}.json.checkpoint", initialFile: "SyncMetadata/e\u{301}.json.checkpoint"))
        // An equivalent spelling in installed must not escape reverse projection
        // accounting merely because exact family matching no longer selects it.
        reject(journal(manifestPath: "SyncMetadata/\u{e9}.json", programPath: "SyncMetadata/\u{e9}.json",
            installedDirectory: "SyncMetadata", initialDirectory: "SyncMetadata", installedFile: "SyncMetadata/e\u{301}.json.checkpoint"))
    }

    @Test func journalOperationFamiliesRequireExactBoundPrefixBytes() throws {
        func operation(_ name: String, _ kind: String) -> [String: Any] {
            switch kind {
            case "directory", "synchronize": return ["kind": kind, "path": name]
            case "copyAttachment": return ["kind": kind, "path": name + "/.pending.json.attachments/\(id)-\(id).asset",
                "sourceVersionID": id, "proof": outputProof, "temporaryID": id]
            default: return ["kind": "reuse", "path": name + "/pending.json.proofs.00000000", "proof": outputProof]
            }
        }
        func object(_ operation: [String: Any]) -> [String: Any] {
            var object = changedBody("prepared") { body in
                body["commitProgram"] = ["journalRelativePath": "\u{e9}/pending.json", "initialJournalDirectories": [],
                    "initialJournalFiles": [:], "operations": [operation]]
            }
            object["journalPath"] = "\u{e9}/pending.json"
            return object
        }
        for kind in ["directory", "synchronize", "copyAttachment", "reuse"] {
            _ = try decode(object(operation("\u{e9}", kind)))
            reject(object(operation("e\u{301}", kind)))
        }
    }

    @Test func journalProofsKeep64MiBLimitWithoutAllocatingTheirBytes() {
        let oversized: [String: Any] = ["byteCount": 64 * 1_024 * 1_024 + 1, "sha256": hash]
        reject(changedBody("prepared") { body in
            body["installed"] = ["projects-v1.json": proof, "SyncMetadata/": ["bytes": -1, "digest": ""],
                "SyncMetadata/journal.json.checkpoint": ["bytes": 64 * 1_024 * 1_024 + 1, "digest": hash]]
            body["commitProgram"] = ["journalRelativePath": "SyncMetadata/journal.json", "initialJournalDirectories": ["SyncMetadata"],
                "initialJournalFiles": ["SyncMetadata/journal.json.checkpoint": oversized], "operations": []]
        })
        for operation in [
            ["kind": "reuse", "path": "SyncMetadata/journal.json.checkpoint", "proof": oversized],
            ["kind": "replace", "path": "SyncMetadata/journal.json.checkpoint", "old": oversized, "bytes": "", "temporaryID": id]
        ] as [[String: Any]] {
            reject(changedBody("prepared") { body in
                body["commitProgram"] = ["journalRelativePath": "SyncMetadata/journal.json", "initialJournalDirectories": [],
                    "initialJournalFiles": [:], "operations": [operation]]
            })
        }
    }

    @Test func frozenTreesAreExactScopedAndRequiredOnlyAfterRollback() throws {
        _ = try decode(fixture("abortedPreparation"))
        reject(changedBody("rolledBack") { $0["frozenTransactionEntries"] = [] })
        reject(changedBody("rolledBack") { $0["frozenTransactionEntries"] = [entry(root)] })
        reject(changedBody("rolledBack") { $0["frozenTransactionEntries"] = frozen.reversed().map { $0 } })
        reject(changedBody("rolledBack") { $0["frozenTransactionEntries"] = frozen + [entry(root + "/Original")] })
        reject(changedBody("abortedPreparation") { $0["frozenOutputEntries"] = [entry(root), entry(root + "/Failed")] })
        reject(changedBody("abortedPreparation") { $0["frozenOutputEntries"] = [entry(root + "/Original")] })
        reject(changedBody("abortedPreparation") { $0["frozenOutputEntries"] = [entry(root), entry(root + "/Original/child", directory: false)] })
        var changedFile = entry(root + "/Original/projects-v1.json", directory: false); changedFile["sha256"] = Data(repeating: 2, count: 32).base64EncodedString()
        reject(changedBody("rolledBack") { $0["frozenTransactionEntries"] = [entry(root), entry(root + "/Original"), changedFile] })
    }

    @Test func normalizedDigestRetainsAllImmutableBindings() throws {
        let expected = try decode(fixture("prepared")).normalizedPreparedDigest()
        #expect(expected == Data(SHA256.hash(data: try json(fixture("prepared")))))
        for phase in ["installed", "committed", "rollingBack", "rolledBack"] {
            #expect(try decode(fixture(phase)).normalizedPreparedDigest() == expected)
        }
        #expect(throws: (any Error).self) { try decode(fixture()).normalizedPreparedDigest() }
        #expect(throws: (any Error).self) { try decode(fixture("abortedPreparation")).normalizedPreparedDigest() }
        let mutations: [[String: Any]] = [
            changed("prepared") { $0["id"] = "22222222-2222-4222-8222-222222222222" },
            changed("prepared") { $0["context"] = ["accountIDHash": String(repeating: "a", count: 64),
                "epoch": "22222222-2222-4222-8222-222222222222", "freezeID": id] },
            changed("prepared") { $0["original"] = ["projects-v1.json": proof, "extra": proof] },
            changedBody("prepared") { $0["preparationSHA256"] = Data(repeating: 2, count: 32).base64EncodedString() },
            changedBody("prepared") { $0["sourceControlSHA256"] = Data(repeating: 2, count: 32).base64EncodedString() },
            changedBody("prepared") { $0["pendingSnapshotSHA256"] = Data(repeating: 2, count: 32).base64EncodedString() },
            changedBody("prepared") { $0["immutableOutputSHA256"] = Data(repeating: 2, count: 32).base64EncodedString() },
            changedBody("prepared") { $0["stagedRoot"] = ["device": 1, "inode": 4] },
            changedBody("prepared") { $0["installed"] = ["projects-v1.json": proof, "extra": proof] },
            changed("prepared") { $0["historyHead"] = ["sha256": hash, "byteCount": 10, "recordCount": 1, "chainByteCount": 10] },
            changedBody("prepared") { $0["commitProgram"] = ["journalRelativePath": "SyncMetadata/journal.json", "initialJournalDirectories": [], "initialJournalFiles": [:], "operations": [["kind": "synchronize", "path": "SyncMetadata"]]] }
        ]
        for mutation in mutations { #expect(try decode(mutation).normalizedPreparedDigest() != expected) }
    }

    @Test func historyReferencesAndEnvelopeAreStrictAndBounded() throws {
        let ref: [String: Any] = ["sha256": hash, "byteCount": 10, "recordCount": 1, "chainByteCount": 10]
        for change in [["sha256": "AA=="], ["byteCount": -1], ["byteCount": 100_000_001], ["recordCount": 0], ["chainByteCount": 9], ["extra": true]] as [[String: Any]] {
            reject(changed { $0["historyHead"] = ref.merging(change) { _, new in new } })
        }
        let manifest = try decode(fixture())
        var envelope = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]
        envelope["digest"] = Data(repeating: 2, count: 32).base64EncodedString()
        #expect(throws: (any Error).self) { try BootstrapManifestV3.decodeEnvelope(json(envelope)) }
        envelope = try JSONSerialization.jsonObject(with: manifest.encoded()) as! [String: Any]; envelope["extra"] = true
        #expect(throws: (any Error).self) { try BootstrapManifestV3.decodeEnvelope(json(envelope)) }
        #expect(throws: (any Error).self) { try manifest.encoded(maximumBytes: 1) }
        #expect(throws: (any Error).self) { try BootstrapManifestV3.decodeEnvelope(manifest.encoded(), maximumBytes: 1) }
    }

    @Test func commitOperationsRejectUnknownPathsMixedKindsAndBadProofs() throws {
        func with(_ operation: [String: Any]) -> [String: Any] {
            changedBody("prepared") { body in
                var program = body["commitProgram"] as! [String: Any]; program["operations"] = [operation]; body["commitProgram"] = program
            }
        }
        for operation in [
            ["kind": "remove", "path": "SyncMetadata/journal.json.segment"],
            ["kind": "directory", "path": "arbitrary"],
            ["kind": "synchronize", "path": "SyncMetadata/journal.json.unplanned"],
            ["kind": "reuse", "path": "SyncMetadata/journal.json.segment", "proof": outputProof, "bytes": ""],
            ["kind": "replace", "path": "SyncMetadata/journal.json.checkpoint", "old": NSNull(), "bytes": "", "temporaryID": id],
            ["kind": "copyAttachment", "path": "SyncMetadata/journal.json.segment", "sourceVersionID": id, "proof": outputProof, "temporaryID": id],
            ["kind": "reuse", "path": "SyncMetadata/journal.json.segment", "proof": ["byteCount": -1, "sha256": hash]],
            ["kind": "appendSegment", "expected": NSNull(), "frames": ""],
        ] as [[String: Any]] { reject(with(operation)) }
        for operation in [
            ["kind": "synchronize", "path": "SyncMetadata"],
            ["kind": "directory", "path": "SyncMetadata/.journal.json.attachments"],
            ["kind": "reuse", "path": "SyncMetadata/journal.json.proofs.100000000", "proof": outputProof],
            ["kind": "replace", "path": "SyncMetadata/journal.json.segment", "bytes": "", "temporaryID": id],
            ["kind": "copyAttachment", "path": "SyncMetadata/.journal.json.attachments/\(id)-\(id).asset", "sourceVersionID": id, "proof": outputProof, "temporaryID": id],
            ["kind": "appendSegment", "frames": ""],
        ] as [[String: Any]] { _ = try decode(with(operation)) }
    }

    @Test func missingArchiveTreeDigestKeepsLegacyEscapedSlashEncoding() throws {
        let original: [String: Any] = ["folder/": ["bytes": -1, "digest": ""]]
        let escaped = Data(#"{"folder\/":{"bytes":-1,"digest":""}}"#.utf8)
        var object = fixture()
        object["original"] = original
        object["sourceProof"] = ["kind": "missingArchive", "treeSHA256": Data(SHA256.hash(data: escaped)).base64EncodedString()]
        object["body"] = ["phase": "preparing", "preparing": preparing.merging(["sourceControlSHA256": hash]) { _, new in new }]
        _ = try decode(object)
        let unescaped = Data(#"{"folder/":{"bytes":-1,"digest":""}}"#.utf8)
        object["sourceProof"] = ["kind": "missingArchive", "treeSHA256": Data(SHA256.hash(data: unescaped)).base64EncodedString()]
        reject(object)
    }

    @Test func pendingHistoryChecksExactEnvelopeAndLocallyInferableTotals() throws {
        // Only envelope integrity is claimed here: terminal/chain verification is
        // intentionally a later reader, and this test does not issue authority.
        let payload = Data(#"{"version":1}"#.utf8)
        let record = try json(["payload": payload.base64EncodedString(), "digest": Data(SHA256.hash(data: payload)).base64EncodedString()])
        let reference: [String: Any] = ["sha256": Data(SHA256.hash(data: record)).base64EncodedString(),
            "byteCount": record.count, "recordCount": 1, "chainByteCount": record.count]
        let pending: [String: Any] = ["record": record.base64EncodedString(), "reference": reference]
        _ = try decode(changedBody { $0["predecessor"] = pending })
        for bad in [
            pending.merging(["record": (record + Data([0])).base64EncodedString()]) { _, new in new },
            pending.merging(["reference": reference.merging(["byteCount": record.count + 1, "chainByteCount": record.count + 1]) { _, new in new }]) { _, new in new },
            pending.merging(["reference": reference.merging(["recordCount": 2]) { _, new in new }]) { _, new in new },
            pending.merging(["extra": true]) { _, new in new }
        ] { reject(changedBody { $0["predecessor"] = bad }) }
        var chain = changedBody { $0["predecessor"] = pending.merging(["reference": reference.merging([
            "recordCount": 2, "chainByteCount": record.count + 5]) { _, new in new }]) { _, new in new } }
        chain["historyHead"] = ["sha256": hash, "byteCount": 5, "recordCount": 1, "chainByteCount": 5]
        _ = try decode(chain)
        chain["historyHead"] = ["sha256": hash, "byteCount": 5, "recordCount": Int.max, "chainByteCount": 5]
        reject(chain)
    }

    @Test func exactEnvelopeLimitAndWideRootIdentitiesRemainPortable() throws {
        let manifest = try decode(changedBody("prepared") {
            $0["originalLiveRoot"] = ["device": UInt64.max, "inode": UInt64.max]
            $0["stagedRoot"] = ["device": UInt64.max, "inode": UInt64.max - 1]
        })
        let bytes = try SyncBootstrapOwnedManifestCodec.encode(manifest)
        #expect(try SyncBootstrapOwnedManifestCodec.encode(manifest, maximumBytes: bytes.count) == bytes)
        #expect(try SyncBootstrapOwnedManifestCodec.decode(bytes, maximumBytes: bytes.count) == manifest)
        #expect(throws: (any Error).self) { try manifest.encoded(maximumBytes: bytes.count - 1) }
        #expect(throws: (any Error).self) { try BootstrapManifestV3.decodeEnvelope(bytes, maximumBytes: bytes.count - 1) }
        #expect(throws: (any Error).self) { try manifest.encoded(maximumBytes: -1) }
        #expect(throws: (any Error).self) { try manifest.encoded(maximumBytes: 100_000_001) }
    }

    @Test func receiptUsesExistingSourceVersionAndBindsTransaction() throws {
        func withReceipt(_ receipt: [String: Any]) throws -> [String: Any] {
            let bytes = try json(receipt)
            return changedBody("prepared") { body in
                var program = body["commitProgram"] as! [String: Any]
                program["operations"] = [["kind": "replace", "path": "SyncMetadata/bootstrap-receipt.json",
                    "bytes": bytes.base64EncodedString(), "temporaryID": id]]
                body["commitProgram"] = program
            }
        }
        let receipt: [String: Any] = ["transactionID": id, "accountIDHash": String(repeating: "a", count: 64), "sourceArchiveFingerprint": hash]
        _ = try decode(withReceipt(receipt))
        reject(try withReceipt(receipt.merging(["formatVersion": 3]) { _, new in new }))
        reject(try withReceipt(receipt.merging(["transactionID": "22222222-2222-4222-8222-222222222222"]) { _, new in new }))
        reject(try withReceipt(receipt.merging(["sourceKind": "missingArchive", "sourceTreeFingerprint": hash]) { _, new in new }))
        reject(try withReceipt(receipt.merging(["extra": true]) { _, new in new }))
    }

    @Test func mutationWireValidationDoesNotReadAttachmentFiles() throws {
        let uuid = UUID(uuidString: id)!
        let slot = SyncAttachmentSlot(owner: .init(kind: .project, uuid: uuid), role: "projectCover", slotID: "cover")
        let digest = Data(repeating: 1, count: 32)
        let attachment = try SyncAttachmentVersion(slot: slot, versionID: uuid,
            conflictGroupID: SyncAttachmentVersion.conflictGroupID(for: slot), contentSHA256: digest,
            byteCount: 1, mediaType: "application/octet-stream", displayFilename: "photo.asset", replacesVersionID: nil)
        let stamp = SyncMutationStamp(logicalRevision: 1, modifiedAt: Date(timeIntervalSince1970: 1), deviceID: "wire-test")
        let record = SyncRecord(schemaVersion: 1, id: .init(kind: .attachment, uuid: uuid), createdAt: Date(timeIntervalSince1970: 0),
            entityRevision: 1, payload: .init(fields: [:], attachment: attachment), relationships: [.init(role: "owner", target: slot.owner)],
            deletedAt: .init(value: nil, stamp: stamp))
        let source = try SyncAttachmentSource(fileURL: URL(fileURLWithPath: "/private/tmp/owned-codec-no-file/\(UUID().uuidString).asset"),
            contentSHA256: digest, byteCount: 1)
        let mutation = try SyncMutation.save(recordVersion: SyncRecordVersion(record: record), attachmentSource: source, mutationID: uuid)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([mutation]))
        let object = changedBody("prepared") { $0["mutations"] = encoded }
        _ = try decode(object)
        #expect(try decode(object).normalizedPreparedDigest() != decode(fixture("prepared")).normalizedPreparedDigest())
        reject(changedBody("prepared") { $0["mutations"] = [encoded as! [Any], encoded as! [Any]].flatMap { $0 } })
        var array = encoded as! [[String: Any]]
        array[0]["delete"] = ["_0": ["recordID": ["kind": "project", "uuid": id], "mutationID": id]]
        reject(changedBody("prepared") { $0["mutations"] = array })
        // Literal mutation of a required attachment hash preserves decodability
        // while violating the record/source binding checked by journal metadata.
        var save = (encoded as! [[String: Any]])[0]["save"] as! [String: Any]
        var contents = save["_0"] as! [String: Any]
        var attachmentSource = contents["attachmentSource"] as! [String: Any]
        attachmentSource["contentSHA256"] = "AA=="; contents["attachmentSource"] = attachmentSource; save["_0"] = contents
        reject(changedBody("prepared") { $0["mutations"] = [["save": save]] })
    }
}
