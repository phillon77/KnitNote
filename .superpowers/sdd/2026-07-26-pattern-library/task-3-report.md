# Task 3 Report: Owned Asset Storage and Durable Import Inbox

## Scope

Implemented only Task 3. No UI, localization, Share Extension target, or Xcode project changes were made.

## RED

1. Added focused tests for inbox restart/byte preservation, empty and disguised-file rejection, SHA-256 duplicate reuse, retained ambiguous migrated duplicates, and explicit selection retry.
2. Ran `swift test --filter PatternImport` before production implementation.
3. It failed because `PatternInboxFileService`, `PatternInboxItem`, `PatternImportOutcome`, `PatternStorageLocations`, and `JSONProjectStore.processPatternInboxItem` did not exist.

## GREEN

Implemented:

- `PatternStorageLocations`: private Application Support pattern assets, iOS App Group inbox with a throwing missing-container path.
- `PatternInboxItem` and `PatternImportOrigin` Codable durable sidecars.
- `PatternInboxFileService`: candidate copy, size/type/content validation, atomic item + sidecar publication, safe reload, and removal after publication.
- `PatternFileService`: SHA-256 metadata, owned `Patterns/Assets/<assetID>.<ext>` installation, byte-checked reuse, and export URL access.
- `PatternImportCoordinator`: detached validation/hash preparation, deterministic asset identifiers, and normalized-name matching support.
- `JSONProjectStore.processPatternInboxItem`: active pattern transaction accounting, current-array duplicate resolution after detached work, archive publication before inbox deletion, asset cleanup on persistence failure, optional project usage creation, and deterministic ambiguous outcomes.

The persistence path now validates the complete pattern library snapshot and advances `dataGeneration` on successful publication.

## Verification

- `swift test --filter PatternInboxFileServiceTests` — PASS (2 tests)
- `swift test --filter PatternImportCoordinatorTests` — PASS (3 tests)
- `swift test --filter PatternFileServiceTests` — PASS (3 tests)
- `swift test` — initial PASS (582 tests, 44 suites; before remediation)
- `git diff --check` — PASS

## Files

