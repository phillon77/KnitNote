# Backup Session Drain Verification

## Candidate identity and scope

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`
- Branch: `docs/cross-device-sync-design`
- Task 2 base/current HEAD: `8abc55889bb1958dcf183d64a9f5955618be9e6c`; Task 2 changes are intentionally unstaged and uncommitted pending independent review.
- Version: **1.7.0 (13)**.
- Current file blob IDs before review: tracker `85bbd4e4430332b789ae89655c9a0c926ec09f47`; store `c2083730e887761518ceae2ab6569d76b43c5165`; tests `cbb7b97d735769031e996a65a289b3c0f1934647`; PBX `d447febe20840068521375df32234cb5d9963b78`.
- Frozen source SHA, Sources tree, Tests tree, PBX identity, reviewer outcome, and final-candidate validation fields are **pending controller review/commit**.
- Scope is only per-store backup admission closure, accepted-work lifetime tracking, late-result rejection, and owned-artifact cleanup protection. The wait is not a health, cleanup, freeze, inventory, or account-opening receipt.

## TDD and focused evidence

- Environment-only first attempt: exit 1 before manifest compilation due denied user clang module-cache access; `/tmp/backup-session-drain-task2-red-api.log`, SHA256 `ac1790a89af42403e6717b09652f931d8b1686207206e30a0f2a6dd5a884f839`.
- Intended API RED: exit 1 on missing public store wait; `/tmp/backup-session-drain-task2-red-api-escalated.log`, SHA256 `a65417404926654aa4b9f3ed1ccae1ee2c5173810c1639dd9223583f0a5ad9be`.
- Behavioral RED after wait-only wiring: exit 1, 6 tests / 1 suite, 22 issues; `/tmp/backup-session-drain-task2-red-behavior.log`, SHA256 `aba6db2fb5b2136cb659b106e1a2fecb2a51e4a79cf59a7d8f361045e78d9028`.
- Final focused covering GREEN: exit 0, 24 tests / 3 suites in 11.952 seconds; `/tmp/backup-session-drain-task2-green-final-focused.log`, SHA256 `c7c2b56960a78a913ad258297dd5b5ce56108c56946a1f9dea05b3474da04e11`.
- Mutation REDs all failed as intended for missing prepare entry/registration, missing prepare result admission, and early restore token completion. Exact evidence and restored GREEN are recorded in `.superpowers/sdd/2026-09-06-backup-session-drain/task-2-report.md`.
- Final restored session suite: exit 0, 6 test functions / 1 suite (13 parameterized cases); `/tmp/backup-session-drain-task2-green-restored.log`, SHA256 `fa31536a796b6a24f27fae7f83be034668edc26a8485f515970f60be92e97051`.

## Affected regression and static checks

- Original default-concurrent affected command: `swift test --filter 'JSONProjectStore|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch'`; **exit 0, 829 tests / 50 suites passed** in 167.401 seconds, 168.720 seconds total. Log `/tmp/backup-session-drain-task2-affected-concurrent.log`; SHA256 `ddb64ae52897ce6f4a17302b6af963267b2c49721975dfa27ff3988523e5c616`.
- `git diff --check`: exit 0. Log `/tmp/backup-session-drain-task2-diff-check.log`; SHA256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- `plutil -lint KnitNote.xcodeproj/project.pbxproj`: exit 0, `OK`. Log `/tmp/backup-session-drain-task2-pbx-lint.log`; SHA256 `87ad3b9c34abbc299eb43b9adeff05e01c116925d4f2ab993b0a8a847f09953c`.
- Final focused and affected GREEN logs contain no warning, error, issue, or timeout lines. No bounded run timed out.

## Failure evidence and safety limits

- Reload failure preserves the original archive and reports `installFailedOriginalPreserved` after native rollback/reload.
- Rollback failure reports `rollbackFailed` and retains one rollback root.
- Partial commit cleanup failure retains one cleanup root while preserving the native successful restore result.
- Evidence-byte snapshots are unchanged across the backup-specific wait. Enumeration creation/traversal errors throw and cannot become empty evidence.
- A second independent store's complete fixture-root bytes remain unchanged until its explicit post-check edit.
- Termination does not establish durable health or authorize recovery, cleanup, inventory capture, account switch, or new account opening.

## Pending frozen-candidate validation

- Independent Task 1 and Task 2 precommit reviews: approved with no Critical/Important findings. Task 1's direct simultaneous-uncancelled-waiter coverage and Task 2's deterministic post-cancellation handshake coverage are non-blocking minors for final integration review triage.
- Task 2 source commit: pending; expected controller message `feat(backup): drain accepted work after session revocation` after findings are resolved.
- `swift test --no-parallel`: not run by Task 2 implementer; pending controller-owned final validation.
- Unsigned macOS build-for-testing: not run by Task 2 implementer; pending controller-owned final validation.
- Unsigned generic iOS build: not run by Task 2 implementer; pending controller-owned final validation.
- Final immutable source/tree identity readback: pending controller commit and validation.
- App/test-host execution, live service activation, physical-device acceptance, signing, installation, merge, push, upload, and submission: not run and not authorized.

## Final review test-hardening fix wave

- Base/HEAD for this fix wave: `ef29ca2d4b4baa04f7f8ae72539c4ee2b0c3c43d`, clean before edits. The final review approved the implementation with no Critical/Important findings and identified two optional Minor test-hardening gaps.
- Final changes are tests only: `BackupSessionWorkTrackerTests.swift` now confirms two uncancelled waiters have both reached their same-MainActor wait suspension before the final work token is finished, and the cancellation test confirms its peer has also reached that suspension before cancelling the first waiter.
- `JSONProjectStoreTests.swift` replaces the immediate post-`operation.cancel()` boolean assertion with a cancellation-handler event and a deterministic existing-behavior probe: before revocation and while the native service blocker remains closed, public cleanup must still preserve the known package because tracker ownership remains active. No production seam, delay, `Task.yield`, timeout assertion, or behavior change was added.
- Baseline focused GREEN after the test edits: `swift test --filter 'BackupSessionWorkTrackerTests|lateBackupArtifactsStayOwnedAndAreNotReturned'`; exit 0, 6 tests / 2 suites in 0.053 seconds, 20.793 seconds total. Log `/tmp/backup-session-drain-final-fix-baseline-green.log`; SHA256 `db711d842ab0bab4de91371cdb029f135dbc392337dd3378c59af0341e632b54`.
- Multi-waiter broadcast mutation RED: the tracker temporarily yielded completion to only one pending waiter and finished the other stream without a value. `swift test --filter twoRegisteredUncancelledWaitersBothReceiveFinalCompletion` exited 1, 1 test / 1 suite, 1 `CancellationError` issue in 0.001 seconds, 5.840 seconds total. Log `/tmp/backup-session-drain-final-fix-mutation-broadcast-red.log`; SHA256 `6b7e282eb21f32f5843c6d4402bcdbc4bd99a0453700454655cccdae5abcc4de`.
- Cancelled-waiter peer mutation RED: cancellation cleanup temporarily finished all remaining peer streams. `swift test --filter cancelledWaiterDoesNotDrainWorkOrCancelPeer` exited 1, 1 test / 1 suite, 1 `CancellationError` issue in 0.001 seconds, 5.773 seconds total. Log `/tmp/backup-session-drain-final-fix-mutation-cancel-peer-red.log`; SHA256 `6ae8eb0631a3ebe4a198ae220e4fa7ca2d6c99eb2d30d8bcf2f4f70471e9b7b5`.
- Caller-cancellation early-finish mutation RED: export and prepare temporarily finished their tracker token synchronously from a cancellation handler. With each native service blocker still closed, `swift test --filter lateBackupArtifactsStayOwnedAndAreNotReturned` exited 1, both parameter cases failed, 6 issues in 0.048 seconds, 10.738 seconds total. The event-confirmed cleanup probe deleted each known package and the drain returned early. Log `/tmp/backup-session-drain-final-fix-mutation-caller-cancel-red.log`; SHA256 `4a0af6490fc4179b913aee5a3f0b453e1e6d1fa57788d2a50e1af515ba30a830`.
- All production mutations were restored exactly. `git diff` for `BackupSessionWorkTracker.swift` and `JSONProjectStore.swift` is empty against `ef29ca2`.
- Final focused covering GREEN: `swift test --filter 'BackupSessionWorkTrackerTests|StoreBackupSessionDrainTests'`; exit 0, 11 tests / 2 suites in 0.355 seconds, 10.454 seconds total. Log `/tmp/backup-session-drain-final-fix-covering-green.log`; SHA256 `b6979637c032d749f40afd5eb80d178322ddc628c7e27abd5b97893be62f9109`.
- Final test blob identities before scoped rereview: `BackupSessionWorkTrackerTests.swift` `99407221ded452eee4dc5bb8f2bcbc27bd4995dd`; `JSONProjectStoreTests.swift` `b846a3977917ed3a5636e5a045b727fd0c4bc39c`.
- The final focused log has zero warning/error/issue/timeout lines. No bounded run timed out. No affected/full Core or platform build was repeated in this fix wave.
- Pending: controller scoped rereview, test/report commit, source freeze identity readback, then controller-owned full Core and unsigned platform validation. No release action occurred.
