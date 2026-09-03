# Task 6 — Incremental attachment manifest and phase verification

**Status:** Task 6 implementation and local verification complete. The
independent Phase 1 review remains required; this report does not authorize
CloudKit Phase 2 or release work.

**Base and head before Task 6 commit:** `ddb79f4bd28d21016bb3d064d23b7fb82a3b3409`.

## Recovered RED evidence

- `swift test --filter SyncAttachmentManifestTests` passed from the recovered
  worktree (6 tests). No pre-implementation RED output was retained, so none
  is claimed here.
- `swift test --filter JSONProjectStoreSyncPublicationTests` initially failed
  3 of 41 tests: `usageMarkupPublishesStableAttachmentSaveAndDelete`,
  `usageMarkupSinkFailurePersistsAcrossRestartAndBlocksLaterFileWrites`, and
  `deletingProjectPublishesDeletesForItsUsageMarkupPages`. The projector was
  issuing legacy, unchanged attachments when attachment evidence existed but
  the new manifest did not.

## Decisions and self-review

- Keep legacy slots without both manifest and immutable issuance evidence
  local until their slot is introduced or replaced; do not synthesize a remote
  version while bootstrapping the manifest.
- The 500-file fixture now models its first persist as attachments entering
  the archive, while later persists use the unchanged archive reference set.
- Candidate manifests remain in the durable publication marker and are
  committed only after archive commit and journal publication reconcile.
- Remaining phase gate: fresh complete suite, generic iOS/Watch builds,
  whitespace/status checks, and the separately required independent review.

## GREEN evidence

- `swift test --filter 'SyncAttachmentManifestTests|JSONProjectStoreSyncPublicationTests|SyncMutationJournal|SyncMerge|WatchCommandApplicationTests|WatchSyncPersistenceTests|YarnLink'`
  — 187 tests in 10 suites, exit 0.
- `swift test` — 1,936 tests in 154 suites, exit 0.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`
  — `BUILD SUCCEEDED`.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build`
  — `BUILD SUCCEEDED`.
- `git diff --check` — exit 0.

## Files and final self-review

- Added `SyncAttachmentManifest.swift`, `SyncPublicationProjection.swift`, and
  their 500-real-file operation-count coverage; moved the pure publication
  projection out of `JSONProjectStore`.
- Publication markers now carry a candidate manifest through idempotent
  repair. The manifest is written only after mutation publication; corrupt or
  unsafe sidecars fail closed.
- Restored legacy-slot behavior during manifest bootstrap so an unchanged,
  never-issued attachment does not become a newly published remote version.
- Tightened revision-ledger decoding: revision zero and an issued floor that
  differs from the greatest durable receipt are corruption. Disabled sync no
  longer creates sync metadata while launch recovery is deciding whether a
  missing live root is recoverable.
- Regenerated `KnitNote.xcodeproj` from `project.yml` so every CloudSync source
  is compiled in the app and Watch targets. No implementer Critical/Important
  regression remains after diff review and the commands above; the independent
  review gate is intentionally still pending.

## Review fix round 1/5 — attachment cache, legacy replacement, and ledger duplicates

### RED evidence

- `swift test --filter 'SyncAttachmentManifestTests|JSONProjectStoreSyncPublicationTests.sameStoreStructuralPersistKeepsAttachmentHeadForRestartedReplacement'`
  — exit 1: a same-store structural rename emitted an attachment delete and
  then blocked the later replacement; a legacy reference replacement produced
  no attachment save.
- `swift test --filter 'SyncRevisionLedgerTests.duplicateIssuedEntityFailsClosedWithoutReplacingItsOriginalBytes'`
  — exit 1 with signal 5: `Dictionary(uniqueKeysWithValues:)` trapped on the
  duplicate entity key before the corruption guard could throw.

### Fix and self-review

- The projection cache is structural-only: attachment mutations no longer
  enter its record map, and attachment heads are read solely from durable
  issuance evidence. This prevents a later archive snapshot from treating its
  deliberately absent attachment records as deletes.
- A legacy slot remains local only when its before and after references are
  identical. A changed filename/media descriptor/reference is issued as a new
  immutable attachment with no guessed predecessor; an unchanged legacy
  deletion still emits no guessed ID. Restart coverage retains the issued head
  and its subsequent delete.
- Ledger decoding validates issued entity uniqueness before constructing the
  dictionary, so duplicate persisted keys fail as `SyncRevisionLedgerError.corrupt`
  and leave the original bytes untouched.
- Reviewed the change boundary: no schema changes, no CloudKit transport, and
  no changes to the deferred duplicate-projector or tautology minor findings.

### GREEN evidence

- `swift test --filter 'SyncAttachmentManifestTests|JSONProjectStoreSyncPublicationTests|SyncRevisionLedgerTests'`
  — 57 tests in 3 suites, exit 0.
- `swift test --filter 'SyncAttachmentManifestTests|JSONProjectStoreSyncPublicationTests|SyncRevisionLedgerTests|SyncMutationJournal|SyncMerge|WatchCommandApplicationTests|WatchSyncPersistenceTests|YarnLink'`
  — 197 tests in 11 suites, exit 0.
- `swift test --filter 'SyncRegularFileReaderTests|SyncAttachmentVersionTests'`
  — 10 tests in 2 suites, exit 0.
