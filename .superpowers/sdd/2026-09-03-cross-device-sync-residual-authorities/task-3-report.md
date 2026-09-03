# Task 3 Report: Permanent Immutable Revision Receipt Authority

Date: 2026-09-03

Branch: `docs/cross-device-sync-design`

Starting commit: `af2962efb6c9bbdaca67401125773f97f1b9707c`

## Outcome

`SyncRevisionLedger` now separates a compact version-2 entity-head ledger from permanent immutable receipt files keyed by mutation UUID. Allocation, legacy migration, crash recovery, and publication repair share a bounded durable marker protocol. Historical mutation retries no longer depend on compacted in-envelope receipt history.

This task preserves the existing `SyncRevisionRequest`, `SyncRevisionReceipt`, and `SyncRevisionAllocating` Codable/API contracts, the Task 1 orphan Watch authority, the Task 2 canonical attachment proof behavior, and the existing publication order after receipt recovery.

## Marker layout ruling

The brief specified the receipt layout but not the marker filename. Implementation paused for a ruling rather than guessing. The confirmed layout is:

- heads: original `url`, for example `revision-ledger.json`;
- receipts root: `url.deletingPathExtension().appendingPathExtension("receipts")`;
- receipt: `<receipts-root>/<lowercase UUID first 2 chars>/<lowercase UUID>.json`;
- marker: `url.deletingPathExtension().appendingPathExtension("transaction.json")`;
- one versioned marker with `purpose: allocation | migration`;
- exact sorted `newReceipts` and exact sorted `targetEntityHeads`;
- `sourceLegacyLedgerSHA256` is exactly 32 bytes for migration and `nil` for allocation.

Both purposes replay receipt files, one heads write, then marker removal. V1 bytes remain at the heads URL until the v2 heads atomic rename succeeds.

## Implementation

### Version-2 receipt authority

- The original ledger URL now stores only `{ version: 2, deviceID, issuedRevisions }` with deterministically sorted heads and no receipt array.
- Every receipt is deterministically encoded with sorted JSON keys and installed with an atomic no-clobber `renameatx_np(..., RENAME_EXCL)`.
- An existing receipt must match the canonical encoded bytes exactly. A differing regular file is corruption; symlinks and non-regular paths are unsafe.
- Receipt directories are UUID-prefix sharded. Allocation and retry never enumerate the receipt tree.
- Requested receipts are read directly by mutation UUID. Existing receipts retain their original entity, logical revision, and device ID regardless of a newer observed remote floor.

### Locked allocation and recovery ordering

All operations run under the existing process-local lock plus the durable `fcntl(F_SETLKW)` cross-process exclusive lock.

1. Load and replay an existing bounded marker.
2. Migrate v1 if necessary.
3. Read only receipt files named by the current requests.
4. Reuse byte-identical receipts and allocate unseen mutations from compact heads plus observed floors.
5. Durable-write and directory-sync the sorted marker.
6. Durable-create each immutable receipt, syncing its shard directory. Recovery also re-syncs an already-equal file's directory.
7. Durable-write compact heads exactly once.
8. Remove the marker and sync its parent directory.

Injected crash boundaries cover after marker sync, after each of three receipt installs, after heads sync, and before marker removal. Restart replays the exact receipts and advances the next revision above all three.

Marker validation rejects duplicate mutation IDs, duplicate entity heads, duplicate logical revisions for one entity, wrong device IDs, zero revisions, non-canonical ordering, invalid purpose/digest combinations, and target heads below proposed receipts.

### Legacy v1 migration

Before any new layout write, v1 validates:

- ledger version and device ID;
- positive receipt/head revisions;
- unique mutation IDs;
- unique `(entity, revision)` pairs;
- unique entity heads;
- exact equality between issued heads and per-entity receipt maxima.

Migration then hashes the untouched v1 bytes, writes a migration marker containing all validated receipts and target heads, materializes immutable receipts, atomically replaces v1 with v2 heads, and removes the marker. Re-entry accepts equal receipt files. A changed legacy source digest or divergent receipt fails closed without replacing the current legacy bytes.

### Publication recovery

`JSONProjectStore.publish` restores `transaction.revisionReceipts` into the immutable ledger before attachment-evidence persistence and journal publication. A restart can therefore reconstruct a missing receipt from the still-durable publication marker. Divergent receipt bytes map to `SyncPublicationError.corruptTransaction`, leave the publication marker intact, and publish nothing.

### Durable file extraction

The shared durable-file implementation was moved from `SyncInstallationIdentity.swift` to the brief-specified `SyncDurableFile.swift`. It gained durable regular-file removal, public-to-module directory syncing, no-follow directory validation, and atomic no-clobber rename. XcodeGen added the new file to both KnitNote and KnitNoteWatch; the existing membership contract now covers it.

## Files changed

