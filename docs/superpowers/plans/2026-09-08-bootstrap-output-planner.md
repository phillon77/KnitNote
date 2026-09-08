# Owned Bootstrap Finite Output Planner Implementation Plan

## Execution outcome — 2026-09-08

Implemented db702621f3ceabaa4e7282cf5122e6d96560d10e. Missing-API RED plus behavioral parent-Unicode-alias RED recorded; final 9 tests /1 suite exit0 in `/tmp/bootstrap-output-planner-green.log`, SHA256 `0ca2eb13594b797457c711bccd689eb544606f442cb7e0b93102e37c3b6b7b9d`. Exact UTF-8 parent matching corrects the draft alias gap; shrinking-replacement and temporary-component bounds also covered. Independent reviewer read spec/plan/source/report and verified hashes: no Critical/Important/Minor findings. Scope accepted; no filesystem/capability/helper/runtime activation. Original checklist below is execution specification; evidence in `.superpowers/sdd/2026-09-08-bootstrap-output-planner/report.md`. Full recovery budget and helper compliance remain future gates. No App/fullchain repeated for inactive pure code; no push.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Main has self-reviewed this bounded plan under delegated technical authority. Focused self-review and scoped local commit precede independent review; no push.

**Goal:** Add a pure, independently testable validator and metadata estimator for a finite ordered bootstrap output program, with no filesystem writes or activated owned-bootstrap route.

**Architecture:** A program explicitly describes directories, file creations/replacements, exact-existing immutable reuse, and locks under five fixed roles. A pure planner rejects path/operation contradictions and returns the complete potential output-entry set and conservative encoded Entry reservations, including one preselected temporary per write. Its result is accounting data only; it cannot construct an installation or output capability.

**Tech Stack:** Swift 6, Foundation, CryptoKit, Swift Testing, existing KnitNoteCore package.

**Spec:** `docs/superpowers/specs/2026-09-08-bootstrap-output-planner-design.md`. Broader provenance/lineage integration remains outside this pure prerequisite.

## Global Constraints

- Baseline inspected at `a859988` in `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
- Keep 1.7.0 (13), iOS 18 / macOS 15 / watchOS 11, existing package/dependencies, all legacy wire and runtime behavior.
- Keep file/canonical/batch 100,000,000 bytes, recovery aggregate 100,000,000 bytes, control 8192 bytes, journal 64 MiB and incoming 128 batches / 16 MiB unchanged.
- No bootstrap/control/history selector mutation, account opening, helper caller adaptation, App activation, schema, Keychain, transport, cleanup, or compiler during planning. A scoped local implementation commit is allowed after focused GREEN and self-review; no push.
- All new production symbols are internal. A planner result is not ownership authority, even when its hashes and paths are correct. No runtime sink or test-only authority factory is introduced.
- A later durable preparing validator must issue the real private output capability. This unit never pretends to provide that capability.
- The accepted subsequent helper route retains owned outputs; its deletion-validation scratch is preallocated beneath ValidationMerged, never Staged/live. Non-mutating ledger preflight rejects outstanding purge intents; generic live-ledger purge remains unchanged.

## Scope and deliberately precise limit

This is the smallest independently testable prerequisite. It certifies that a *supplied finite program* is internally consistent and computes its own worst-case Entry metadata. It does not certify that existing helpers obey that program; no existing helpers call it yet. It does not calculate the complete recovery envelope budget. History, abort envelopes, pending/deletion data, JSON/Base64 layers and already existing account entries are added by a later preflight before preparing can be published.

The previous draft's helper adaptations are not executable tasks in this document. They require their own reviewed plans after this pure type exists. This avoids inventing a usable runtime sink before the durable preparing issuer exists.

Paths are account-relative in the result. The caller supplies account hash, live-path hash and transaction UUID for accounting; this planner cannot verify that these describe a current owner or a nonexistent physical tree. Physical no-follow checks, UUID absence, context validation and source authority remain future owned-transaction prerequisites.

## Files and interfaces

Create:

- `Sources/KnitNoteCore/CloudSync/SyncBootstrapOutputPlanner.swift`: the internal types and pure planner below.
- `Tests/KnitNoteCoreTests/SyncBootstrapOutputPlannerTests.swift`: the isolated pure tests below.

Modify no other files. SwiftPM automatically discovers both paths; Package.swift needs no edit.

Exact interface:

```swift
SyncBootstrapOutputPlanner.plan(
    accountIDHash: String,
    livePathSHA256: String,
    transactionID: UUID,
    actions: [SyncBootstrapOutputAction],
    maximumMetadataBytes: Int = 100_000_000
) throws -> SyncBootstrapOutputPlan
```

Every file write describes exact final byte count/hash and one UUID chosen in memory for its temporary name. A create requires absence in the modeled program. A replace requires exact prior planned proof. Reuse requires exact existing planned proof and allocates no temporary. Lock creation/acquisition is explicit; locks must be empty regular files and cannot later be replaced in the program. A role root and every descendant parent directory must appear before its children; no implicit helper-created directories are hidden.

The four fixed namespace ancestor directories are included separately in the reservation. Existing-vs-new physical ancestor handling is deliberately not claimed here. Program paths cannot escape their enum-selected role. Repeated writes reserve each distinct temporary even though abort-on-first-error means the all-temporaries union is conservative. This makes the bound valid without relying on cleanup or an arbitrary failure-count allowance.

The storage walker currently enforces depth < 128 and charges encoded Entry bytes. It has no fixed numeric entry-count cap. This planner derives counts from the finite program and enforces the same depth ceiling plus a conservative 255-byte component bound. Case/diacritic/Unicode-equivalent distinct spellings are conservatively rejected to avoid aliasing on common Apple filesystems; original spellings are preserved in all returned paths.

## Task 1: Pure finite-program validation and reservation

**Consumes:** existing internal memberwise initializer of `SyncAccountRecoveryInventory.Entry(relativePath:isDirectory:byteCount:sha256:device:inode:)`.

**Produces:** the exact internal API above. It has no I/O, no encoded bootstrap wire type and no runtime capability.

- [ ] **Step 1: Add the failing tests below.** Copy this complete content to the new test file. These tests deliberately specify missing types first; the first test run is expected to fail only because this API does not yet exist.

```swift
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
```

- [ ] **Step 2: Run the focused failing suite.** `swift test --filter SyncBootstrapOutputPlannerTests`. Expect missing `SyncBootstrapOutputPlanner` / supporting-type diagnostics only. Do not count an environment or unrelated compiler failure as the intended red result.

- [ ] **Step 3: Add the implementation below to the new production file.** It is pure; do not introduce Foundation filesystem APIs or wire it to existing helpers.

```swift
import CryptoKit
import Foundation

