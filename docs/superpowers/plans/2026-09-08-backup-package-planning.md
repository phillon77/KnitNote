# Backup Package Content Planning Prerequisite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Main has self-reviewed and approved this bounded prerequisite. Execute the two tightly coupled steps as one reviewed deliverable; local scoped commit after focused GREEN/self-review, no push.

**Goal:** Make the real backup helper's reference selection and exact manifest encoding reusable by a non-writing package-content plan derived from frozen source proofs, and verify correspondence with actual ordinary packages.

**Architecture:** Extract two pure operations already inside KnitNoteBackupService: selecting archive/markup paths and encoding the manifest. Ordinary createPackage continues its existing reads, copying, Foundation atomic writes, inspection and cleanup. A separate internal planning method consumes frozen archive bytes and a complete projected source-tree description, selects the same files, and maps the exact package layout and per-write temporary names into the accepted SyncBootstrapOutputPlanner. It cannot execute outputs or issue ownership authority.

**Tech Stack:** Swift, Foundation, CryptoKit, Swift Testing, existing KnitNoteCore backup and finite-output planner.

**Spec:** `docs/superpowers/specs/2026-09-08-backup-package-planning-design.md`; accepted output planner is implemented at db70262.

## Global Constraints

- Pure output planner accepted at `db702621f3ceabaa4e7282cf5122e6d96560d10e`; reread its current API before implementation.
- Keep 1.7.0 (13), iOS 18 / macOS 15 / watchOS 11, no schema/App/transport/Keychain/device/push/release changes.
- Keep backup limits: archive 20,000,000; manifest 1,000,000; markup 2,000,000 bytes, 512 entries per owner; ordinary media 200,000,000 and ordinary package 4,000,000,000 bytes. Owned planned files additionally satisfy the existing bootstrap 100,000,000-byte bound. Do not lower ordinary limits to the owned limit.
- Keep recovery aggregate 100,000,000, account control 8192, journal 64 MiB, incoming 128 batches / 16 MiB unchanged.
- No owned output executor/sink, capability issuer, trusted boolean, preparing/history publication or helper cleanup-policy change in this prerequisite.
- Ordinary `createPackage(appVersion:now:)` preserves signature, timestamp semantics, localized manifest sorting, output encoder options and cleanup.

## Why this exact boundary

ValidationOriginal can eventually read an existing original source, but ValidationMerged must be planned before Staged exists. A new live-root-only snapshot API would not solve that prerequisite. Therefore this unit accepts *already frozen archive bytes and file proofs*, including projected merged entries, and does not open sources. This is content accounting, not physical source certification. Inputs may be fabricated without granting any write authority.

The existing backup constructor only stores URLs and closures; it does not create directories. `createPackage` first reads/validates the bounded archive, validates referenced path metadata, enumerates markup with descriptor checks and preflights sizes. Its first output is Data directory creation at current line 322. Copying and final inspection then validate source/content. The ordinary ordering stays intact.

Actual markup selection is not just archive media: `referencedRelativePaths(in:sourceRoot:)` at 1721 enumerates both legacy project-pattern Markup owners and library UsageMarkup owners. The descriptor reader rejects unsupported child names, directories, owner swaps and >512 entries. The frozen-tree counterpart must match this *selection and path validation*, while physical no-follow/device/inode checks remain with the actual source owner.

Successful planning does not certify JPEG/YouTube/markup semantic content. Those validators currently run in `inspectPackage` after copying. Do not move or weaken them. A future owned executor must still run the real helper validation before prepared publication; a failure becomes retained aborted preparation. Plan tests compare successful ordinary fixture packages and verify selection errors, not falsely promise all corrupt media fails during proof-only planning.

## Files and exact internal interfaces

Modify only `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`; add types either at the end of this same file or a focused `Sources/KnitNoteCore/Backup/KnitNoteBackupPackagePlan.swift` (types only). Put methods calling service-private validators inside the service's existing file so no validators become public/internal merely for cross-file access.

Create `Tests/KnitNoteCoreTests/KnitNoteBackupPackagePlanTests.swift`. Reuse internal `BackupFixture` from KnitNoteBackupServiceTests.swift; do not duplicate complex archive/media builders.

