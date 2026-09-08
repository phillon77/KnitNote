import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct SyncBootstrapOutputPlannerTests {
    private let transactionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let temp1 = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let temp2 = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private let account = String(repeating: "a", count: 64)
    private let live = String(repeating: "b", count: 64)
    private var one: SyncBootstrapOutputProof { proof(1, 1) }
    private var two: SyncBootstrapOutputProof { proof(2, 2) }
    private func proof(_ bytes: Int64, _ byte: UInt8) -> SyncBootstrapOutputProof {
        .init(byteCount: bytes, sha256: Data(repeating: byte, count: 32))
    }
    private func plan(_ actions: [SyncBootstrapOutputAction], cap: Int = 100_000_000) throws -> SyncBootstrapOutputPlan {
        try SyncBootstrapOutputPlanner.plan(accountIDHash: account, livePathSHA256: live,
            transactionID: transactionID, actions: actions, maximumMetadataBytes: cap)
    }
    private func roots(_ roles: [SyncBootstrapOutputRole]) -> [SyncBootstrapOutputAction] {
        roles.map { .directory(role: $0, path: "") }
    }

    @Test func finiteReplacementAndExactReuseReserveEveryPotentialTemporary() throws {
        let actions = roots([.original, .staged]) + [
            .write(role: .original, path: "a.json", mode: .create(one), temporaryID: temp1),
            .write(role: .staged, path: "a.json", mode: .create(one), temporaryID: temp1),
            .write(role: .staged, path: "a.json", mode: .replace(expected: one, new: two), temporaryID: temp2),
            .reuseExact(role: .staged, path: "a.json", proof: two)
        ]
        let result = try plan(actions)
        #expect(result.actionCount == 6)
        #expect(result.reservations[.original]?.maximumEntryCount == 3)
        #expect(result.reservations[.staged]?.maximumEntryCount == 4)
        #expect(result.potentialEntries.count == 11) // 4 ancestors + 3 Original + 4 Staged
        #expect(result.potentialEntries.first { $0.relativePath.hasSuffix("Staged/a.json") }?.byteCount == 2)
        #expect(result == (try plan(actions)))
    }

    @Test func operationPreconditionsFailClosed() throws {
        let start = roots([.staged])
        let created = start + [.write(role: .staged, path: "a", mode: .create(one), temporaryID: temp1)]
        let invalid: [SyncBootstrapOutputAction] = [
            .write(role: .staged, path: "a", mode: .create(one), temporaryID: temp2),
            .write(role: .staged, path: "a", mode: .replace(expected: two, new: one), temporaryID: temp2),
            .reuseExact(role: .staged, path: "a", proof: two),
            .directory(role: .staged, path: "a")
        ]
        for action in invalid {
            #expect(throws: SyncBootstrapOutputPlanner.Error.self) { try plan(created + [action]) }
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(start + [.reuseExact(role: .staged, path: "missing", proof: one)])
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(start + [.write(role: .staged, path: "missing", mode: .replace(expected: one, new: two), temporaryID: temp1)])
        }
    }

    @Test func parentsRoleBoundariesAliasesAndTemporaryCollisionsReject() throws {
        for path in ["../Staged/a", "/a", "a//b", "a/./b", "a\\b", "a\u{0000}b", "a/b", String(repeating: "a", count: 256)] {
            #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
                try plan(roots([.original]) + [.write(role: .original, path: path, mode: .create(one), temporaryID: temp1)])
            }
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan([.write(role: .original, path: "a", mode: .create(one), temporaryID: temp1)])
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(roots([.original]) + [.directory(role: .original, path: "A"), .directory(role: .original, path: "a")])
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(roots([.original]) + [.directory(role: .original, path: "é"), .directory(role: .original, path: "e\u{0301}")])
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(roots([.original]) + [
                .write(role: .original, path: "a", mode: .create(one), temporaryID: temp1),
                .write(role: .original, path: "a", mode: .replace(expected: one, new: two), temporaryID: temp1)
            ])
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(roots([.original]) + [
                .directory(role: .original, path: ".a.\(temp1.uuidString).tmp"),
                .write(role: .original, path: "a", mode: .create(one), temporaryID: temp1)
            ])
        }
        let result = try plan(roots([.attachments]) + [.directory(role: .attachments, path: "毛線"),
            .write(role: .attachments, path: "毛線/a", mode: .create(one), temporaryID: temp1)])
        #expect(result.potentialEntries.contains { $0.relativePath.hasSuffix("Attachments/毛線/a") })
    }

    @Test func canonicalEquivalentParentSpellingCannotIntroduceAnAlias() throws {
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(roots([.original]) + [
                .directory(role: .original, path: "é"),
                .write(role: .original, path: "e\u{0301}/a", mode: .create(one), temporaryID: temp1)
            ])
        }
    }

    @Test func temporaryComponentLimitIncludesTheGeneratedSuffix() throws {
        // Dot + dot + UUID (36) + .tmp consumes 42 bytes of the 255-byte component.
        _ = try plan(roots([.original]) + [.write(role: .original,
            path: String(repeating: "a", count: 213), mode: .create(one), temporaryID: temp1)])
        #expect(throws: SyncBootstrapOutputPlanner.Error.invalidPath) {
            try plan(roots([.original]) + [.write(role: .original,
                path: String(repeating: "a", count: 214), mode: .create(one), temporaryID: temp1)])
        }
    }

    @Test func shrinkingReplacementReservesTheLargerEarlierFile() throws {
        let result = try plan(roots([.staged]) + [
            .write(role: .staged, path: "a", mode: .create(two), temporaryID: temp1),
            .write(role: .staged, path: "a", mode: .replace(expected: two, new: one), temporaryID: temp2)
        ])
        #expect(result.potentialEntries.first { $0.relativePath.hasSuffix("Staged/a") }?.byteCount == 2)
        #expect(result.potentialEntries.first { $0.relativePath.hasSuffix(".\(temp1.uuidString).tmp") }?.byteCount == 2)
        #expect(result.potentialEntries.first { $0.relativePath.hasSuffix(".\(temp2.uuidString).tmp") }?.byteCount == 1)
    }

    @Test func locksAreExplicitAndCannotBeReplaced() throws {
        let actions = roots([.staged]) + [.directory(role: .staged, path: "SyncMetadata"),
            .lock(role: .staged, path: "SyncMetadata/.ledger.json.lock", expectedExisting: nil)]
        let result = try plan(actions)
        #expect(result.reservations[.staged]?.maximumEntryCount == 3)
        #expect(result.potentialEntries.filter { !$0.isDirectory }.count == 1)
        let empty = SyncBootstrapOutputProof(byteCount: 0, sha256: Data(SHA256.hash(data: Data())))
        _ = try plan(actions + [.lock(role: .staged, path: "SyncMetadata/.ledger.json.lock", expectedExisting: empty)])
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(actions + [.write(role: .staged, path: "SyncMetadata/.ledger.json.lock",
                mode: .replace(expected: empty, new: one), temporaryID: temp1)])
        }
        #expect(throws: SyncBootstrapOutputPlanner.Error.self) {
            try plan(actions + [.lock(role: .staged, path: "SyncMetadata/.ledger.json.lock", expectedExisting: one)])
        }
    }

    @Test func proofFileAndMetadataLimitsAreExact() throws {
        let actions = roots([.original]) + [.write(role: .original, path: "big", mode: .create(proof(100_000_000, 255)), temporaryID: temp1)]
        let result = try plan(actions)
        _ = try plan(actions, cap: result.reservedEncodedEntryBytes)
        #expect(throws: SyncBootstrapOutputPlanner.Error.tooLarge) {
            try plan(actions, cap: result.reservedEncodedEntryBytes - 1)
        }
        for value in [proof(-1, 1), proof(100_000_001, 1), .init(byteCount: 0, sha256: Data([1]))] {
            #expect(throws: SyncBootstrapOutputPlanner.Error.invalidProof) {
                try plan(roots([.original]) + [.write(role: .original, path: "a", mode: .create(value), temporaryID: temp1)])
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedArray = try encoder.encode(result.potentialEntries)
        #expect(encodedArray.count <= result.reservedEncodedEntryBytes)
        #expect(try JSONEncoder().encode(result.potentialEntries).count <= result.reservedEncodedEntryBytes)
        #expect(result.potentialEntries.allSatisfy { $0.device == UInt64.max && $0.inode == UInt64.max })
        #expect(result.potentialEntries.filter { !$0.isDirectory }.allSatisfy { $0.sha256.count == 32 })
    }

    @Test func bindingsAndDepthAreBoundedWithoutFilesystemAccess() throws {
        #expect(throws: SyncBootstrapOutputPlanner.Error.invalidBinding) {
            try SyncBootstrapOutputPlanner.plan(accountIDHash: "../a", livePathSHA256: live,
                transactionID: transactionID, actions: [])
        }
        var actions = roots([.validationMerged])
        var path = ""
        // A directory at 128 components would recurse into depth 128 and fail.
        // 4 namespace ancestors + role + 122 child directories = 127.
        for _ in 0..<122 { path += path.isEmpty ? "d" : "/d"; actions.append(.directory(role: .validationMerged, path: path)) }
        _ = try plan(actions)
        _ = try plan(actions + [.write(role: .validationMerged, path: path + "/a", mode: .create(one), temporaryID: temp1)])
        actions.append(.directory(role: .validationMerged, path: path + "/d"))
        #expect(throws: SyncBootstrapOutputPlanner.Error.invalidPath) { try plan(actions) }
    }
}
