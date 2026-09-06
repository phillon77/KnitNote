# Session Write Admission Verification

## Source identity and scope

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`
- Branch: `docs/cross-device-sync-design`
- Baseline HEAD: `0195aed115353f91e8c51234a902e4050e43d717`
- Candidate state: reviewed implementation commit `d8ad41e77aaae02de2e8a68e51a52433f1d5df29` plus a review-ready unstaged final-fix diff; a frozen successor candidate SHA does not exist yet.
- Implemented only the synchronous, per-`JSONProjectStore` write-admission prerequisite. Revocation is monotonic for the store instance, is not persisted, and is not an account/session identity proof.
- Added no App wiring, live service, signing, push, cleanup, migration, account-switch, or production activation behavior.

## RED and restored GREEN evidence

- Controller baseline before edits: `swift test --filter persistsProjectsAcrossStoreInstances`; exit 0, 1 Swift Testing test passed. The controller reported a 79.04-second build and the existing `HighlightOverlayContractTests` deprecated-API warning.
- The first local `swift test --filter JSONProjectStoreSessionAdmissionTests` attempt exited 1 before compiling the package because the outer sandbox denied the user clang module cache (`/tmp/session-admission-red.log`). A scoped `/tmp` module-cache attempt was also blocked by nested `sandbox-exec`; neither is counted as intended RED.
- Intended RED: `swift test --filter JSONProjectStoreSessionAdmissionTests`; exit 1 because `StoreSessionAccessError`, `revokeSessionWrites`, and `isSessionWriteRevoked` did not exist (`/tmp/session-admission-red-intended.log`).
- First GREEN: the same focused command; exit 0, 4 tests in 1 suite passed (`/tmp/session-admission-green-1.log`). Its full recompilation repeated 42 instances of the same pre-existing `HighlightOverlayContractTests.swift:92` deprecated `String(contentsOf:)` diagnostic; no admission diagnostic was present.
- Purchase-boundary mutation check: with only the `preflightAccess` and `ensureSyncPublicationReady` admission statements temporarily removed, `swift test --filter revocationDoesNotConsumePurchaseAuthorization` exited 1 because `calls` was 1 instead of 0 (`/tmp/session-admission-mutation-red.log`). The exact statements were restored, and the four-test suite exited 0 (`/tmp/session-admission-green-restored.log`).
- Publication-boundary mutation RED: with only the inner `commitRemoteBatch`, inner `commitConflictRebase`, and first post-ACK admission statements temporarily removed, `swift test --filter 'revocationInsideRemoteCommitOwnership|revocationInsideAcknowledgement|revocationInsideConflictCommitOwnership'` exited 1: both commits completed and changed durable state, while the ACK callback ran twice (`/tmp/session-admission-publication-boundaries-red.log`).
- Second-ACK mutation RED: the ACK test was parameterized to revoke on callback 1 or 2. With only the second post-ACK admission statement temporarily removed, `swift test --filter revocationInsideAcknowledgementStopsBeforeReceiptRetirement` exited 1; the callback-2 case retired the receipt instead of throwing and changed the checkpoint (`/tmp/session-admission-second-ack-red.log`).
- Restored focused GREEN: `swift test --filter 'JSONProjectStoreSessionAdmissionTests|revocationInsideRemoteCommitOwnership|revocationInsideAcknowledgement|revocationInsideConflictCommitOwnership'`; exit 0, 7 tests in 3 suites passed, including both ACK callback cases (`/tmp/session-admission-all-focused-final.log`).

## Affected regression command, counts and exit code

- Required concurrent command: `swift test --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'`; 808 tests in 47 suites, exit 1, one issue (`/tmp/session-admission-affected-regressions.log`). `JSONProjectStoreTests.swift:1965` observed `await Task.detached { blocker.waitUntilBlocked() }.value == false` in the existing `exportSerializesProjectYarnAndJournalMutations` test. The log also shows many unrelated tests completing near 119 seconds, but there is no timing instrumentation or baseline concurrent reproduction proving why the blocker wait timed out.
- Controlled focused reproduction: `swift test --filter exportSerializesProjectYarnAndJournalMutations`; 1 test in 1 suite passed in 0.038 seconds, exit 0 (`/tmp/session-admission-regression-rerun-export.log`).
- Controlled serialized diagnostic: `swift test --no-parallel --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'`; 808 tests in 47 suites passed in 209.502 seconds, exit 0 (`/tmp/session-admission-affected-regressions-serialized.log`).
- The original concurrent command remains a real exit-1 result and is not relabelled as passed. Isolated and serialized passes suggest concurrent scheduling sensitivity, but the root cause remains unproven; no unrelated timeout or test code was changed.
- `git diff --check`; exit 0, no output. `plutil -lint KnitNote.xcodeproj/project.pbxproj`; exit 0.