```swift
struct KnitNoteBackupFrozenTree: Equatable, Sendable {
    let archiveData: Data
    let directories: Set<String> // source-relative, no root entry, complete projected tree
    let files: [String: SyncBootstrapOutputProof]
}

struct KnitNoteBackupPackagePlan: Sendable {
    let role: SyncBootstrapOutputRole
    let packageID: UUID
    let archiveData: Data
    let manifestData: Data
    let sourceFiles: [String: SyncBootstrapOutputProof] // selected dependencies, including archive
    let temporaryIDs: [String: UUID] // keys are exact role-relative final file paths
    let actions: [SyncBootstrapOutputAction]
    let output: SyncBootstrapOutputPlan
}

// Internal KnitNoteBackupService methods. No filesystem calls or destination URL.
func planOwnedPackage(source: KnitNoteBackupFrozenTree, role: SyncBootstrapOutputRole,
    packageID: UUID, accountIDHash: String, livePathSHA256: String, transactionID: UUID,
    appVersion: String, now: Date, maximumMetadataBytes: Int = 100_000_000,
    temporaryID: (String) throws -> UUID = { _ in UUID() }) throws -> KnitNoteBackupPackagePlan

func validateFrozenPackageSource(_ plan: KnitNoteBackupPackagePlan,
    source: KnitNoteBackupFrozenTree) throws
```

Only ValidationOriginal and ValidationMerged are accepted roles. The plan includes its role root directory. Future composition merges a role root once when combining helper fragments; this task does not implement composition or allow arbitrary alternate roots.

`validateFrozenPackageSource` repeats archive-byte equality, pure archive validation, complete current reference/markup selection, selected-proof equality and source-parent consistency. It intentionally ignores unrelated non-selected files, matching backup selection; future bootstrap source-baseline validation separately binds the whole working set. It does not read disk or certify physical root identity.

## Task 1: Extract the two shared pure operations, preserving ordinary execution

**Files:** KnitNoteBackupService.swift and the new test file.

**Interfaces:** retain the existing private `referencedRelativePaths(in:sourceRoot:)`; add the overload below. Keep `referencedMediaPaths`, `validateArchive`, `patternCount`, `isMarkupFilename`, `copyFileLimit` private and unchanged.

- [ ] Add a regression comparing ordinary package bytes/manifests at the same explicit appVersion/date for both `BackupFixture.completePackage()` and `.patternLibraryPackage()`. Full executable correspondence test code is under Task 2; first commit/test cycle may use only the ordinary-package assertions from that test.
- [ ] Replace the body of the existing path selector with a wrapper and move its current iteration into the injected reader overload:

```swift
private func referencedRelativePaths(in archive: ProjectArchive, sourceRoot: URL) throws -> [String] {
    guard sourceRoot.standardizedFileURL == liveRoot.standardizedFileURL else {
        throw KnitNoteBackupError.unsafePackageEntry
    }
    return try referencedRelativePaths(in: archive, markupPaths: descriptorMarkupPaths)
}

private func referencedRelativePaths(in archive: ProjectArchive,
    markupPaths: (String) throws -> [String]) throws -> [String] {
    var paths = referencedMediaPaths(in: archive)
    for project in archive.projects {
        for pattern in project.patterns {
            paths.formUnion(try markupPaths("Patterns/\(project.id.uuidString)/Markup/\(pattern.id.uuidString)"))
        }
    }
    for usage in archive.patternUsages {
        paths.formUnion(try markupPaths("Patterns/UsageMarkup/\(usage.id.uuidString)"))
    }
    return paths.sorted()
}

private func encodePackageManifest(archive: ProjectArchive, appVersion: String, now: Date,
    files: [KnitNoteBackupManifestFile]) throws -> Data {
    let ordered = files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    let manifest = KnitNoteBackupManifest(createdAt: now, appVersion: appVersion,
        projectCount: archive.projects.count, yarnCount: archive.yarns.count,
        patternCount: patternCount(in: archive), files: ordered,
        criticalFeatures: [KnitNoteBackupManifest.fileIntegrityFeature])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(manifest)
}
```

- [ ] In ordinary createPackage, keep all code through collecting manifestFiles. Replace only sorting/manifest construction/encoding with:

```swift
try encodePackageManifest(archive: archive, appVersion: appVersion, now: now, files: manifestFiles)
    .write(to: packageRoot.appendingPathComponent("manifest.json"), options: .atomic)
```

No additional read, cap, preflight, localized-sort replacement or check belongs in ordinary createPackage. Its final inspectPackage call continues to enforce manifest cap/content validity. No change to `copyLiveRegularFileBounded`, resource hooks, `.atomic`, catch cleanup or source descriptor code.

- [ ] Run `swift test --filter KnitNoteBackupServiceTests`. Treat failures as ordinary behavior regressions; preserve the existing descriptor-swap, overrun, cleanup and corruption tests.

