# Task 11 Report: Backup Manifest 2 and Pattern Round Trips

## Scope

Implemented only Task 11. KnitNote complete manual backups now use manifest
format 2 and preserve the archive-level pattern library. Task 12 backup history
and reminder behavior was not added. Storage remains local-first with manual
backup and restore; no cloud sync or tracking was introduced.

## Manifest 2

Format 2 adds:

- the exact `patternCount` shown in backup preview;
- a closed list of every regular file below `Data`;
- each file's canonical relative path, exact byte count, and lowercase SHA-256;
- the recognized critical feature `data-file-sha256`.

Format 1 continues to decode, preview with `patternCount == nil`, stage, restore,
and migrate legacy project-owned patterns to archive schema 10.

Validation rejects:

- unsupported manifest or archive versions and unknown critical features;
- absolute, traversal, backslash, hidden, empty-component, or noncanonical paths;
- duplicate paths and Unicode-normalized case collisions;
- symbolic links, unknown tree entries, and missing referenced files;
- manifest/physical file-set mismatch, size mismatch, or SHA-256 mismatch;
- duplicate asset, pattern, usage, project, or pattern-project identifiers;
- dangling asset, pattern, project, or yarn references;
- unsafe owned filenames, oversized files/packages, and invalid markup.

The external package is checked before staging. The app-owned staged copy is
checked again after bounded copying and immediately before installation.

## Included Pattern Data

The backup contains:

- `projects-v1.json`, including `PatternAsset`, `StoredPattern`, and every active
  or inactive `PatternProjectUsage`;
- each referenced original PDF or image under `Patterns/Assets`;
- each accepted usage markup page under `Patterns/UsageMarkup`;
- usage reading page, zoom, offset, highlight mode/positions, page notes, and
  project counter state stored in the archive;
- active usage ordering required by automatic project-cover fallback.

The backup does not contain thumbnail caches, PatternInbox data, candidates,
transaction journals, publication receipts, or quarantine artifacts.

## Transaction and Recovery Boundaries

The existing backup operation gate remains the single store boundary. Active
pattern or journal transactions reject export and restore. While replacement is
in progress, project, yarn, reader, markup, import, link, unlink, and deletion
mutations are rejected.

Restore remains:

1. nonmutating external-package inspection;
2. bounded copy into an app-owned staging directory;
3. staged-tree revalidation;
4. same-volume live-to-rollback rename;
5. staged-data-to-live rename;
6. store reload;
7. rollback and original reload on failure;
8. rollback cleanup only after the restored archive reloads successfully.

The transaction-gate race tests are serialized as a suite so their synchronous
injected latches cannot exhaust Swift's cooperative worker pool. Timeouts were
not enlarged, and every test still waits for the exact injected boundary before
asserting that mutations are rejected.

## TDD Evidence

First manifest RED:

```text
swift test --filter KnitNoteBackupManifestTests
error: KnitNoteBackupPreview has no member patternCount
error: cannot find KnitNoteBackupManifestFile in scope
error: extra arguments patternCount/files/criticalFeatures
```

Security RED:

```text
swift test --filter KnitNoteBackupServiceTests
error: KnitNoteBackupError has no member integrityMismatch
```

The new tests then drove the manifest model, archive-level path walker,
streaming integrity checks, staged revalidation, and schema-10 reference
validation. Mutation-backed integration tests export complete pattern state,
destroy the live projects/pattern/files, restore, and compare exact IDs, bytes,
reader states, notes, counters, markup, active/inactive relationships, and
cover-fallback relationship. Separate tests restore a real format-1 legacy
pattern package and prove corrupt format-2 preflight does not change live data.

## Verification

Focused tests:

- `swift test --filter KnitNoteBackupManifestTests`: 4 passed.
- `swift test --filter KnitNoteBackupServiceTests`: 56 passed.
- `swift test --filter KnitNoteBackup`: 60 passed.
- `swift test --filter JSONProjectStoreTests`: 69 passed.
- `swift test --filter PatternShareInboxEnqueuerTests`: 8 passed.

Full tests:

```text
swift test --quiet
785 tests in 67 suites passed
```

Fresh builds with separate DerivedData and `CODE_SIGNING_ALLOWED=NO`:

- iOS App: exit 0.
- macOS App: exit 0.
- iOS Share Extension: exit 0.
- watchOS App: exit 0.

Static verification:

- localization catalog parses as JSON;
- Xcode project, App/Share/Watch Info plists, and all entitlements pass
  `plutil -lint`;
- every touched Swift source parses with `xcrun swiftc -parse`;
- `git diff --check` passes.

## Files