## Review findings and resolutions

- Verified the admission statement is first in every named throwing boundary and outside error translation, with a side-effect-free guard first in `retryLoad()`.
- Verified both caller-supplied ownership closures recheck before obtaining authority, and both transport-ACK callback returns recheck before subsequent receipt work.
- The four planned entry tests did not protect the inside-ownership or post-ACK checks. Added three focused real-fixture tests that preserve archive, checkpoint, journal authority, and publication-intent state. The ACK test has separate callback-1 and callback-2 cases; mutation REDs prove both post-callback checks and both ownership checks are observable.
- `KnitNote.xcodeproj` uses explicit file references. The first unsigned macOS build-for-testing exited 65 with `cannot find 'StoreSessionAccessError' in scope` (`/tmp/session-admission-macos-pre-review.log`). Added the smallest `PBXFileReference` plus the same two Sources memberships as `JSONProjectStore.swift`.
- After that membership correction, `xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/session-admission-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing` exited 0 with `** TEST BUILD SUCCEEDED **` (`/tmp/session-admission-macos-pre-review-restored.log`). It emitted 3 existing AppIntents metadata-skip warnings. The DerivedData path is retained for controller reuse.
- Independent implementation/spec and code-quality review found two Important issues: missing post-purchase-callback checks and loss of the revoked error in `persist`. Fix round 1 added the checks and explicit error preservation; scoped re-review confirmed both addressed, without new Critical/Important breakage. Final integration review then found the purge callback boundary and two test-only retain cycles addressed in the final correction section below. Final rereview and frozen successor validation remain pending.

## Review round 1 correction evidence

- Both purchase-policy callbacks now have an immediate post-return admission check before their `.allow` / `.requiresUnlock` decisions are interpreted. Existing before-callback checks, purchase policy, and transaction behavior remain unchanged.
- `persist` now preserves `StoreSessionAccessError` explicitly before its generic `ProjectStoreError.persistenceFailed` translation.
- Added parameterized callback regressions for `.allow` and `.requiresUnlock`. The authorization case uses public `addYouTubePattern` title validation; the successful-purchase case uses public `addYarn` label-count validation. Both revoke inside the callback and require `.revoked` with unchanged store/file state.
- No existing synchronous public callback is reachable between `persist` preflight and the first statement of `commitArchiveAndPublish`. The error-preservation regression uses the existing `archiveWrite` injection inside the publication routine, without a production test hook. This is evidence for `persist` error identity, not a claim of a new post-revocation central-entry path.
- Environmental attempt: `swift test --filter JSONProjectStoreSessionAdmissionTests`; exit 1 before package compilation when the sandbox denied the compiler module cache (`/tmp/session-admission-review1-red.log`).
- Behavioral RED: the same command outside the sandbox; exit 1, 7 test functions / 1 suite, 4 issues (`/tmp/session-admission-review1-red-behavior.log`): authorization `.requiresUnlock` produced `.accessRestricted`; successful-purchase `.allow` produced `.invalidOrdinal`; successful-purchase `.requiresUnlock` produced `.accessRestricted`; the archive-writer seam produced `.persistenceFailed`. Authorization `.allow` already reached a later admission check and passed before the fix.
- Corrected GREEN: `swift test --filter JSONProjectStoreSessionAdmissionTests`; exit 0, 7 test functions / 1 suite passed (`/tmp/session-admission-review1-green.log`).
- Purchase-policy regression: `swift test --filter JSONProjectStoreEntitlementTests`; exit 0, 31 tests passed (`/tmp/session-admission-review1-entitlement-regression.log`). The log contains the existing CoreGraphics PDF diagnostic and no compiler warning.
- These review corrections are intentionally unstaged over the exact staged v1 baseline. Rereview and frozen full validation remain pending.