## Task 2: Produce exact frozen package content and map every output

**Files:** same service file, optional types-only file, new test file.

**Interfaces:** `planOwnedPackage` and `validateFrozenPackageSource` above; private helpers below.

- [ ] Add failing tests from the next section, then run `swift test --filter KnitNoteBackupPackagePlanTests` and confirm missing planning API is the intended failure.
- [ ] Implement the pure frozen source selector below; it mirrors the actual descriptor reader's relevant tree shape. It consumes a complete tree declaration, not just a list of known good selected files.

```swift
private func selectedFrozenPackageFiles(_ source: KnitNoteBackupFrozenTree) throws
    -> (ProjectArchive, [String: SyncBootstrapOutputProof]) {
    guard Int64(source.archiveData.count) <= KnitNoteBackupLimits.maximumArchiveBytes else {
        throw KnitNoteBackupError.fileTooLarge
    }
    let archive: ProjectArchive
    do { archive = try JSONDecoder().decode(ProjectArchive.self, from: source.archiveData) }
    catch { throw KnitNoteBackupError.invalidArchive }
    try validateArchive(archive)
    guard source.directories.isDisjoint(with: source.files.keys) else { throw KnitNoteBackupError.unsafePackageEntry }
    var aliases: [String: String] = [:]
    for path in Array(source.directories) + Array(source.files.keys) {
        let alias = path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if let old = aliases[alias], !old.utf8.elementsEqual(path.utf8) { throw KnitNoteBackupError.unsafePackageEntry }
        aliases[alias] = path
    }
    func exactDirectory(_ path: String) -> Bool {
        guard let index = source.directories.firstIndex(of: path) else { return false }
        return source.directories[index].utf8.elementsEqual(path.utf8)
    }
    for path in Array(source.directories) + Array(source.files.keys) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.utf8.contains(0) }) else {
            throw KnitNoteBackupError.unsafePackageEntry
        }
        for count in 1..<components.count {
            guard exactDirectory(components.prefix(count).joined(separator: "/")) else { throw KnitNoteBackupError.unsafePackageEntry }
        }
    }
    func parents(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy(isSafeFileComponent) else { throw KnitNoteBackupError.unsafePackageEntry }
        for count in 1..<components.count {
            guard exactDirectory(components.prefix(count).joined(separator: "/")) else {
                throw KnitNoteBackupError.unsafePackageEntry
            }
        }
    }
    let references = try referencedRelativePaths(in: archive) { owner in
        let prefix = owner + "/"
        let files = source.files.keys.filter { $0.hasPrefix(prefix) }
        let directories = source.directories.filter { $0.hasPrefix(prefix) }
        if !exactDirectory(owner) {
            guard !source.directories.contains(owner) else { throw KnitNoteBackupError.unsafePackageEntry }
            guard source.files[owner] == nil, files.isEmpty, directories.isEmpty else { throw KnitNoteBackupError.unsafePackageEntry }
            // The descriptor reader also rejects a non-directory ancestor even
            // if the final owner is absent. Missing ordinary ancestors are allowed.
            let components = owner.split(separator: "/")
            for count in 1...components.count {
                guard source.files[components.prefix(count).joined(separator: "/")] == nil else {
                    throw KnitNoteBackupError.unsafePackageEntry
                }
            }
            return []
        }
        try parents(owner)
        guard directories.isEmpty else { throw KnitNoteBackupError.unknownPackageEntry }
        guard files.count <= KnitNoteBackupLimits.maximumMarkupEntriesPerPattern else { throw KnitNoteBackupError.invalidMarkup }
        for path in files {
            let name = String(path.dropFirst(prefix.count))
            guard !name.contains("/"), isMarkupFilename(name) else { throw KnitNoteBackupError.unknownPackageEntry }
        }
        return files.sorted()
    }
    var selected: [String: SyncBootstrapOutputProof] = [:]
    var total: Int64 = 0
    for path in ["projects-v1.json"] + references {
        try parents(path)
        guard let index = source.files.index(forKey: path) else { throw KnitNoteBackupError.missingReferencedFile(path) }
        guard source.files[index].key.utf8.elementsEqual(path.utf8) else { throw KnitNoteBackupError.unsafePackageEntry }
        let value = source.files[index].value
        guard value.byteCount >= 0, value.sha256.count == 32 else { throw KnitNoteBackupError.unsafePackageEntry }
        guard value.byteCount <= min(copyFileLimit(for: path), 100_000_000) else { throw KnitNoteBackupError.fileTooLarge }
        guard value.byteCount <= KnitNoteBackupLimits.maximumPackageBytes - total else { throw KnitNoteBackupError.packageTooLarge }
        total += value.byteCount; selected[path] = value
    }
    let actual = SyncBootstrapOutputProof(byteCount: Int64(source.archiveData.count), sha256: Data(SHA256.hash(data: source.archiveData)))
    guard selected["projects-v1.json"] == actual else { throw KnitNoteBackupError.integrityMismatch("projects-v1.json") }
    return (archive, selected)
}
```