- `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`
- `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- `Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift`
- `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternShareInboxEnqueuerTests.swift`
- `task-11-report.md`

## Review Fix Round 1

### P1: crash-safe restore replacement

Root cause: replacement recovery previously treated a structurally valid live
archive as committed. A format-1/schema-9 backup therefore looked valid before
its required 9-to-10 migration ran. Termination after staged data became live
but before reload/migration allowed launch recovery to delete the only rollback;
a later migration failure then lost the original data.

The replacement now owns an integrity-bound durable journal in the backup work
root. It records the transaction UUID, exact rollback basename, whether an
original live root existed, and one of these phases:

- `prepared`
- `installedAwaitingReload`
- `committed`
- `rolledBack`

Install writes `prepared` before moving the original and
`installedAwaitingReload` only after the replacement is live. Launch recovery
returns an awaiting installation without deleting its rollback. The live store
then reloads the installed archive, including migration and persisted schema-10
validation. Only a successful reload commits and cleans the rollback. Failure
atomically restores the original and reloads it. A committed cleanup tombstone
and journal survive cleanup failure and are idempotently completed on restart.

Regression coverage proves:

- invalid legacy PDF bytes pass backup structural validation but fail migration,
  after which restart restores the schema-10 original byte-for-byte;
- a valid legacy PDF migrates, persists schema 10, and only then cleans rollback;
- a crash after staged data becomes live remains recoverable on restart;
- partial commit cleanup is retried on restart and a second recovery is a no-op.

### P1: bounded descriptor-anchored export

Root cause: export loaded the entire archive with `Data(contentsOf:)`, copied
referenced files with `FileManager.copyItem`, and calculated size/hash only
afterwards. Limits therefore could not prevent memory/disk exhaustion, hashes
were not tied to the exact copy stream, and source changes could race export.

Export now:

- opens the live root and every path component with descriptor-relative
  `openat`, `O_NOFOLLOW`, and regular-file/directory checks;
- rejects an oversized archive from descriptor metadata before allocating and
  reads it with a strict bounded loop;
- preflights every referenced file and the aggregate logical size before
  copying any media;
- copies in 64 KiB chunks while enforcing file and aggregate limits;
- computes SHA-256 and byte count from the same bytes written;
- compares descriptor identity, size, copied byte count, mtime, and ctime before
  accepting the source;
- writes each destination to a private temporary file, `fsync`s, renames
  atomically, and removes the whole package plus temporary output on failure.

Real sparse-file and mutation-hook regressions cover archive, pattern asset,
markup, aggregate, and mid-stream growth limits. They also prove no partial
package/temp survives and existing format-1/format-2 round trips and manifest
hashes retain their semantics.

### Share-extension full-suite timing stabilization

The first two normal parallel full-suite runs exposed a pre-existing timing
failure in `cancelDuringProcessingSuppressesLatePublication`: under heavy
machine load the global callback did not begin within its two-second bounded
semaphore wait, causing the start assertion and subsequent cancellation-state
assertion to fail together. The suite is now serialized, retains all three
explicit happens-before assertions, and uses a ten-second bounded wait. The
whole Share suite then passed three consecutive runs and the normal parallel
full suite passed on the final tree.

### Fresh verification

- `KnitNoteBackupServiceTests`: 62 tests passed.
- `JSONProjectStoreTests`: 71 tests passed.
- `ShareExtensionFlowContractTests`: 6 tests passed in each of 3 consecutive
  runs.
- `swift test --no-parallel`: 793 tests in 67 suites passed.
- final normal parallel `swift test`: 793 tests in 67 suites passed.
- fresh iOS App, macOS App, iOS Share Extension, and watchOS App builds, each
  with independent DerivedData and `CODE_SIGNING_ALLOWED=NO`: exit 0.
- localization JSON, Xcode project, all configured Info plists and entitlements,
  Swift parsing for every touched source, bounded-export source scan, and
  `git diff --check`: passed.

## Review Fix Round 2

### P1: rollback crash-window closure

Root cause: rollback still advertised `installedAwaitingReload` while it
deleted the installed live tree and moved the rollback tree back. A process
termination after live deletion or after rollback-to-live movement therefore
left launch recovery without a durable way to distinguish an interrupted
rollback from a pending installation.

Rollback now persists and synchronizes a `rollingBack` journal before its
first destructive operation. Journal writes use atomic replacement followed
by `fsync` of both the journal descriptor and work-root directory; journal
removal also synchronizes the directory. Recovery completes the phase
idempotently for both transactions that had an original live root and those
that did not:

- rollback present plus live present removes the installed live tree and moves
  the original back;
- rollback present plus live absent moves the original back;
- rollback absent plus live present validates the restored live tree as the
  completed move recorded by the integrity-bound `rollingBack` journal;
- transactions without an original remove any remaining installed live tree.

Only after the rollback filesystem outcome is complete does the service write
`rolledBack` and remove the journal. Injection regressions terminate after the
`rollingBack` journal, live deletion, rollback move, and final journal for both
`hadLiveRoot` values. Restart recovery restores the original archive bytes
exactly (or restores the prior absence), removes rollback/journal artifacts,
and is a no-op on the second recovery. A corrupt journal fails closed without
changing either live or rollback bytes.

### P1: bounded descriptor markup discovery

Root cause: markup discovery validated directory paths and then returned to
`FileManager.contentsOfDirectory`. That reopened the path after validation,
allowed directory rename/swap races, and allocated an unbounded entry array
before enforcing the per-owner markup cap.

Legacy pattern markup and usage markup now share one root-anchored descriptor
walker. It:

- opens the live root and each directory component with
  `openat`, `O_DIRECTORY`, `O_NOFOLLOW`, and `O_CLOEXEC`;
- obtains every component and entry with
  `fstatat(..., AT_SYMLINK_NOFOLLOW)`;
- enumerates through `fdopendir`/`readdir` and checks the 512-entry limit
  before appending a name;
- accepts only regular canonical page-number `.json` files;
- sorts only the bounded set for deterministic manifests;
- compares owner directory device, inode, mtime, and ctime before/after
  enumeration, then rechecks that its parent name still binds to the same
  directory.

Real filesystem regressions cover limit-plus-one for both owner layouts with
no partial package, rename/swap during enumeration, symlink and unsupported
entries, and deterministic valid manifests.

### Fresh verification

- `KnitNoteBackupServiceTests`: 69 tests passed.
- final normal parallel `swift test`: 800 tests in 67 suites passed
  (63.835 seconds).
- `swift test --no-parallel`: 800 tests in 67 suites passed
  (78.272 seconds).
- fresh iOS App, macOS App, iOS Share Extension, and watchOS App builds, each
  with independent DerivedData and `CODE_SIGNING_ALLOWED=NO`: exit 0.
- localization JSON, Xcode project, all configured Info plists and
  entitlements, touched production/test Swift parsing, descriptor-discovery
  source scan, and `git diff --check`: passed.

## Review Fix Round 3

### P1: durable rollback filesystem mutations

Root cause: the `rollingBack` and `rolledBack` journals were durable, but the
filesystem mutations they described were not. Removing the installed live tree
did not synchronize the live-root parent, and moving rollback to live did not
synchronize both the source and destination parents before advancing to
`rolledBack`. A successful `FileManager` call therefore did not prove the
directory entries would survive termination.

Rollback now uses an injectable directory synchronizer backed by
`open(O_DIRECTORY | O_NOFOLLOW)` and `fsync`. It synchronizes:

- the live-root parent after removing installed live data;
- the rollback source parent and live destination parent after
  rollback-to-live rename;
- a shared parent exactly once when both entries reside in the same directory.

All mutation-parent synchronization completes before the service persists
`rolledBack`. A failure leaves the integrity-valid `rollingBack` journal in
place; restart recovery repeats the required synchronization and completes
idempotently.

### P1: evidence-preserving rolledBack recovery

Root cause: launch recovery treated `rolledBack` as cleanup-only and deleted
the journal without validating the filesystem outcome. An inconsistent valid
replacement live tree could then win general recovery while the original
rollback was discarded.

`rolledBack` recovery now applies the same filesystem completion routine as
`rollingBack` before removing the journal. For transactions with an original
live root, it prefers and validates the transaction's exact rollback directory
or deterministic cleanup tombstone, removes inconsistent live data, restores
the original, synchronizes both mutation parents, and validates the result. If
neither rollback evidence exists, it requires a valid live tree and
synchronizes the inferred rename parents before clearing the journal. For
transactions without an original live root, it removes inconsistent live data
and synchronizes the live parent. Missing or contradictory evidence fails
closed and retains the journal.

Injection regressions prove:

- live-parent synchronization follows live removal;
- source and destination parent synchronization follows rename and precedes
  the `rolledBack` journal;
- direct rollback and interrupted-rollback synchronization failures retain
  `rollingBack` evidence and complete on a fresh restart;
- an integrity-valid `rolledBack` transaction with replacement live plus an
  available original restores the original byte-for-byte;
- an integrity-valid no-original transaction removes inconsistent live data.

### Fresh verification

- `KnitNoteBackupServiceTests`: 75 tests passed.
- final normal parallel `swift test`: 806 tests in 67 suites passed
  (41.327 seconds).
- fresh iOS App, macOS App, iOS Share Extension, and watchOS App builds, each
  with independent DerivedData and `CODE_SIGNING_ALLOWED=NO`: exit 0.
- localization JSON, Xcode project, all configured Info plists and
  entitlements, touched production/test Swift parsing, and
  `git diff --check`: passed.