- `Sources/KnitNoteCore/CloudSync/SyncRevisionLedger.swift`
- `Sources/KnitNoteCore/CloudSync/SyncDurableFile.swift` (new extraction)
- `Sources/KnitNoteCore/CloudSync/SyncInstallationIdentity.swift` (extraction only)
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Tests/KnitNoteCoreTests/SyncRevisionLedgerTests.swift`
- `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`
- `Tests/KnitNoteCoreTests/Task8XcodeProjectMembershipTests.swift`
- `KnitNote.xcodeproj/project.pbxproj` (generated membership only)

## TDD evidence

All SwiftPM commands used `--scratch-path /tmp/KnitNoteResidualTask3`.

### RED

1. Exact brief sequence:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'SyncRevisionLedgerTests|JSONProjectStoreSyncPublicationTests'`

   Unexpected baseline result: 76 tests passed. The v1 implementation compacts before appending B/C, so A accidentally survives one extra batch. The exact approved sequence remains as a regression contract.

2. Permanent retry beyond the one-batch compaction lag:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'SyncRevisionLedgerTests.historicalRetryRemainsPermanentBeyondTheCompactionLag'`

   RED: 1 test failed with 1 issue; A changed from logical revision 1 to 10000.

3. Initial full ledger matrix:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'SyncRevisionLedgerTests'`

   RED diagnostic: process exited with signal 5 because malformed v1 duplicate heads reached `Dictionary(uniqueKeysWithValues:)` before validation. Root cause fixed by duplicate-safe incremental validation.

4. Publication receipt reconstruction:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'JSONProjectStoreSyncPublicationTests.publicationRepairReconstructsMissingImmutableReceiptAuthority'`

   RED: 1 test failed with 1 issue; receipt file remained missing after publication repair.

5. Duplicate entity/revision marker corruption:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'SyncRevisionLedgerTests.transactionMarkerRejectsDuplicateEntityRevisionReceipts'`

   RED: 1 test failed with 2 issues; tampered marker replayed instead of throwing and was removed.

6. Publication divergence mapping:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'JSONProjectStoreSyncPublicationTests.publicationRepairFailsClosedOnDivergentImmutableReceipt'`

   RED: 1 test failed with 1 issue; `.transactionUnavailable` was returned instead of `.corruptTransaction`.

7. Xcode membership:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'Task8XcodeProjectMembershipTests.cloudSyncCoreBelongsToBothAppAndWatchTargets'`

   RED: 1 test failed with 2 issues; the new source was absent from both targets.

8. Real child-process test first run:

   `swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'SyncRevisionLedgerTests.separateProcessesAllocateUniqueDurableReceipts'`

   Test-infrastructure RED: helper compilation failed because the repository root walked up two levels instead of three. After correcting only the fixture path, the same production test passed.

### GREEN

- Permanent historical retry: 1/1 passed.
- Receipt reconstruction: 1/1 passed.
- Duplicate-revision marker rejection: 1/1 passed.
- Publication divergence mapping: 1/1 passed.
- Xcode membership focused test: 1/1 passed.
- Four real child processes allocating into one ledger: 1/1 passed; four unique revisions and restart readback.
- Ledger suite during development: 19/19 passed before the final process test was added.
- Task 3 ledger + publication suites during development: 84/84 passed before the final corruption/process additions.

Final required focused command:

`swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'SyncRevisionLedgerTests|JSONProjectStoreSyncPublicationTests|SyncInstallationIdentityTests|SyncPublicationTransactionTests'`

Result: exit 0; 91 tests passed, 0 failures, across the three matching suites present in this checkout. There is no separately named `SyncPublicationTransactionTests` suite; transaction tests are housed in `JSONProjectStoreSyncPublicationTests`.

Additional generated-project contract:

`swift test --scratch-path /tmp/KnitNoteResidualTask3 --filter 'Task8XcodeProjectMembershipTests'`

Result: exit 0; 3 tests passed, 0 failures.

`git diff --check`

Result: exit 0, no whitespace errors before report creation.

## I/O bounds

- Fresh batch of N requests: N direct receipt-path lookups, no receipt-directory enumeration, one bounded marker write, at most N immutable receipt creates, exactly one compact-head durable write, and one marker removal.
- Measured 1,000-request batch assertions: `headLedgerDurableWriteCount == 1`, `receiptLookupCount <= 1_001`, `receiptDirectoryEnumerationCount == 0`.
- Measured retry after 5,000 durable receipts: one direct receipt lookup (asserted `<= 2`), zero directory enumerations, zero head writes.
- Crash recovery work is O(marker batch), not O(all historical receipts).
- V1 migration is intentionally O(v1 receipt count) once; all later retries are direct-path lookups.
- Safety caps fail closed at 16 MiB for heads and marker envelopes and 64 KiB per receipt.

## Self-review and concerns

- No full `swift test` or platform build was run, as Task 4 owns the full-suite/build gate.
- The brief's exact A/B/C sequence did not reproduce RED because the old compactor retained A for one extra batch. The stronger next-unrelated-batch test demonstrated the actual permanent-idempotence failure and is retained alongside the exact sequence.
- The process test compiles a tiny executable from the real production source, then runs four independent processes. This adds about two seconds to the ledger suite but directly validates the cross-process file lock rather than inferring it from two objects in one process.
- Receipt authority is permanent by design; disk usage grows linearly with unique mutation IDs. This is the accepted tradeoff in the approved specification.
- No CloudKit transport, version/build change, release, push, or submission work was performed.