- [ ] Implement `planOwnedPackage` using this exact sequence:

```swift
guard role == .validationOriginal || role == .validationMerged else { throw KnitNoteBackupError.unsafePackageEntry }
let (archive, selected) = try selectedFrozenPackageFiles(source)
let files = selected.map { path, value in
    KnitNoteBackupManifestFile(relativePath: path, byteCount: value.byteCount,
        sha256: value.sha256.map { String(format: "%02x", $0) }.joined())
}
let manifestData = try encodePackageManifest(archive: archive, appVersion: appVersion, now: now, files: files)
guard Int64(manifestData.count) <= KnitNoteBackupLimits.maximumManifestBytes else { throw KnitNoteBackupError.fileTooLarge }
let package = packageID.uuidString + ".knitnote-backup"
var actions: [SyncBootstrapOutputAction] = [.directory(role: role, path: ""),
    .directory(role: role, path: package), .directory(role: role, path: package + "/Data")]
var directories: Set<String> = ["", package, package + "/Data"]
var ids: [String: UUID] = [:]
func appendFile(_ path: String, _ proof: SyncBootstrapOutputProof) throws {
    let components = path.split(separator: "/").map(String.init)
    for count in 1..<components.count {
        let parent = components.prefix(count).joined(separator: "/")
        if directories.insert(parent).inserted { actions.append(.directory(role: role, path: parent)) }
    }
    let id = try temporaryID(path)
    ids[path] = id
    actions.append(.write(role: role, path: path, mode: .create(proof), temporaryID: id))
}
try appendFile(package + "/Data/projects-v1.json", selected["projects-v1.json"]!)
for path in selected.keys.filter({ $0 != "projects-v1.json" }).sorted() {
    try appendFile(package + "/Data/" + path, selected[path]!)
}
try appendFile(package + "/manifest.json", .init(byteCount: Int64(manifestData.count), sha256: Data(SHA256.hash(data: manifestData))))
let output = try SyncBootstrapOutputPlanner.plan(accountIDHash: accountIDHash,
    livePathSHA256: livePathSHA256, transactionID: transactionID, actions: actions,
    maximumMetadataBytes: maximumMetadataBytes)
return .init(role: role, packageID: packageID, archiveData: source.archiveData, manifestData: manifestData,
    sourceFiles: selected, temporaryIDs: ids, actions: actions, output: output)
```

The real helper writes archive first, references in ordinary `.sorted()` order, then manifest; the action order matches this. Manifest file order separately remains localizedStandardCompare. Temporary names belong to the later owned writer contract, not a claim that today's Foundation atomic writer uses these names.

- [ ] Implement pure revalidation:

```swift
func validateFrozenPackageSource(_ plan: KnitNoteBackupPackagePlan, source: KnitNoteBackupFrozenTree) throws {
    guard source.archiveData == plan.archiveData else { throw KnitNoteBackupError.integrityMismatch("projects-v1.json") }
    let (_, selected) = try selectedFrozenPackageFiles(source)
    guard selected == plan.sourceFiles else { throw KnitNoteBackupError.unsafePackageEntry }
}
```

No media bytes are read/materialized by these new APIs. Archive bytes are already supplied; validate their 20 MB bound before decode. File sizes/proof shape/package sum are admitted before manifest encoding. Exact manifest size is admitted before output-entry planning. Metadata preflight may be passed a smaller remaining allowance from future recovery preflight; this unit does not invent a budget fraction. No complete recovery-seal budget is claimed.

## Executable correspondence tests

The following fixture adapter uses files only in tests to obtain the frozen declaration. It is not an owned-output writer or an authority factory. Existing fixture methods create their ordinary backup before the planning assertions.

