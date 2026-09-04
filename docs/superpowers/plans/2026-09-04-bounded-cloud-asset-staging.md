# Bounded Cloud Asset Staging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unreleased retirement-evidence implementation with bounded App-Sandbox attachment staging that keeps exact upload references durable until acknowledgement.

**Architecture:** Split the current monolithic service into a descriptor-safe account file store, a checksummed manifest store, and a small CloudKit-facing workflow service. Cooperating KnitNote processes serialize mutations with one account kernel lock; manifest-first authority and restart reconciliation provide crash safety without permanent retirement/evidence files.

**Tech Stack:** Swift 6, Foundation, CryptoKit, CloudKit, Darwin descriptor APIs, Swift Testing, Xcode app tests.

**Spec:** `docs/superpowers/specs/2026-09-04-cloud-asset-staging-sandbox-design.md`

## Global Constraints

- Reuse `SyncAttachmentVersion` and `SyncAttachmentSource`; do not create `SyncAttachmentMetadata`.
- The threat model is cooperating App-Sandbox processes. Do not add tests or production machinery for a malicious same-user actor mutating a pathname between two already validated syscalls.
- Reject symlinks, hard links, FIFO/device/socket entries, traversal, wrong-owner locks, corrupt manifests, read-time changes, and account crossover.
- `SyncPublicationFileLimits.maximumAttachmentBytes` is exactly `100_000_000`; bounded reads consume at most declared size plus one overrun byte.
- Every mutation owns a distinct `<mutation UUID>-<version UUID>.asset`; cloud staging never deletes the journal/original `SyncAttachmentSource`.
- Every save attempt creates a new `CKAsset` object from the same durable staged URL.
- Upload manifest and quarantine manifest are versioned canonical sorted-key JSON with domain-separated SHA-256 checksums.
- Quarantine is bounded to 4 entries and `400_000_000` bytes per account.
- No `Retired`, `.zero-retirement-evidence`, retirement hook, or permanent cleanup-evidence format may remain.
- CloudKit types remain outside `Sources/KnitNoteCore` and the Watch target.
- Do not add lifecycle wiring, entitlements, live CloudKit calls, schema deployment, version/build changes, push, upload, or release actions.

---

### Task 1: Cooperative account file store

**Files:**
- Create: `KnitNote/CloudSync/CloudAssetFileStore.swift`
- Create: `Tests/KnitNoteAppTests/CloudAssetFileStoreTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: account identifier, service root URL, `SyncPublicationFileLimits.maximumAttachmentBytes`.
- Produces: `CloudAssetAccountFileStore.withAccountLock`, `readExternal`, `readOwned`, `publishNoClobber`, `replaceAtomically`, `removeOwned`, `listOwned`, and directory synchronization helpers used by Tasks 2–4.

- [ ] **Step 1: Add failing account and descriptor-safety tests**

Create tests that instantiate two store objects for the same account and assert one blocks while a subprocess holds the same regular owned `.lock`; another account does not block. Add seeded symlink, two-link regular file, FIFO, traversal component, wrong-owner/nonregular lock, and account-directory replacement cases. Add a descriptor growth fixture proving a declared `N` byte read consumes no more than `N + 1` bytes.

```swift
@Test func cooperatingProcessesSerializeOneAccount() async throws
@Test func accountTokensAreOpaqueAndIsolated() throws
@Test func unsafeObjectsAndTraversalFailClosed() throws
@Test func declaredReadUsesOnlyOneOverrunByte() throws
@Test func accountTreeReplacementBeforeReturnFailsClosed() throws
```

- [ ] **Step 2: Run the focused tests and capture RED**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBoundedAssetsTask1RED \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/CloudAssetFileStoreTests
```

Expected: exit 65 because `CloudAssetAccountFileStore` does not exist.

- [ ] **Step 3: Implement the account file store**

Implement the following internal boundary and keep opened descriptors alive only inside the locked closure:

```swift
struct CloudAssetAccountDirectories {
    let account: Int32
    let uploads: Int32
    let installed: Int32
    let quarantine: Int32
}

final class CloudAssetAccountFileStore: @unchecked Sendable {
    init(rootURL: URL, accountIdentifier: String, maximumAssetBytes: Int = 100_000_000) throws
    func withAccountLock<T>(_ body: (CloudAssetAccountDirectories) throws -> T) throws -> T
    func readExternal(_ url: URL, expectedByteCount: Int64, expectedSHA256: Data) throws -> Data
    func readOwned(named: String, in directory: Int32, expectedByteCount: Int64, expectedSHA256: Data) throws -> Data
    func publishNoClobber(_ data: Data, named: String, in directory: Int32) throws
    func replaceAtomically(_ data: Data, named: String, in directory: Int32) throws
    func removeOwned(named: String, in directory: Int32) throws
    func listOwned(in directory: Int32) throws -> [String]
    func synchronize(_ directory: Int32) throws
}
```

Use `openat` with `O_NOFOLLOW | O_CLOEXEC`, `fstat`, `fstatat`, `renameatx_np(RENAME_EXCL)` for no-clobber publication, same-directory atomic rename for replacement, `fsync` on files and directories, and one kernel lock per account. `removeOwned` may use `unlinkat` only while the account lock is held and only after immediate regular/single-link/owner/name validation; this is valid under the approved cooperative-process threat model.

- [ ] **Step 4: Run Task 1 GREEN and static checks**

Run the focused command from Step 2, `git diff --check`, and `plutil -lint KnitNote.xcodeproj/project.pbxproj`. Expected: all pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add KnitNote/CloudSync/CloudAssetFileStore.swift \
  Tests/KnitNoteAppTests/CloudAssetFileStoreTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add bounded cloud asset file store"
```

---

### Task 2: Checksummed manifest authority

**Files:**
- Create: `KnitNote/CloudSync/CloudAssetManifestStore.swift`
- Create: `Tests/KnitNoteAppTests/CloudAssetManifestStoreTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CloudAssetAccountFileStore`, `CloudAssetAccountDirectories`, canonical `SyncAttachmentVersion`.
- Produces: `CloudAssetUploadReference`, `CloudAssetQuarantineReference`, `CloudAssetManifestSnapshot`, and `CloudAssetManifestStore.load/commit` for Tasks 3–4.

- [ ] **Step 1: Add failing canonical-manifest tests**

Cover canonical round-trip, sorted entries, checksum bit flip, valid-JSON field mutation/removal, duplicate mutation ID, duplicate filename, absolute/traversal filename, unsupported version, missing manifest with empty/nonempty Uploads, and atomic commit failure preserving the prior manifest.

```swift
struct CloudAssetUploadReference: Codable, Equatable, Sendable {
    let mutationID: UUID
    let version: SyncAttachmentVersion
    let relativeFilename: String
}

struct CloudAssetQuarantineReference: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let byteCount: Int64
    let contentSHA256: Data
    let relativeFilename: String
}

struct CloudAssetManifestSnapshot: Equatable, Sendable {
    var uploads: [CloudAssetUploadReference]
    var quarantine: [CloudAssetQuarantineReference]
}
```

- [ ] **Step 2: Run focused tests and capture RED**

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBoundedAssetsTask2RED \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/CloudAssetManifestStoreTests
```

Expected: exit 65 because the manifest types and store do not exist.

- [ ] **Step 3: Implement canonical upload and quarantine manifests**

Implement:

```swift
final class CloudAssetManifestStore {
    init(fileStore: CloudAssetAccountFileStore)
    func load(in directories: CloudAssetAccountDirectories) throws -> CloudAssetManifestSnapshot
    func commit(_ snapshot: CloudAssetManifestSnapshot, in directories: CloudAssetAccountDirectories) throws
}
```

