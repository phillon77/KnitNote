# Plan 2 final integration fix report

Base: `89599b06c9e64afbd7869ab97e8f7388d9662fa0` on `docs/cross-device-sync-design`.
Checkout: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
Version remains 1.7.0 (13). Candidate is the commit containing this report.

## Status and decisions

One integrated fix wave addresses all five findings plus the schemaVersion CFBoolean minor. Final affected suites and unsigned generic iOS/macOS builds PASS. No app UI, lifecycle, domain migration, Core or Watch production source was changed.

1. Failure events carry the actual transport attempt ID and account epoch. Coordinator deduplication is per attempt, grouped under the stable mutation identity and retired on acknowledgement. Two real transport conflicts for one stable mutation both rebase the complete FIFO, then head and successor acknowledge.
2. Conflict committers receive `CloudSyncAccountEpoch`; their final synchronous durable CAS must execute through `withCurrent`, including after suspension. Coordinator checks before and after the commit and discards stale work. The composed suspended-commit regression invalidates the actual transport epoch before resuming the committer and proves the journal remains unchanged.
3. Production and injected-engine initializers accept the existing concrete, account-scoped `CloudAssetStagingService` as their adapter. Its account identifier is immutable. Start rejects a mismatched account; a transport cannot reuse old-account staging after an account change. Attachments require that adapter and immutable source; default production materialization fails closed instead of transmitting metadata alone. Every attempt stages/verifies the immutable source and creates a fresh CKAsset at the stable mutation/version URL. Custom materializers cannot bypass the staging step.
4. Incoming CKAsset bytes are verified and installed before incoming spool creation, event delivery or receipt/state advancement. Restart validates that each spooled attachment still resolves to verified installed bytes. `installedDownload(version:)` is a deterministic, account-bound, hash/size/binding-verified locator for Plan 3. The version in the incoming record remains the only metadata authority.
5. `limitExceeded` has a dedicated failure. Both identified record failures and whole-request errors reduce the batch size, preserve mutation IDs and staged bytes, and retry within a bounded 250-to-1 progression. A materialized single-record rejection is terminal and excluded from subsequent automatic batches. Offline request regression observes `[4, 2, 2]` and then one terminal single-record request.
6. Schema decoding rejects CFBoolean masquerading as integer schema version 1.

## Exact acknowledgement and cleanup

Remote success first passes transport attempt correlation and system-field durability, then yields the stable identity. The coordinator acknowledges the exact journal head before calling `acknowledgeSentMutation`. Only that confirmed identity can remove the matching upload reference. Cleanup failure has its own coordinator issue and retries on the next send/sync without re-sending the acknowledged mutation. A regression injects failure after the acknowledgement manifest commit, stages another mutation, and proves retry cleans the old file while preserving the new one.

There is deliberately **no absence-based pruning against a journal replay snapshot**. Such a snapshot is not atomic with other writers and cannot prove that an unlisted staging reference is acknowledged. The controller explicitly approved conservative retention. If the process exits after durable journal acknowledgement but before the cleanup callback, the still-referenced staged file may be retained. Plan 3 must provide a durable exact-ack proof/atomic journal-asset reconciliation before reclaiming that window. Existing staging recovery still removes files whose acknowledgement manifest has already durably dropped the exact reference. Restart/account-switch tests prove unrelated references survive.

## Development harness

- Offline: deterministic engine driver, real codec, transport, file mutation journal, coordinator, durable incoming committer, incoming spool and staging. It verifies immutable retry CKAsset identity/URL, exact journal ack and cleanup, verified incoming install, durable record readback, journal restart and installed-file restart lookup.
- Live: the opt-in test now constructs **real CKSyncEngine** with production `LiveCKSyncEngineDriver`, using actual delegate events rather than manually injecting sent/fetched callbacks. Automatic sync is disabled only in this harness to bound explicit requests and cleanup. It performs actual transport send/fetch, coordinator/file-journal acknowledgement, installed attachment verification, engine-state readback and a second real engine/coordinator restart. Driver operations are cancelled before exact unique-zone cleanup, including the error path.
- Default-off opt-in, explicit Development marker, signed Development entitlement and signed container membership are retained before CKContainer access. The body rechecks the full gate. Production is refused. Only the unique test zone is cleaned up.
- Live CloudKit: **NOT RUN**. The real-engine path is compiled but not experimentally validated here. No provisioning, schema deployment, push, archive, upload or submission occurred.

## RED/GREEN evidence

All logs are local `/tmp/plan2-integration-*.log` artifacts. Initial sandboxed Xcode execution could not contact testmanagerd; unsigned offline tests were subsequently run with sandbox escalation. The first method-only Swift Testing filter selected zero tests and is not counted as evidence; whole-suite selection corrected that.