## Final integration review correction evidence

- Added an immediate admission recheck after `purgeRecentlyDeleted` returns from its caller-supplied `references` callback. Revocation now escapes before reference interpretation, archive/canonical inspection, `SyncDeletionLedger.purge`, permanent-marker persistence, or retained-payload unlinking.
- The focused fixture creates a real eligible project-deletion entry with retained files, revokes inside `references`, returns complete acknowledgement evidence, and compares archive bytes, `ledger.json`, each retained payload, and deletion markers.
- Behavioral RED: `swift test --filter revocationInsidePurgeReferencesPreservesRetainedDeletion`; exit 1, 1 test / 1 suite with 4 issues (`/tmp/session-admission-final-fix-purge-red.log`). The call returned without error, changed the manifest and markers, and unlinked a retained file. Its clean compilation repeated the pre-existing deprecated `String(contentsOf:)` warning at `HighlightOverlayContractTests.swift:92`; no new compiler warning appeared.
- Focused GREEN: the same command; exit 0, 1 test / 1 suite passed (`/tmp/session-admission-final-fix-purge-green.log`).
- Covering GREEN: `swift test --filter 'JSONProjectStoreSyncDeletionTests|JSONProjectStoreSessionAdmissionTests'`; exit 0, 44 test functions / 2 suites passed (`/tmp/session-admission-final-fix-covering-green.log`).
- Added simple `defer { store = nil }` cleanup in both callback-admission fixtures to remove the final review's test-only retain cycles.
- Controller-reported affected run on `d8ad41e` (session 48269): exit 1, 814 tests / 47 suites; total 257.036 seconds, test time 173.754 seconds. The same existing `exportSerializesProjectYarnAndJournalMutations` blocker wait returned false at `JSONProjectStoreTests.swift:1965`. This second concurrent failure remains unresolved; its root cause is not proven and it is not a pass.
- Final-fix `git diff --check`: exit 0, no output.
- Final scoped rereview confirmed the purge guard and fixture-cycle corrections addressed, with no new Critical/Important breakage. Successor commit/SHA and controller-owned frozen validation remain pending at this snapshot; no broad affected rerun was performed in this fix wave.

## Remaining asynchronous writers and activation gates

- Detached backup installation is not proven drained by this task.
- Inbox reconciliation/import is not proven drained by this task.
- Journal-photo processing is not proven drained by this task.
- Thumbnail/cache writes are not proven drained by this task.
- External Watch ledger writers are not proven drained by this task.
- Constructor-time recovery is not proven drained by this task.
- No drain receipt, session owner, lifecycle proof, account opening/switching, App activation, or live transport gate was added. A synchronous transaction already started before later MainActor revocation still follows its existing native transaction/rollback outcome.

## Candidate-bound full validation

- Final scoped rereview completed; no open code findings remain from the task or final integration reviews.
- Pending final-fix commit and frozen successor source SHA.
- Pending controller-owned `swift test --no-parallel`, unsigned macOS build-for-testing, and unsigned generic-iOS build on the frozen source candidate.
- The eleven-case Phase 4A matrix has not been run or passed by this task. Focused GREEN and the pre-review unsigned build do not substitute for candidate-bound full validation.