Encode a version-1 payload with sorted uploads and quarantine entries, then wrap its canonical bytes and domain-separated SHA-256 checksum in a sorted-key JSON envelope. Validate all identifiers, filenames, sizes, hashes, immutable version bindings, total quarantine count/bytes, and canonical re-encoding before returning or committing. Missing manifest initializes only when Uploads and Quarantine contain no final service-owned files.

- [ ] **Step 4: Run Task 2 GREEN and Task 1 regressions**

Run both `CloudAssetManifestStoreTests` and `CloudAssetFileStoreTests`. Expected: all pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add KnitNote/CloudSync/CloudAssetManifestStore.swift \
  Tests/KnitNoteAppTests/CloudAssetManifestStoreTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: add cloud asset manifest authority"
```

---

### Task 3: Rewrite immutable upload staging

**Files:**
- Rewrite: `KnitNote/CloudSync/CloudAssetStagingService.swift`
- Replace and split: `Tests/KnitNoteAppTests/CloudAssetStagingServiceTests.swift`
- Create: `Tests/KnitNoteAppTests/CloudAssetUploadStagingTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Task 1 file store, Task 2 manifest store, `SyncAttachmentVersion`, `SyncAttachmentSource`, exact `SyncMutationIdentity`.
- Produces: `CloudAssetUploadStagingBoundary.stageUpload`, `assetForUpload`, `acknowledgeUpload`, and `reconcile` while preserving the Task 2 transport materializer integration surface.

- [ ] **Step 1: Replace retirement-era tests with upload contract tests**

Delete tests and hooks whose only purpose is a malicious post-validation same-user substitution, `Retired`, or `.zero-retirement-evidence`. Add exact behavior tests:

```swift
@Test func stageCopiesAndVerifiesDistinctMutationOwnedBytes() throws
@Test func exactStageRetryIsIdempotentAndDivergenceFailsClosed() throws
@Test func everySaveAttemptCreatesFreshCKAssetAtStableURL() throws
@Test func acknowledgementRemovesOnlyExactMutationAfterManifestCommit() throws
@Test func crashAfterManifestRemovalLeavesRecoverableOrphan() throws
@Test func corruptOrMissingManifestPreservesEveryFinalUpload() throws
@Test func restartReconcilesOnlyCanonicalUnreferencedFiles() throws
@Test func tenThousandStageAcknowledgementCyclesRemainBounded() throws
```

The sustained test uses small payloads and requires zero manifest entries, zero Upload files, no `Retired` or evidence directory, and constant account metadata count after 10,000 cycles.

- [ ] **Step 2: Run the upload suite and capture RED**

Run the new upload suite against the existing retirement implementation. Expected: failure because retirement/evidence artifacts remain and the service does not use one file per mutation.

- [ ] **Step 3: Rewrite the service around manifest-first authority**

Keep the public boundary explicit:

```swift
protocol CloudAssetUploadStagingBoundary: AnyObject {
    func stageUpload(version: SyncAttachmentVersion, source: SyncAttachmentSource, mutationID: UUID) throws
    func assetForUpload(versionID: UUID, mutationID: UUID) throws -> CKAsset
    func acknowledgeUpload(versionID: UUID, mutationID: UUID) throws
    func reconcile() throws
}
```

Remove every retirement/evidence type, directory, hook, parser, and recovery branch. Use exact `<mutation UUID>-<version UUID>.asset` files. Stage file first and commit manifest second; acknowledge by committing manifest removal first and cleaning the now-unreferenced exact file second. On restart, a valid manifest preserves referenced files and removes only canonical regular unreferenced orphans. Missing/corrupt manifest with final uploads fails closed.

- [ ] **Step 4: Run upload, manifest, file-store, transport, and coordinator tests**