- Replaced `Sources/KnitNoteCore/Patterns/PatternFileService.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternStorageLocations.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternInboxItem.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternImportCoordinator.swift`
- Modified `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Added `Tests/KnitNoteCoreTests/PatternInboxFileServiceTests.swift`
- Added `Tests/KnitNoteCoreTests/PatternImportCoordinatorTests.swift`
- Extended `Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift` with the requested injected-root `PatternImportHarness`.

## Concerns

- The existing project-scoped `PatternDocument` APIs remain temporarily for source compatibility; Task 4 is responsible for moving caller/UI paths to the library pipeline.
- The App Group location is deliberately injected in tests and extension contexts. `PatternStorageLocations.live()` throws on iOS if the configured group is unavailable and does not substitute an unrelated directory.

## Review Remediation: Crash Safety and Security

### RED

The review found concrete protocol defects rather than cosmetic gaps:

- an owned staged file could be orphaned between move and sidecar write;
- a cleanup failure could remove the only manifest before staged-file cleanup;
- ImageIO accepted JPEG bytes under a `.png` name;
- source/staged symlinks and archive-controlled asset paths were trusted;
- the production live store constructed its inbox independently of the throwing App Group location.

New focused tests first failed for missing durable recovery/canonical asset APIs, JPEG-as-PNG acceptance, and a staged symlink that recovery left in place.

### GREEN

- Replaced the inbox sidecar with a versioned `staged` / `committed` manifest protocol. Archive persistence succeeds before the manifest becomes committed; committed cleanup is idempotent and best-effort, and later recovery retries it.
- Recovery removes owned UUID candidates (including symlinks without following their targets), quarantines corrupt/missing-manifest owned staged files, quarantines corrupt manifests, and unlinks controlled staged symlinks without following them.
- Image imports compare ImageIO's actual UTI with the claimed PNG/JPEG/HEIC extension.
- Source and staged files must be regular non-symlink files. Asset URLs require `<asset-id>.<allowed-extension>`, canonical direct descent from `Patterns/Assets`, and no symlink file; migration/load routes through the same validation.
- `PatternFileService.live()` now throws rather than silently falling back. `JSONProjectStore.live()` obtains assets and inbox together from `PatternStorageLocations.live()`; an unavailable App Group produces a mutation-disabled error store instead of a private fallback inbox.
- Added internal-only failure seams for asset move, archive write, and inbox removal. Tests run real temporary roots, JSON stores, restarts, archive decoding, and byte-for-byte exports.

### Additional Verification

- Focused Task 3 suite — PASS (17 tests): durable recovery, corrupt/orphan behavior, candidates/staged symlinks, traversal, exact image type, duplicate/selection, archive-write/asset-move/cleanup failure retry, cancellation, restart, and export bytes.
- Final `swift test` — PASS (594 tests, 44 suites).
- Final `git diff --check` — PASS.

## Review Remediation 2: Publication Journals and Live Dependency Recovery

### RED

The second review identified four remaining correctness gaps:

- an asset move had no durable transaction record spanning candidate to final asset;
- a failed post-archive `markCommitted` could be surfaced as an import failure or lose its recovery proof;
- the live-store failure path still created a private `.UnavailablePatternInbox` fallback;
- startup did not proactively reconcile the inbox, and asset-root validation did not reject a symlinked parent directory.

New tests first exposed the missing retry-load transition: a store remained disabled after its injected live locations became available because successful empty-store recovery did not clear the previous availability error.

### GREEN

- Added a durable asset transaction journal under `Patterns/Assets/.Transactions`. It is written before the candidate/final move, is retained while a published inbox sidecar still needs reconciliation, and removes only unreferenced crash artifacts or a fully cleaned committed transaction.
- Archive persistence is the success boundary. A post-publish inbox `markCommitted` failure now returns the created/existing outcome; a fresh startup uses the journal's archive reference to promote and clean the inbox without a second archive mutation.
- Startup recovery now runs both asset-transaction and inbox reconciliation for an absent archive and for a decoded archive before normal migration/validation continues.
- Removed `.UnavailablePatternInbox`. The unavailable live store has no pattern/inbox services; `retryLoad` and mutations remain blocked until the real `PatternStorageLocations.live()` provider resolves, then load from the real locations.
- Asset URL validation now compares the physical `Patterns/Assets` directory and its direct parent path, rejecting an `Assets` symlink before returning an archive-controlled file URL.

### Additional Verification

- `swift test --filter PatternImportFaultTests --filter PatternImportSecurityTests --filter PatternInboxFileServiceTests` — PASS (19 tests), including fresh-start candidate/final crash artifacts, failed committed-sidecar writes, proactive inbox recovery, unavailable-then-available live dependencies, and symlinked asset-parent rejection.
- `swift test` — PASS (599 tests, 44 suites).
- `git diff --check` — PASS.

## Review Remediation 4: Inbox Canonical Roots and Partial Commit Cleanup

### RED

The accepted review findings showed three remaining inbox-side recovery gaps:

- a symlinked inbox `.Candidates` directory could surface a raw filesystem error
  instead of a typed blocked path;
- a committed manifest whose staged file had already been deleted was treated as
  corrupt rather than as a partial cleanup that only needed its manifest removed;
- journal evidence lookup could throw for corrupt or unsupported inbox manifests,
  turning a recoverable quarantine into an unreadable archive.

Added regressions for an external UUID candidate behind a symlinked inbox root,
an injected failure on only the second cleanup removal, and both corrupt and
unknown-version manifests while the archive asset remains valid.

### GREEN

- Inbox recovery and all owned create/list/manifest/remove/quarantine operations
  now validate the physical inbox root and `.Candidates`, `Items`, `Manifests`,
  and `.Quarantine` descendants before touching them. A symlinked path raises
  `PatternInboxError.invalidItem`; external UUID files are not enumerated or
  removed.
- Recovery recognizes a committed manifest with missing staged bytes as partial
  cleanup. It retries only the manifest removal, reports committed cleanup, and
  then permits the associated asset journal to complete without republishing.
- `journalVerificationItem` treats corrupt, unknown-version, or otherwise
  unsupported sidecars as non-evidence. Asset recovery quarantines the journal,
  then normal inbox recovery quarantines the malformed manifest and staged bytes;
  the already-referenced archive asset remains available and startup stays usable.

### Rejected Review Suggestions

Descriptor-anchored `openat`/`unlinkat` operations and a secret-keyed MAC were
not implemented. The approved product scope has no adversarial concurrent
filesystem-writer or authenticated anti-tamper threat model, and the local
sandbox/App Group design has no trusted secret-key source. Adding Darwin-only
descriptor plumbing and a key-management scheme would materially expand
complexity without a specified product requirement. Canonical path checks and
SHA-256 journal integrity continue to cover accidental corruption within the
approved scope.

### Additional Verification

- Task 3 focused suite — PASS (32 tests), including inbox symlink isolation,
  partial committed cleanup, and corrupt/unknown manifest quarantine.
- `swift test` — PASS (606 tests, 44 suites).
- `git diff --check` — PASS.

## Review Remediation 3: Canonical Recovery Roots and Journal Binding

### RED

The third review found that recovery's owned-file deletion did not first prove
that `Patterns/Assets` and its recovery subdirectories were physical descendants
of the configured root. It also found that the journal only carried an asset ID,
and that normal publication removed the journal after `markCommitted` before
the inbox cleanup actually succeeded.

Added regressions for a symlinked `Assets` tree containing external UUID-named
candidate/final files, a decodable journal tampered to point at a different
pending inbox item, and a real injected cleanup failure followed by fresh
startup. They initially failed by respectively permitting the unsafe recovery
path, retaining the tampered journal, and removing the journal too early.

### GREEN

- All asset installation, transaction, rollback, deletion, and startup-recovery
  paths now validate the physical `Assets`, `.Candidates`, `.Transactions`, and
  transaction-quarantine directories before listing, creating, moving, or
  deleting. An externally symlinked tree throws and leaves external bytes intact.
- The versioned journal now binds the exact inbox item (including its staged
  filename and normalized original identity), staged content metadata
  (hash/size/type/page count), and full `PatternAsset` identity. Its canonical
  payload has a SHA-256 integrity value. Recovery verifies that payload against
  the archive asset, current inbox manifest/staged bytes, and final asset bytes
  before treating it as archive-publication proof. A malformed or cross-item
  journal is quarantined without deleting its referenced archive asset or a
  pending inbox item.
- A transaction journal is now removed only after both `markCommitted` and
  `cleanupCommitted` succeed. If cleanup is interrupted, fresh startup retries
  cleanup idempotently and removes the journal only after the inbox is gone.

### Additional Verification

- Task 3 focused suite — PASS (28 tests), including external symlink safety,
  tampered journal isolation, and cleanup-failure restart recovery.
- `swift test` — PASS (602 tests, 44 suites).
- `git diff --check` — PASS.