enum SyncBootstrapOutputRole: String, CaseIterable, Hashable, Sendable {
    case original = "Original", staged = "Staged", attachments = "Attachments"
    case validationOriginal = "ValidationOriginal", validationMerged = "ValidationMerged"
}

struct SyncBootstrapOutputProof: Equatable, Sendable {
    let byteCount: Int64
    let sha256: Data
}

enum SyncBootstrapOutputWriteMode: Equatable, Sendable {
    case create(SyncBootstrapOutputProof)
    case replace(expected: SyncBootstrapOutputProof, new: SyncBootstrapOutputProof)
}

enum SyncBootstrapOutputAction: Equatable, Sendable {
    case directory(role: SyncBootstrapOutputRole, path: String)
    case write(role: SyncBootstrapOutputRole, path: String, mode: SyncBootstrapOutputWriteMode, temporaryID: UUID)
    case reuseExact(role: SyncBootstrapOutputRole, path: String, proof: SyncBootstrapOutputProof)
    case lock(role: SyncBootstrapOutputRole, path: String, expectedExisting: SyncBootstrapOutputProof?)
}

/// Accounting data only. No member is evidence that a path is owned or writable.
struct SyncBootstrapOutputPlan: Equatable, Sendable {
    struct Reservation: Equatable, Sendable {
        let maximumEntryCount: Int
        let reservedEncodedProofBytes: Int
    }
    let transactionID: UUID
    let actionCount: Int
    let potentialEntries: [SyncAccountRecoveryInventory.Entry]
    let reservations: [SyncBootstrapOutputRole: Reservation]
    let namespaceReservedEncodedProofBytes: Int
    let reservedEncodedEntryBytes: Int
}

enum SyncBootstrapOutputPlanner {
    enum Error: Swift.Error, Equatable {
        case invalidBinding, invalidPath, collision, missingParent, invalidTransition, invalidProof, tooLarge
    }
    private enum Node: Equatable {
        case directory
        case file(SyncBootstrapOutputProof)
    }
    private struct Potential {
        let role: SyncBootstrapOutputRole?
        let isDirectory: Bool
        var byteCount: Int64
    }