Run the three bounded-asset suites plus `CloudSyncEngineTransportTests` and `KnitNoteCloudSyncCoordinatorTests`. Expected: all pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add KnitNote/CloudSync/CloudAssetStagingService.swift \
  Tests/KnitNoteAppTests/CloudAssetStagingServiceTests.swift \
  Tests/KnitNoteAppTests/CloudAssetUploadStagingTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "refactor: bound CloudKit upload staging"
```

---

### Task 4: Verified download installation and bounded quarantine

**Files:**
- Modify: `KnitNote/CloudSync/CloudAssetStagingService.swift`
- Create: `Tests/KnitNoteAppTests/CloudAssetDownloadStagingTests.swift`
- Modify: `Tests/KnitNoteAppTests/CloudAssetManifestStoreTests.swift`
- Modify: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Tasks 1–3 file, manifest, and staging boundaries.
- Produces: final `CloudAssetStagingBoundary`, adding `installDownload` and `quarantine` to Task 3's upload boundary, with a maximum of 4 quarantine entries and `400_000_000` bytes.

- [ ] **Step 1: Add failing download and quarantine tests**

Cover exact install, idempotent existing destination, divergent existing destination, source hash mismatch, source size mismatch before allocation, read-time growth capped at declared plus one, installed destination preservation, quarantine count/byte eviction, cleanup failure blocking new quarantine, account isolation, crash after temp fsync, and restart orphan cleanup.

```swift
protocol CloudAssetStagingBoundary: CloudAssetUploadStagingBoundary {
    func installDownload(version: SyncAttachmentVersion, sourceURL: URL) throws -> URL
    func quarantine(version: SyncAttachmentVersion, sourceURL: URL, reason: CloudAssetQuarantineReason) throws
}
```

- [ ] **Step 2: Run the download suite and capture RED**

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBoundedAssetsTask4RED \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/CloudAssetDownloadStagingTests
```

Expected: exit 65 because the rewritten boundary does not yet implement download/quarantine methods.

- [ ] **Step 3: Implement verified installation and bounded quarantine**

Read the opened source once with exact expectations. Publish verified Installed bytes with no-clobber semantics; verify and reuse an exact existing version, never overwrite divergent bytes. On mismatch, preserve the installed destination and create at most one bounded quarantine copy from the already opened/bounded data. Before adding a fifth entry or exceeding `400_000_000` bytes, commit removal of oldest entries and then clean their files; if cleanup cannot be made durable, reject the new quarantine entry.

- [ ] **Step 4: Run all Task 4 and project regressions**

Run:

```bash
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBoundedAssetsFinal \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/CloudAssetFileStoreTests \
  -only-testing:KnitNoteAppTests/CloudAssetManifestStoreTests \
  -only-testing:KnitNoteAppTests/CloudAssetUploadStagingTests \
  -only-testing:KnitNoteAppTests/CloudAssetDownloadStagingTests \
  -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests \
  -only-testing:KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests
```

Then run the relevant Core filter, complete `swift test --disable-sandbox`, and unsigned generic iOS build. Expected: all pass; no retirement/evidence symbols or directories remain.

- [ ] **Step 5: Commit Task 4**

```bash
git add KnitNote/CloudSync/CloudAssetStagingService.swift \
  Tests/KnitNoteAppTests/CloudAssetDownloadStagingTests.swift \
  Tests/KnitNoteAppTests/CloudAssetManifestStoreTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: install and quarantine CloudKit assets"
```

---

## Completion Gate

- Every task receives a fresh task-scoped review and up to five scoped fix rounds.
- A final whole-plan review must report zero Critical and zero Important findings.
- Verify `git diff --check`, project membership, no Core/Watch CloudKit import, no `SyncAttachmentMetadata`, no retirement/evidence implementation, and clean tracked worktree.
- This plan completes only the redesigned Task 4. After it passes, resume Task 5 of `docs/superpowers/plans/2026-09-02-cross-device-sync-2-cloudkit-assets.md`.
