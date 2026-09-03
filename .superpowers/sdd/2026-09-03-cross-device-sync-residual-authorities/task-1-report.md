# Task 1 report: missing-target Watch rejection authority

## Implementation

- Added `watchCommandProof` records and `SyncOrphanWatchCommandProof`, which accepts only immutable `.projectMissing` and `.counterMissing` proofs with a command identity and no prepared/effect state.
- Projected missing-target proofs into standalone records keyed by the command UUID; retained an existing orphan record if its counter later reappears, while extant counters continue using their existing aggregate-owned proof state.
- Validated and merged standalone records independently; divergent payloads for one command ID are rejected.
- Included standalone records in durable publication evidence.
- Reworked `publishWatchSyncMetadata` to prepare and publish a metadata-only transaction against the existing archive bytes (`shouldWriteArchive: false`), so proof publication does not rewrite user archive data. The existing transaction flow still writes the marker before enqueueing and removes it only after evidence persistence.

## TDD evidence

Before each new test body, the production break is named in a source comment.

RED command:

```sh
swift test --filter 'JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests'
```

RED result: 92 existing tests passed; two new tests failed as intended:

- `missingProjectWatchRejectionPublishesAStandaloneProof`: no mutation was emitted for the command ID.
- `rejectedWatchMetadataPublicationDoesNotRewriteTheArchive`: archive bytes differed after proof-only publication.

GREEN command:

```sh
swift test --filter 'JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|WatchSyncPersistenceTests|SyncPublicationEvidenceDurabilityTests|WatchCommandApplicationTests|PhoneWatchSyncSourceContractTests'
```

GREEN result: 185 tests passed in six suites.

## Files

- `Sources/KnitNoteCore/CloudSync/SyncIdentity.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRecord.swift`
- `Sources/KnitNoteCore/CloudSync/SyncRecordValidation.swift`
- `Sources/KnitNoteCore/CloudSync/SyncPublicationProjection.swift`
- `Sources/KnitNoteCore/CloudSync/SyncMergeEngine.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Tests/KnitNoteCoreTests/JSONProjectStoreSyncPublicationTests.swift`

## Self-review and concerns

- `git diff --check` passed.
- Full `swift test -q` was started once, but this report was written before its process returned. Its result must be checked before claiming full-suite success or release readiness.
- CloudKit transport, version/build, push, archive, and submission were not changed.

## Fix round 1 (in progress)

- Added sidecar-proof lookup before ledger replay acknowledgement, with exact command identity/rejection validation and local-ledger cache reconstruction.
- Changed orphan projection so the immutable standalone record is retained when the counter reappears.
- Focused validation command was queued behind an existing SwiftPM process and had not returned at handoff; no GREEN claim is made for this amendment.

## Fix round 1 takeover (complete)

This section supersedes the incomplete handoff immediately above.

### Review findings closed

- Every Watch evaluation path now reloads locked durable proof evidence before it can trust the prunable ledger or execute a transition. This includes both in-memory `applyWatchCommand` overloads, durable duplicate acknowledgement, and prepared-command recovery. Exact command identity and the recorded rejection are required; a matching orphan authority returns its original acknowledgement without applying an effect, then repairs the local ledger cache.
- Standalone orphan records survive project/counter reappearance. When the counter exists, the identical proof is also embedded in its aggregate; the standalone authority is not removed.
- Merge performs a global command-ID consistency pass across every orphan and counter-embedded proof. Any differing proof for one command ID fails closed.
- `ProcessedWatchCommandLedger.Entry` now persists the immutable originating processing stamp. Projection and cache repair reuse that stamp/device instead of replacing provenance with a later projector's device.
- Duplicate handling no longer assumes that a ledger write implies proof publication. If evidence is absent it republishes, completes or repairs the marker transaction, reloads the evidence, and verifies the exact proof before acknowledging—including the initial marker-creation gap.
- Missing-target publication now commits in marker -> locked evidence -> journal enqueue -> attachment manifest -> marker removal order. Failure-injection coverage proves evidence-write, journal-enqueue, and marker-removal interruptions remain retryable and do not apply the Watch effect.
- Proof-only publication continues with `shouldWriteArchive: false`; both unsupported-schema and missing-target metadata tests compare the archive's bytes before and after publication.