```swift
import CryptoKit
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct KnitNoteBackupPackagePlanTests {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func frozen(_ package: BackupFixture.Package) throws -> KnitNoteBackupFrozenTree {
        let root = package.url.appendingPathComponent("Data")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        var directories = Set<String>(), files: [String: SyncBootstrapOutputProof] = [:]
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(root.path.count + 1))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { directories.insert(path) }
            else {
                let bytes = try Data(contentsOf: url)
                files[path] = .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))
            }
        }
        return .init(archiveData: try Data(contentsOf: root.appendingPathComponent("projects-v1.json")), directories: directories, files: files)
    }
    private func plan(_ package: BackupFixture.Package, _ tree: KnitNoteBackupFrozenTree,
        cap: Int = 100_000_000) throws -> KnitNoteBackupPackagePlan {
        try package.service.planOwnedPackage(source: tree, role: .validationMerged, packageID: id,
            accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
            transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20),
            maximumMetadataBytes: cap, temporaryID: { _ in id })
    }

    @Test(arguments: [false, true]) func matchesActualHelperFilesAndManifest(library: Bool) throws {
        let f = try library ? BackupFixture.patternLibraryPackage() : BackupFixture.completePackage()
        defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let ordinary = try f.service.createPackage(appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20))
        let before = try BackupFixture.childNames(in: f.service.workRoot)
        let p = try plan(f, tree)
        #expect(try BackupFixture.childNames(in: f.service.workRoot) == before)
        #expect(p.archiveData == tree.archiveData)
        let ordinaryManifest = try Data(contentsOf: ordinary.appendingPathComponent("manifest.json"))
        #expect(p.manifestData == ordinaryManifest)
        #expect(p.sourceFiles[f.markupRelativePath] == tree.files[f.markupRelativePath])
        let manifest = try JSONDecoder().decode(KnitNoteBackupManifest.self, from: p.manifestData)
        #expect(Set(manifest.files.map(\.relativePath)) == Set(tree.files.keys))
        var writes: [String: SyncBootstrapOutputProof] = [:]
        for action in p.actions {
            if case let .write(_, path, .create(proof), _) = action { writes[path] = proof }
        }
        let package = id.uuidString + ".knitnote-backup"
        #expect(writes.count == tree.files.count + 1)
        for (path, proof) in tree.files { #expect(writes[package + "/Data/" + path] == proof) }
        #expect(writes[package + "/manifest.json"]?.sha256 == Data(SHA256.hash(data: p.manifestData)))
        #expect(p.temporaryIDs.count == writes.count)
        try f.service.validateFrozenPackageSource(p, source: tree)
        _ = try plan(f, tree, cap: p.output.reservedEncodedEntryBytes)
        #expect(throws: SyncBootstrapOutputPlanner.Error.tooLarge) { try plan(f, tree, cap: p.output.reservedEncodedEntryBytes - 1) }
    }

    @Test func changedSelectedProofAndNewMarkupInvalidatePlan() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f), p = try plan(f, tree)
        var changed = tree.files
        let old = try #require(changed[f.firstRelativePath])
        changed[f.firstRelativePath] = .init(byteCount: old.byteCount, sha256: Data(repeating: 9, count: 32))
        #expect(throws: KnitNoteBackupError.self) {
            try f.service.validateFrozenPackageSource(p, source: .init(archiveData: tree.archiveData, directories: tree.directories, files: changed))
        }
        var extra = tree.files
        let owner = f.markupRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        extra[owner + "/9999.json"] = .init(byteCount: 2, sha256: Data(repeating: 8, count: 32))
        #expect(throws: KnitNoteBackupError.self) {
            try f.service.validateFrozenPackageSource(p, source: .init(archiveData: tree.archiveData, directories: tree.directories, files: extra))
        }
        #expect(throws: KnitNoteBackupError.self) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories.subtracting([owner]), files: tree.files))
        }
    }

    @Test func unknownMarkupAndOversizeProofFailWithoutOutputs() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let before = try BackupFixture.childNames(in: f.service.workRoot)
        var files = tree.files
        files[f.firstRelativePath] = .init(byteCount: 100_000_001, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        let owner = f.markupRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        files = tree.files; files[owner + "/unexpected.bin"] = .init(byteCount: 1, sha256: Data(repeating: 2, count: 32))
        #expect(throws: KnitNoteBackupError.unknownPackageEntry) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        #expect(try BackupFixture.childNames(in: f.service.workRoot) == before)
    }
}
```

- [ ] Run `swift test --filter KnitNoteBackupPackagePlanTests`, then `swift test --filter KnitNoteBackupServiceTests`, and the accepted `SyncBootstrapOutputPlannerTests`. No broad App/cloud validation is justified by this inert change.
- [ ] Include these additional tests in the same test file. They exercise real-helper limits without allocating large media bytes; ordinary descriptor tests continue to cover physical source mutation.