    static func plan(accountIDHash: String, livePathSHA256: String, transactionID: UUID,
                     actions: [SyncBootstrapOutputAction], maximumMetadataBytes: Int = 100_000_000) throws -> SyncBootstrapOutputPlan {
        func isHash(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard isHash(accountIDHash), isHash(livePathSHA256) else { throw Error.invalidBinding }
        guard (0...100_000_000).contains(maximumMetadataBytes) else { throw Error.tooLarge }
        let parts = [".KnitNote-SyncBootstrap", accountIDHash, livePathSHA256, transactionID.uuidString]
        let root = parts.joined(separator: "/")
        var nodes: [String: Node] = [:]
        var potentials: [String: Potential] = [:]
        var aliases: [String: String] = [:]
        var temporaryPaths = Set<String>()
        var lockPaths = Set<String>()

        func validPath(_ path: String) throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count <= 128,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
                  !path.contains("\\"), !path.utf8.contains(0) else { throw Error.invalidPath }
        }
        func register(_ path: String, role: SyncBootstrapOutputRole?, directory: Bool, bytes: Int64) throws {
            try validPath(path)
            guard !directory || path.split(separator: "/").count < 128 else { throw Error.invalidPath }
            let alias = path.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let old = aliases[alias], Array(old.utf8) != Array(path.utf8) { throw Error.collision }
            aliases[alias] = path
            if var old = potentials[path] {
                guard old.role == role, old.isDirectory == directory else { throw Error.collision }
                old.byteCount = max(old.byteCount, bytes); potentials[path] = old
            } else {
                potentials[path] = .init(role: role, isDirectory: directory, byteCount: bytes)
            }
        }
        func requireParent(_ path: String) throws {
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            guard nodes[parent] == .directory else { throw Error.missingParent }
        }
        func full(_ role: SyncBootstrapOutputRole, _ relative: String, directory: Bool = false) throws -> String {
            if relative.isEmpty {
                guard directory else { throw Error.invalidPath }
                return root + "/" + role.rawValue
            }
            try validPath(relative)
            return root + "/" + role.rawValue + "/" + relative
        }
        func proof(_ value: SyncBootstrapOutputProof) throws {
            guard (0...100_000_000).contains(value.byteCount), value.sha256.count == 32 else { throw Error.invalidProof }
        }
        for index in parts.indices {
            let path = parts[...index].joined(separator: "/")
            nodes[path] = .directory
            try register(path, role: nil, directory: true, bytes: 0)
        }
        let empty = SyncBootstrapOutputProof(byteCount: 0, sha256: Data(SHA256.hash(data: Data())))
        for action in actions {
            switch action {
            case let .directory(role, relative):
                let path = try full(role, relative, directory: true)
                try requireParent(path)
                guard nodes[path] == nil, !temporaryPaths.contains(path) else { throw Error.collision }
                try register(path, role: role, directory: true, bytes: 0)
                nodes[path] = .directory
            case let .write(role, relative, mode, temporaryID):
                let path = try full(role, relative)
                try requireParent(path)
                guard !temporaryPaths.contains(path), !lockPaths.contains(path) else { throw Error.collision }
                let result: SyncBootstrapOutputProof
                switch mode {
                case let .create(value):
                    try proof(value)
                    guard nodes[path] == nil else { throw Error.invalidTransition }
                    result = value
                case let .replace(expected, value):
                    try proof(expected); try proof(value)
                    guard nodes[path] == .file(expected) else { throw Error.invalidTransition }
                    result = value
                }
                let components = path.split(separator: "/").map(String.init)
                let temporary = (components.dropLast() + ["." + components.last! + "." + temporaryID.uuidString + ".tmp"]).joined(separator: "/")
                guard nodes[temporary] == nil, temporaryPaths.insert(temporary).inserted else { throw Error.collision }
                try register(temporary, role: role, directory: false, bytes: result.byteCount)
                try register(path, role: role, directory: false, bytes: result.byteCount)
                nodes[path] = .file(result)
            case let .reuseExact(role, relative, expected):
                let path = try full(role, relative)
                try proof(expected); try requireParent(path)
                guard !temporaryPaths.contains(path), !lockPaths.contains(path), nodes[path] == .file(expected) else { throw Error.invalidTransition }
                try register(path, role: role, directory: false, bytes: expected.byteCount)
            case let .lock(role, relative, expected):
                let path = try full(role, relative)
                try requireParent(path)
                guard !temporaryPaths.contains(path) else { throw Error.collision }
                if let expected {
                    try proof(expected)
                    guard expected == empty, nodes[path] == .file(expected) else { throw Error.invalidTransition }
                } else {
                    guard nodes[path] == nil else { throw Error.invalidTransition }
                }
                try register(path, role: role, directory: false, bytes: 0)
                nodes[path] = .file(empty); lockPaths.insert(path)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let storageEncoder = JSONEncoder() // current recoveryEntries accounting escapes slashes
        var roleCounts: [SyncBootstrapOutputRole: Int] = [:]
        var roleBytes: [SyncBootstrapOutputRole: Int] = [:]
        var namespaceBytes = 2 // conservative array brackets
        var entries: [SyncAccountRecoveryInventory.Entry] = []
        func add(_ left: Int, _ right: Int) throws -> Int {
            let value = left.addingReportingOverflow(right)
            guard !value.overflow, value.partialValue <= maximumMetadataBytes else { throw Error.tooLarge }
            return value.partialValue
        }
        for path in potentials.keys.sorted() {
            let value = potentials[path]!
            let entry = SyncAccountRecoveryInventory.Entry(relativePath: path, isDirectory: value.isDirectory,
                byteCount: value.byteCount, sha256: value.isDirectory ? Data() : Data(repeating: 255, count: 32),
                device: UInt64.max, inode: UInt64.max)
            let canonicalCost = try encoder.encode(entry).count
            let storageCost = try storageEncoder.encode(entry).count
            let cost = try add(max(canonicalCost, storageCost), 1) // conservative comma per entry
            if let role = value.role {
                roleCounts[role, default: 0] += 1
                roleBytes[role] = try add(roleBytes[role] ?? 2, cost)
            } else { namespaceBytes = try add(namespaceBytes, cost) }
            entries.append(entry)
        }
        var total = namespaceBytes
        var reservations: [SyncBootstrapOutputRole: SyncBootstrapOutputPlan.Reservation] = [:]
        for role in SyncBootstrapOutputRole.allCases {
            guard let bytes = roleBytes[role], let count = roleCounts[role] else { continue }
            total = try add(total, bytes)
            reservations[role] = .init(maximumEntryCount: count, reservedEncodedProofBytes: bytes)
        }
        return .init(transactionID: transactionID, actionCount: actions.count, potentialEntries: entries,
            reservations: reservations, namespaceReservedEncodedProofBytes: namespaceBytes,
            reservedEncodedEntryBytes: total)
    }
}
```

- [ ] **Step 4: Run `swift test --filter SyncBootstrapOutputPlannerTests`.** Expect all focused tests to pass. Fix only defects in the new files; if the tests reveal a semantic design change, bring that exact change back to main review.
- [ ] **Step 5: Inspect the diff and caller boundary.** Run `git diff --check` and `rg -n 'SyncBootstrapOutputPlanner|SyncBootstrapOutputPlan' Sources Tests/KnitNoteCoreTests/SyncBootstrapOutputPlannerTests.swift`. All matches must be confined to the two new files. New code must contain no `public`, `FileManager`, `Darwin`, `.write(to:)`, `URL` output capability, or runtime install method.
- [ ] **Step 6: Request a focused review.** Review replacement semantics, temp/final/parent collision checks, alias behavior, Entry cost versus actual current encoder, file cap equality, and the explicit lack of filesystem authority. Stop at the reviewed inert unit. No App tests or full release validation is required for this inactive pure addition. Commit only the two scoped files after focused GREEN/self-review, then main independently reviews.

## Subsequent integration contract, not tasks authorized here

The later helper adaptation plan must map each actual owned write to these actions, choose package/group/temp UUIDs in memory, and route deletion validation scratch under ValidationMerged. It must include backup markup descendants and publication immutable/lock outputs, replace opaque Foundation atomic writers, and avoid all owned cleanup unlinks. Its runtime execution must enforce the exact action program under a preparing-issued capability and stop after the first failure; restart certifies abort instead of replaying the producer program.

Before activation, a separate preflight must add all history/abort/complete recovery costs. It must also prove operation-generated file content matches the specified proof, ownership/no-follow/source checks hold, and helper output paths are exactly from the program. The pure planner's successful return is never sufficient to publish preparing, spend source provenance, or open an owned output path.