| RED log | Observed failure before remedy |
| --- | --- |
| `red4.log` | Repeated stable-mutation conflict, suspended account-invalidated conflict CAS, metadata-only attachment send/fetch, per-record limit splitting, CFBoolean schema version |
| `red-request2.log` | Whole-request limitExceeded aborted instead of completing reduced requests; composed offline harness already passed |
| `red-cleanup.log` | Journal acknowledged but next sync did not retry failed exact cleanup |
| `red-restart.log` | Missing installed bytes did not block incoming replay; cleanup test synchronization was subsequently strengthened to await the filesystem outcome |
| `red-exact-ack.log` | Snapshot-based restart reconciliation deleted a reference without exact acknowledgement proof |

GREEN iterations: `green1.log` (coordinator/codec/transport), `green2.log` (all affected suites including staging and offline harness), `final-app.log` (real-engine harness compiled, cleanup retry and missing-file restart passed). Final exact candidate validation is below.

## Final validation

- Affected app suites: PASS, **166 distinct tests / 180 parameterized executions passed, 0 failed, 1 live Development test skipped**. Final log: `/tmp/plan2-integration-final-app3.log`. Result bundle: `/tmp/KnitNotePlan2Integration/Logs/Test/Test-KnitNote-2026.09.05_06-37-09-+0800.xcresult`. `xcresulttool get test-results summary` confirms 167 distinct tests total, 166 passed and 1 skipped; device execution count is 180 passed and 1 skipped.
- The preceding final run (`final-app2.log`) exposed a fixed-yield synchronization assumption in the fake repeated-conflict test. It now awaits explicit resolution completion and journal acknowledgement. The real composed transport conflict test was already passing. Production did not change for this test-only correction.
- Core: PASS, **26 tests in 3 suites**, `/tmp/plan2-integration-core.log`.
- Generic unsigned iOS build: PASS, exit 0, `/tmp/plan2-integration-final-ios.log`.
- Generic unsigned macOS build: PASS, exit 0, `/tmp/plan2-integration-final-mac.log`.
- Shell syntax, six plist/entitlement lint checks, diff whitespace and Core/Watch CloudKit-isolation static checks: PASS. The isolation search returned no matches.
- Final build/test output contains the existing multiple matching macOS destination warning; no build errors. No signing or release settings changed.

Affected app suite command:

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' -derivedDataPath /tmp/KnitNotePlan2Integration \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests/CloudSyncEngineTransportTests \
  -only-testing:KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests \
  -only-testing:KnitNoteAppTests/CloudRecordCodecTests \
  -only-testing:KnitNoteAppTests/CloudKitDevelopmentIntegrationTests \
  -only-testing:KnitNoteAppTests/CloudAssetStagingServiceTests \
  -only-testing:KnitNoteAppTests/CloudAssetUploadStagingTests \
  -only-testing:KnitNoteAppTests/CloudAssetDownloadStagingTests \
  -only-testing:KnitNoteAppTests/CloudAssetManifestStoreTests \
  -only-testing:KnitNoteAppTests/CloudAssetFileStoreTests
```

Other checks:

```sh
swift test --disable-sandbox --scratch-path /tmp/KnitNotePlan2Integration-Core \
  --filter 'SyncAttachmentVersionTests|SyncMutationJournalTests|SyncRecordValidationTests'
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNotePlan2Integration-iOS CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNotePlan2Integration-mac CODE_SIGNING_ALLOWED=NO
bash -n AppStore/Verification/release_audit.sh AppStore/Verification/create_release_candidate.sh \
  AppStore/Screenshots/capture.sh AppStore/Screenshots/python_runtime.sh
plutil -lint KnitNote/Info.plist KnitNote/KnitNote-iOS.entitlements KnitNote/KnitNote-macOS.entitlements \
  KnitNoteWatch/Info.plist KnitNoteShare/Info.plist KnitNoteShare/KnitNoteShare.entitlements
git diff --check
rg -n 'import CloudKit|CKAsset|CKSyncEngine' Sources/KnitNoteCore KnitNoteWatch
```

No slow full release audit rerun: audit code was untouched. Generic builds are unsigned build checks, not physical-device acceptance or release proof.

## Changed files and remaining boundaries

- Production: `CloudAssetStagingService.swift`, `CloudRecordCodec.swift`, `CloudSyncEngineTransport.swift`, `KnitNoteCloudSyncCoordinator.swift` under `KnitNote/CloudSync`.
- Tests: matching coordinator, transport, codec and Development integration suites under `Tests/KnitNoteAppTests`.
- This report.

Plan 3 still owns actual domain commit implementation (including epoch-guarded CAS), lifecycle integration, attachment consumption and atomic exact-ack recovery for the conservative retention window. No claim of full app cross-device sync, live CloudKit success or release readiness is made.