### RED evidence observed during takeover

The inherited partial fix was first reproduced with:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask1 --filter JSONProjectStoreSyncPublicationTests --xunit-output /tmp/knitnote-task1-jsonproject.xml
```

Result: 49 tests ran; `duplicateRejectedWatchCommandRepairsInterruptedProofPublication` was the only failure, throwing `.corrupt` at `JSONProjectStoreSyncPublicationTests.swift:312`. Root cause: the partial durable lookup treated every rejection proof as an orphan proof, so a valid `.unsupportedSchema` duplicate was rejected by the missing-target wrapper. Restricting orphan lookup to `.projectMissing` / `.counterMissing` made the focused test pass 1/1.

New tests were then run individually or in small filters before their production changes. The observed RED failures were:

- `orphanProofReusesOriginatingProcessingStampAcrossProjectors`: the projected stamp used the command timestamp and current projector device instead of the originating processing stamp.
- `orphanAndEmbeddedProofDivergenceFailsClosedGlobally`: merge accepted two different proofs for the same command ID because validation was record-local.
- `standaloneOrphanProofRemainsWhenItsCounterReappears`: the standalone record disappeared when the counter existed again.
- `nonDurableWatchEvaluationHonorsFreshDeviceOrphanAuthority`: replay incremented the reappeared counter and returned no stored rejection.
- `alreadyLoadedStoreReloadsDurableOrphanAuthorityBeforeEvaluation`: an already-open store used its stale evidence snapshot, incremented the counter, and did not repair the ledger stamp.
- `preparedCommandRecoveryConsultsOrphanAuthorityBeforeEvaluation`: recovery attempted the locally prepared transition and failed `.corrupt` instead of consuming the durable rejection authority.
- `missingProjectAuthoritySurvivesLedgerDeletionRestartAndProjectReappearance` and `missingCounterAuthoritySurvivesPruningRestartAndCounterReappearance`: restart/pruning removed the only replay authority.
- `duplicateMissingTargetRepublishesAfterInitialMarkerCreationFailure`: the durable ledger duplicate returned without ever publishing its proof.
- `missingTargetEvidenceWriteFailureRepairsBeforeAcknowledgement`: the journal saw the mutation even though evidence persistence failed.
- `missingTargetJournalEnqueueFailureRepairsBeforeAcknowledgement`: the caller was acknowledged despite journal enqueue failure.
- `missingTargetMarkerRemovalFailureRepairsOneJournalMutation`: the caller was acknowledged despite marker removal failure.
- `unchangedOrphanAuthorityReusesItsCausallyStampedCacheRecord`: an unchanged authority emitted a new revision-zero mutation.

Each named RED test passed after its corresponding minimal production change. The real ledger deletion/restart, 1,001-entry pruning, target reappearance, fresh-device merge, identity/outcome divergence, archive-byte stability, evidence rename, journal enqueue, and marker removal paths are all covered in the brief-named test files.

### Final GREEN evidence

Final required focused gate, rerun after the last production edit:

```sh
swift test --scratch-path /tmp/KnitNoteResidualTask1 --filter 'WatchCommandApplicationTests|WatchSyncPersistenceTests|JSONProjectStoreSyncPublicationTests|SyncCounterReminderMergeTests|SyncPublicationEvidenceDurabilityTests|PhoneWatchSyncSourceContractTests' --xunit-output /tmp/knitnote-task1-focused-final.xml
```

Result: exit 0; `Test run with 201 tests in 6 suites passed` (0 failures). No full-suite claim is made; the takeover followed the brief's focused-suite constraint.

### Takeover self-review

- Reviewed the complete production and test diff against base Task commit `dc80b4f`, including the proof schema, projection cache reuse, merge validation, every Watch entry point, and the marker/evidence/journal ordering.
- Compatibility remains intentional: legacy non-orphan proofs may decode without `processingStamp`; standalone missing-target proof authorities require it.
- CloudKit transport, release version/build, push, archive, and App Store submission remain outside Task 1.