```swift
extension KnitNoteBackupPackagePlanTests {
    @Test func exactParentSpellingRejectsCanonicalUnicodeAlias() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        var directories = tree.directories; directories.insert("e\u{0301}")
        var files = tree.files
        files["é/ignored"] = .init(byteCount: 1, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            try plan(f, .init(archiveData: tree.archiveData, directories: directories, files: files))
        }
    }

    @Test func markupEntryAndByteCapsRemainSpecific() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        let owner = f.markupRelativePath.split(separator: "/").dropLast().joined(separator: "/")
        var files = tree.files.filter { !$0.key.hasPrefix(owner + "/") }
        for page in 0..<512 { files[owner + "/\(page).json"] = .init(byteCount: 2, sha256: Data(repeating: 1, count: 32)) }
        _ = try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        files[owner + "/512.json"] = .init(byteCount: 2, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.invalidMarkup) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        files = tree.files
        files[f.markupRelativePath] = .init(byteCount: 2_000_000, sha256: Data(repeating: 1, count: 32))
        _ = try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        files[f.markupRelativePath] = .init(byteCount: 2_000_001, sha256: Data(repeating: 1, count: 32))
        #expect(throws: KnitNoteBackupError.fileTooLarge) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
    }

    @Test func archiveProofAndMissingReferenceReject() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        var files = tree.files
        let archive = try #require(files["projects-v1.json"])
        files["projects-v1.json"] = .init(byteCount: archive.byteCount, sha256: Data(repeating: 8, count: 32))
        #expect(throws: KnitNoteBackupError.integrityMismatch("projects-v1.json")) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
        files = tree.files; files.removeValue(forKey: f.firstRelativePath)
        #expect(throws: KnitNoteBackupError.missingReferencedFile(f.firstRelativePath)) {
            try plan(f, .init(archiveData: tree.archiveData, directories: tree.directories, files: files))
        }
    }

    @Test func roleTimestampAndEmptyArchiveAreExplicit() throws {
        let f = try BackupFixture.completePackage(); defer { try? FileManager.default.removeItem(at: f.cleanupRoot) }
        let tree = try frozen(f)
        #expect(throws: KnitNoteBackupError.unsafePackageEntry) {
            try f.service.planOwnedPackage(source: tree, role: .original, packageID: id,
                accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
                transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 20))
        }
        let first = try plan(f, tree)
        let later = try f.service.planOwnedPackage(source: tree, role: .validationMerged, packageID: id,
            accountIDHash: String(repeating: "a", count: 64), livePathSHA256: String(repeating: "b", count: 64),
            transactionID: id, appVersion: "1.2.0", now: Date(timeIntervalSince1970: 21))
        #expect(first.manifestData != later.manifestData)
        let bytes = try JSONEncoder().encode(ProjectArchive(version: ProjectArchive.currentVersion, projects: [], yarns: []))
        let empty = KnitNoteBackupFrozenTree(archiveData: bytes, directories: [], files: [
            "projects-v1.json": .init(byteCount: Int64(bytes.count), sha256: Data(SHA256.hash(data: bytes)))])
        let result = try plan(f, empty)
        #expect(result.sourceFiles.count == 1)
        #expect(result.temporaryIDs.count == 2)
    }
}
```
- [ ] Review source call sites: ordinary path selection and manifest bytes use the shared functions; new planning methods have zero disk reads/writes, source-opening calls or workRoot usage. No callers in SyncBootstrapTransaction, App or account factories are introduced.

## Main approval point and remaining obligations

This is a narrower useful adaptation than an owned backup executor: shared real-helper semantics + exact content plan, with successful actual-package correspondence. It supports Original or projected Merged inputs and does not create a fake runtime issuer. Main approved this boundary under delegated technical authority; implementation is limited to this prerequisite.

Physical source revalidation is intentionally not implemented by a proof-only planner: the future bootstrap owner must bind original root/device/inode, complete source/pending baseline and frozen source proof producer; compare exact current inputs before preparing and before execution; stream-copy under actual no-follow readers and verify copied bytes; keep full producers frozen. The future sink must replace ordinary Foundation atomic behavior only in its owned route, use the planned temporaries, retain partial outputs, and perform real backup inspection. No result of this prerequisite authorizes output creation or proves complete recovery capacity.

No production/test edits, compiler/test run, or commit was performed in preparing this draft.
