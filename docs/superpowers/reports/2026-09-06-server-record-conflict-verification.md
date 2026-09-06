# Server-record conflict durable rebase — blocked verification

Status: **Task 7 INCOMPLETE / BLOCKED pending user direction for an additional fix cycle. Review has NOT passed.** The one permitted final fix wave addressed both original Important findings, but its scoped rereview found a new Important per-file 100,000,000-byte ceiling violation. The controller accepted that finding as load-bearing under ruling 10. No further implementation or full validation is authorized in this report-only finalization.

Current source/test commit is **`165d958796b101aa850745b4cfe0551d0573735b`**, `fix(sync): separate media budgets and fence stale continuations`. Its covering Core **272/272 in 12 suites** and no-host App **155/155 in six suites** pass; that evidence does not close the new finding. **Full Core, macOS build-for-testing and iOS build were NOT RUN and have NOT PASSED. There is no frozen approved candidate or release/activation approval.** This report-only commit preserves the source/test trees below and retains the worktree and scratch.

## Current blocked source/test identity

Workdir: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
Branch: `docs/cross-device-sync-design`.
Execution base: `c1b96789e2e1abddb5b7548f61ae0e203c23b11e`.
Accepted Tasks 1–6 base: `47e9db6647d822ae18c277590b6ee06fdce3e517`. Phase-1 acceptance commit: `9652b28fb6e6283d600c45d8aa4cc60b55d80936`. The subsequent one-wave fix commit is `165d958796b101aa850745b4cfe0551d0573735b`; report-only finalization started with a clean checkout there. Version/build remains **1.7.0 (13)**. Current trees are:

- `Sources`: `43bb192c92b84c764f0e423d3b0f93ce537d9ba9`
- `KnitNote/CloudSync`: `503ae68f6dacb6a79dd16b4a1fcb9350e7d26c6b`
- `Tests`: `5ba5e15f40628ba5a83ebb3c78e0cded54bb6c0e`

These identifiers record the blocked review input, not a final freeze. The current changed-file manifest appears below. The report-only commit identity and report hash are recorded in scratch `task-7-report.md`; source/test equality with `165d958` is required after commit.

## Review chain and open Important finding

Phase-1 scoped review (`task-7-review.md`) approved `47e9db6..9652b28` without findings, explicitly limited to phase 1. It confirmed that the combined App proof observes cleanup invocation plus durable native ACK, **not independently observed cleanup completion**. The whole-plan review (`final-review.md`) then reviewed `c1b96789e2e1abddb5b7548f61ae0e203c23b11e..9652b28` and required two Important fixes: ordinary versioned scheduling/ACK incorrectly charged aggregate media against a 64 MiB journal/recovery budget, and stale coordinator await continuations could enter mutating old-account journal maintenance through diagnostics or ACK cleanup continuation.

The single final fix wave (`final-fix-report.md`, commit `165d958`) separated optional aggregate recovery budgeting from nonmutating journal loading while retaining an independent 64 MiB encoded-metadata budget. It also fences successful and failed conflict/ACK continuations under current epoch ownership, keeps callbacks/awaits outside ownership, and uses a last-observed cached pending count for diagnostics. Actual two-by-40,000,000-byte media, native ACK/reopen, stale resolver/handoff/cleanup and zero-native-IO preservation regressions passed. The fix report's claim that the existing per-file ceiling remained enforced was **not upheld by rereview** and is superseded by the open finding below.

Final scoped rereview (`final-rereview.md`, `9652b28..165d958`) marks both original findings ADDRESSED, but review remains **NOT PASSED** because of one new Important finding; no Critical/Minor or out-of-scope finding was reported:

- `Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift:1449` makes aggregate read budget optional. For ordinary versioned/ACK calls, `validateSource` at **1466–1481** follows the no-aggregate branch into the existing validator.
- That validator's `readVerifiedAttachment` at **2957–2970**, specifically **2969**, passes `maximumBytes: Int(expectedByteCount)` after checking only nonnegative/Int-representable size. It does not clamp or reject against 100,000,000 bytes.
- `Sources/KnitNoteCore/CloudSync/SyncRegularFileReader.swift:148–149` respects the supplied ceiling; **219–221** uses the expected size for materialization. It supplies no independent 100 MB cap. Native valid oversized sources are reachable through ordinary source/attachment construction and native enqueue/staging, as traced by the rereviewer; no forged journal or unsafe path is required.

Before the budget separation, the versioned/ACK path rejected such media under its unintended 64 MiB aggregate limit before reading it. Removing that aggregate limit exposes the missing per-file ceiling in the changed path. Required future correction: reject **each source above 100,000,000 bytes before reading**, while preserving valid aggregate 80 MB scheduling/ACK and explicit recovery-budget refusal. No oversized fixture, new test, source fix or additional review wave was executed during this report-only pass. This finding is not waived by the green 272/155 tests or by retention-performance deferral.

Under ruling 10 and the one-final-wave limit, the controller must obtain explicit user direction for an additional fix cycle. Until then Task 7 remains incomplete/blocked; no freeze, full Core/Xcode run, integration, activation or release action is claimed.

Review-record SHA-256 (scratch paths relative to `.superpowers/sdd/2026-09-06-server-record-conflict-durable-rebase/`): `final-review.md` = `1d093a0ac4b2161f40cb5c0393cb60bd9a175211b03e9e2462e617e23b29699a`; `final-fix-report.md` = `535b5ecdb179e4f5369f97be965ed693b0ac9325ebb3d45a3c903610aa473d76`; `final-rereview.md` = `f463ef233073e6f44a23df2edf07baeabb13ad55d83ecf4da239d7266ce45d19`.

## Historical phase-1 combined acceptance (9652b28)

Core `combinedThreeSavesSixWatchProofsAndMediaRecoverTwice` reuses the actual attachment-history fixture, native journal, publication fault hook, released-handle helper and complete filesystem snapshot. It issues exactly three selected project saves (`Local 1`, `Local 2`, `Local 3`), interleaves two other-project saves and six durable Watch increments, retains two photo versions and a nonempty remote receipt, then resolves server fields to `Server`. Before commit, a manually derived full pending/version list preserves every unrelated global slot and each selected save's entity summary; a full expected checkpoint preserves all other records and receipts. The retained archive is independently compared with the complete predecessor archive after the explicit name change and deterministic ordering. Full attachment evidence and the six exact command IDs are retained before the fault.

The real `.afterJournal` boundary throws and the store reports `pendingRepair`; the test requires one hook hit, exact durable intent, rebased native queue and the predecessor canonical checkpoint. Initial store, journal and checkpoint handles are released with weak witnesses. Two separately constructed sets then recover the same full checkpoint, pending payloads/tokens, native transition/head, archive, six-proof ledger, evidence and files; each set deallocates before the next reopen. Whole path inventory is checked, preexisting unrelated files/media/proof shards keep bytes and inode, and the second recovered tree equals the first byte-for-byte and inode-for-inode. The other counter must retain all six increments.

App `combinedConflictHandoffEditRetryAndExactACKs` uses the real transport callbacks, actual account epoch, JSONProjectStore adapter and native versioned journal. An unrelated project/photo FIFO is present throughout. The existing failing-boundary probes inject one stale preparation and one stale handoff, so the single event uses exactly three Core attempts and two handoffs. The handoff fault hook first proves the exact durable revision-1 queue and canonical remote content, then creates a local edit whose stamp exceeds 1000, captures that immutable native save and performs normal versioned transport scheduling. The actual retry commits and accepts the full queue with selected revisions `[2, 1]`; it does not reset the attempt budget.

The failed old record's actual late success callback returns through the real transport rejection boundary before `.sent` emission. A direct verifier control using the exact captured original token/attempt/production epoch also requires `staleOperation`; this is not evidence that the coordinator consumed a queued old `.sent`. The existing Task 6 `staleSentQueuedBeforeRebasePreservesSameIDNewRevision` covers that separate coordinator boundary with an observable verification attempt. This combined case asserts unchanged exact pending and zero cleanup after the awaited old callback, then uses the correct new callback as positive progress: it waits for actual cleanup invocation after journal CAS, checks the complete resulting FIFO, and requires a native `alreadyAcknowledged` receipt. The original issued token reports `staleVersion`, and the later local save is ACKed separately. Unrelated FIFO, canonical records, evidence, actual photo and native staged media bytes/inodes remain unchanged. Expected queues are retained before the callbacks they check, with no production merge helper or mutated-result-derived replacement oracle. Success still goes through the actual transport verifier; only failure injection is simulated.

## Historical phase-1 commands and evidence (9652b28)

The following 270/151 results, phase-1 file hashes and unchanged-production claims belong to `9652b28`; they are retained as provenance and are not current-source acceptance. Current fix-wave evidence is separately recorded below.

All Swift invocations are serial arm64 processes. Core commands use the workdir above; App commands use `/private/tmp/conflict-rebase-harness`. The harness's Package.swift and all nine symlinks (two source directories and seven test files) were inspected: all resolve to this actual worktree. Six no-host suites execute; the nine live CloudKit declarations are compile/discovery only.

Each Core invocation is exactly the following command with the literal filter/log substitutions in the table:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-swift-cache --config-path /tmp/conflict-rebase-swift-config --security-path /tmp/conflict-rebase-swift-security --filter '<FILTER>' > /tmp/<LOG> 2>&1
```

| Log | Literal filter | Exit and result |
| --- | --- | --- |
| `conflict-rebase-task7-core-first.log` | `combinedThreeSavesSixWatchProofsAndMediaRecoverTwice` | 1; fixture compile failure: missing nested `try` inside Testing macro. Not behavioral RED. |
| `conflict-rebase-task7-core-focused.log` | `combinedThreeSavesSixWatchProofsAndMediaRecoverTwice` | 1; 1 test, 1 oracle issue, 4.888 s. The injected boundary was reached and both recoveries ran, but the test initially expected the internal injected error instead of the documented store `pendingRepair` wrapper. Corrected the expected error, not production. Not product RED. |
| `conflict-rebase-task7-oracle-red.log` | `combinedThreeSavesSixWatchProofsAndMediaRecoverTwice` | 1; 1 test, 4 exact-version oracle issues, 4.812 s. Intentional revision-2 expectation against actual revision 1. |
| `conflict-rebase-task7-core-covering.log` | `SyncConflict\|JSONProjectStoreConflict\|SyncMutationJournal\|JSONProjectStoreCanonicalDurabilityTests\|JSONProjectStoreSyncPublicationTests\|SyncPublicationEvidenceDurabilityTests` | 0; **270/270 tests in 11 suites, 282.502 s**, build 18.29 s; zero warnings/errors/issues. |

The exact-version RED changes only the hand-derived expected selected revision from 1 to 2. It fails source-token equality, the complete post-interruption queue, and both fresh-reopen queues. No product guard is changed and the real fault still fires. Restoration uses `apply_patch`; pre-mutation and post-restoration SHA-256 match exactly:

- `Tests/KnitNoteCoreTests/JSONProjectStoreConflictRecoveryTests.swift`: `e4233235f1139052f90c2c9c04aea07473411870a7f8016e31e9e192bfa578ef`
- `Tests/KnitNoteAppTests/ConflictRebaseIntegrationTests.swift`: `9d3ef2b271a015ab7e62c7095eb99d5b751b04361e955dd902cfff1ceb435e88`

App invocation form:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-harness-cache --config-path /tmp/conflict-rebase-harness-config --security-path /tmp/conflict-rebase-harness-security --filter '<FILTER>' > /tmp/<LOG> 2>&1
```

| Log | Literal filter | Exit and result |
| --- | --- | --- |
| `conflict-rebase-task7-app-first.log` | `combinedConflictHandoffEditRetryAndExactACKs` | 0; 1/1, 1.334 s; no warnings/errors. |
| `conflict-rebase-task7-nohost.log` | `KnitNoteCloudSyncCoordinatorTests\|CloudSyncEngineTransportTests\|CloudAccountTransitionCoordinatorTests\|CloudAssetFileStoreTests\|RemoteBatchCommitterIntegrationTests\|ConflictRebaseIntegrationTests` | 0; **151/151 tests in six suites, 28.719 s**, incremental build 0.13 s; zero warnings/errors/issues. Final combined App case passes in 1.351 s. |

Discovery uses exactly:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --cache-path /tmp/conflict-rebase-harness-cache --config-path /tmp/conflict-rebase-harness-config --security-path /tmp/conflict-rebase-harness-security list > /tmp/conflict-rebase-task7-discovery.log 2>&1
```

Discovery exits **0**, build 5.23 s, with **151 required tests**: coordinator 25, transport 68, account transition 11, asset store 11, remote-batch integration 22, conflict integration 14. The additional **nine live tests are compile/discovery only**. Discovery has no warnings/errors. Empty XCTest compatibility output is never counted as executed Swift Testing acceptance. No Task 7 timeout or interrupted command occurred. Core focused build time was 18.29 s, oracle RED build 16.76 s, initial App focused build 4.51 s; test durations above are Swift Testing durations, not wall-clock totals. The initial compile error has no completed test duration. No warnings occurred in the scaffold/oracle logs either; their explicit errors/issues remain recorded separately.

After the byte-exact oracle restoration, App-only self-review added the original transport authority rejection control. Its final test-file SHA-256 is `30bda0f5a6f14f1cc5fa0c4f505f1b183347afb9356c826e75d28dfbb2e5676c`; the Core file retains the restored hash above. Discovery and the final six-suite run compile this final App file. The Core covering run binds the unchanged final Core file and unchanged production trees.

Phase-1 log SHA-256 values:

| `/tmp/` file | SHA-256 |
| --- | --- |
| `conflict-rebase-task7-core-first.log` | `4869510da60e4c558a1614a6f70acf791a4d26f028a412aad054540920410474` |
| `conflict-rebase-task7-core-focused.log` | `6a1dd6849d6d5ecaaa3ab93a9e1188bbaa9be947a0a078510514b2687666df61` |
| `conflict-rebase-task7-oracle-red.log` | `e209cab81c273521732feec0e0b7ca3894d935050e1af41774568537cf088e6b` |
| `conflict-rebase-task7-core-covering.log` | `a3a18f53b03fa9f727ec8127509cc5e6838ff107573e466bbf79601d51fbfac2` |
| `conflict-rebase-task7-app-first.log` | `18934ef079750a1b8c9dbff4a5f7a60c3307c4557eef059db5620ed41bed29db` |
| `conflict-rebase-task7-discovery.log` | `7a971addc6f95b3f91d5c58c4e2e049a9f9c854b7736e316d278e432ed60f8e4` |
| `conflict-rebase-task7-nohost.log` | `1320fb9adba1898b351ceadb8e2a436488e2be1d565be77116437fa08553a1d2` |

The inspected bounded runner SHA-256 is `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`. It will be rechecked before final validation, not treated as immutable because it resides in `/tmp`.

Phase-1 self-review read the entire two-test diff and checked every brief item. No product defect or out-of-scope helper change was needed. It strengthened the old transport authority control without inventing a sent event, and kept that boundary distinct from existing real coordinator queued-sent coverage. `git diff --check` and `plutil -lint KnitNote.xcodeproj/project.pbxproj` pass. Production/Xcode diffs from the accepted base are empty; source/test hashes did not change after their final covering runs. The phase-1 commit identity and exact final report hash are recorded in the plan scratch `task-7-report.md` to avoid a self-referential report hash. Controller review is still required.

## Controller rulings, chronologically

The source of these decisions is this plan's `.superpowers/sdd/2026-09-06-server-record-conflict-durable-rebase/progress.md`. Its headings interleave the numbered entries; all ten are retained here in decision order, including the superseded first ruling.

1. Checkpoint 5 initially required sorted unique `versionedAcknowledgements: [SyncMutationVersionToken]` alongside history, because compaction would otherwise lose exact kind-5 ACK proof. Validation had to require absent pending and effective issued/history authority; identity-only legacy ACK could not count. Cost if wrong: v5 migration/recovery rework and bounded metadata/latency. **Superseded by ruling 2.**
2. The final field is `[SyncVersionedMutation]`, retaining full acknowledged mutation and exact token. Issued shards retain a record digest, not enough full data to recompute a revision-0 portable token. Receipts validate against issued/effective proof, remain loadable after authorized staged cleanup, and retained paths do not grant new cleanup. All bytes remain under 64 MiB, with no pruning or legacy-format/shard changes. Cost: larger checkpoints, earlier fail-closed capacity exhaustion and v5 validation work.
3. The unexpected exact untracked `Sources/KnitNoteCore/CloudSync/SyncConflictRebase 2.swift` was recoverably moved to this plan's `preserved-scaffold-duplicate.swift.txt`. The author recognized the constant-digest scaffold bytes but not the duplicate-path origin. Compiling both would fail; preservation retained external-change evidence. SHA-256 stayed `b1680cad4368223f1d0950089d1e272c2607419413f952cacab46eb7fb4c0307`. Cost if wrong: restore the preserved file after provenance clarification. No bytes were deleted.
4. Unpublished transition v1 binds `predecessorRebaseHeadSHA256`; genesis is SHA256 of UTF-8 `KnitNote.SyncMutationJournal.RebaseHistory.v1`, next head is transition integrity. Checkpoint 5 stores final head, and a lease exposes the real head. Live CAS compares full global pending plus head; replay validates every link and final head. Genesis is fixture-only for first history, never fallback for nonempty authority. This detects independently reordered/missing transitions without duplicate historical global snapshots. Cost: bounded metadata and v1/v5/call-site compatibility work; unsigned integrity is not adversarial authenticity.
5. Conflict intent requires `write(_:preflightingWith:)`, binding safe journal location, validating/encoding the full transaction within 100,000,000 bytes and invoking actual lease `preflightRebase` immediately before the same synchronous private atomic writer. Ordinary `write(_:)` rejects conflict sources. Core uses the actual exclusive lease after full CAS under ownership; no callbacks/await or duplicate writer. Reason: only the real lease can project retained 64 MiB history. Cost: internal call-site migration and possible safe-path false rejection.
6. Retained media role is derived without a wire field: every planned file matches a live raw source or final live candidate attachment; all live raw sources need exact files; files matching neither reject. Artifact evidence covers every retained file. Source-only data survives deletion/tombstone resolution without domain resurrection or new cleanup authority. Reason: final-candidate-only matching contradicted durable raw evidence. Cost: extra retained bytes/lifetime management and installer/recovery complexity.
7. Keep attachment transaction construction on MainActor, matching current JSONProjectStore ownership, and separately run encode/decode/real-lease/write on detached workers, including after the 100 MB test. Task 3's two SIGBUS runs located nested integrity JSONEncoder construction at a 544 KiB cooperative-stack guard. This is a supported-context restriction, not a universal constructor fix. Cost if wrong: future/background construction or deeper worker paths can still crash. The original reports are `swiftpm-testing-helper-2026-09-06-093339.ips` and `swiftpm-testing-helper-2026-09-06-093357.ips` under the user's DiagnosticReports directory; corresponding Task 3 logs and detached controls remain listed in `task-3-report.md`.
8. Raw-only files use `SyncMetadata/conflict-source-attachments/<accountIDHash>/<lowercase-versionUUID>`, with canonical-matching lowercase 64-hex account. Existing installer verifies immutable version/hash/size, actual path/inode/ancestor authority, pre-intent collision/symlink refusal and evidence-backed identical-byte reuse. Narrow recovery exclusions support only this retained path. No mapper expansion, domain resurrection, pruning or guessed cleanup. Reason: final-domain mapping cannot name deleted/unselected source evidence. Cost: retained storage growth and account-specific lifetime/capacity coordination.
9. The causal allocator observes every actual logical stamp in validated hydrated canonical records, not merely entity summaries. Accepted field 1000/entity 0 otherwise produced a local revision 4 and erased the post-commit edit on retry. Existing merge policy/formats and immutable attachment bytes remain; overflow still blocks. Tests cover entity 0 and 1000, new local stamps above 1000, surviving edits and unrelated FIFO. Genuine edits issued before observation still follow merge ordering. Cost: larger monotonic revisions and allocation/overflow regression risk, covered by existing publication/allocator tests. The earlier weakened tail oracle was withdrawn.
10. Accept the scoped rereview's newly reachable per-file 100,000,000-byte bound violation as real and load-bearing, not waived or out of scope. Both original findings are fixed at `165d958`, but ordinary versioned/ACK reads can now accept a native valid oversized source because the existing reader uses its expected byte count as the ceiling. Preserve the one-final-fix-wave cap and park implementation pending explicit user direction for an additional cycle. Do not freeze, full-validate, merge, push or activate this known noncompliant candidate. The report must say review NOT passed despite green 272/155 covering tests. Cost if wrong: delay and another approval for a small bound fix; waiving it would permit oversized reads against the accepted contract. Retain all worktree/scratch/evidence; no deletion. This adjudicates a residual finding and does not complete Task 7.

Task 6 operational clarifications are separate from these wire rulings. A local suffix not yet scheduled to transport must fail full-queue handoff; three attempts terminate with a durable-commit blocker and retained data until normal scheduling/retry or restart. Prefix matches cannot authorize it. Keep the existing single configured-zone send kick after an accepted handoff and recheck epoch/generation after awaits; add no nested retry loop or unconditional self-scheduling. Omitting the kick risks stalled progress; missing post-await checks risks obsolete success. These limitations remain visible to activation planning.

## Prior evidence and review provenance

The specification coverage map remains: §§1–3 → Tasks 1/4/6 (existing merge policy); §4 → Tasks 1–4/6 (raw authority, CAS and ownership); §5 → Tasks 2–4/6 (capacity preflight and shared budget); §6 → Tasks 2–5 (native history, format 7 and fresh recovery); §7 → Task 6 (attempt/version ACK, cleanup and exact handoff); §8 → Tasks 1–7 (behavioral fault/acceptance matrix); §9 → Task 7 (disabled-sync evidence and deferred activation gates). The whole-plan review must assess retained checkpoint history capacity/latency, portable-token path exclusion versus complete source CAS, same-attempt retry ancestry versus newer failures, and effective cleanup proofs after rebase; these are review targets, not exemptions.

Tasks 1–6 reports and scoped reviews in the plan scratch retain exact predecessor commands, logs, exits, warnings, fixture corrections and causal failures. They are predecessor evidence, not fresh Task 7 full-suite results. Tasks 4 and 5 scoped reviews were accepted without fixes. Task 6 review identified an Important throwing-materializer continuation that could poison newer versions/reset contexts and a Minor stale-sent test with an unobservable wait. Commit `47e9db6` fixed both; the scoped rereview accepted the guard and observed-verification regression. Its final six suites were 150/150, 28.138 s, exit 0. Prior 159/8 Core evidence was bound to unchanged Core trees, not rerun by that App-only fix.

Task 7 phase-1 scoped review is approved. The single whole-plan review, one final fix wave, and one scoped rereview have now occurred, as detailed above. Rereview leaves one Important finding OPEN, so there is no final review approval. Further implementation requires user direction under ruling 10. No independent review is claimed from any implementer's self-review.

Legacy publication formats 2–6 use fixed nonempty bytes generated at accepted old-writer commit `cfcbfb83836c0562c1d8cacd0262b9553a9afa2c`, captured in `/tmp/conflict-rebase-task3-fixture-capture.log`, then embedded in tests before the format-7 writer change. They are **not historical release artifacts**. Tests validate and byte-exactly re-encode those bytes and reject injected conflict sources. The temporary generator's unnecessary-try warning was removed with the generator. Native journal versions 1–4 retain their old replay semantics; reviewed migration coverage verifies exact ACK successors while v5 retains rebased receipts/history. These cases are included in the covering selection.

Test provenance remains distinct: Task 1/2 fail-closed scaffold and missing API compilation are not behavioral success/failure proof; Task 3 includes real omitted relationship checks, raw-only media failures, fixture-size/tombstone corrections and separate constructor crashes; Task 4 includes actual stale authority, causal observation and retained inode failures; Task 5's deliberate checkpoint UUID mutation tests its oracle; Task 6 includes real missing raw-asset authority, deliberate budget/token/CAS regressions and the actual suspended-throw regression. Task 7's intentional revision mutation is an oracle check, and its initial compilation/error-wrapper expectations are fixture corrections. No test-count summary conceals these categories.


## Current fix-wave covering evidence (165d958; review still blocked)

These are existing captured results from the one fix wave, read back and hashed during report finalization; no tests were rerun in this report-only pass. Core: exit **0**, **272/272 in 12 suites**, test **286.631 s**, build **18.83 s**. App: exit **0**, **155/155 in six suites**, test **32.543 s**, build **0.15 s**. Discovery: exit **0**, build **0.21 s**, 155 required declarations (25 coordinator / 68 transport / 11 account / 11 assets / 22 remote-batch / 18 conflict), plus **9 live declarations compile/discover only**. Final three logs contain no warnings, errors or recorded issues; the warning/error scan returns 1 for no matches. No timeout or interrupted run is reported. These are covering checks, not full Core or Xcode validation.

Exact Core command, workdir `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-swift-cache --config-path /tmp/conflict-rebase-swift-config --security-path /tmp/conflict-rebase-swift-security --filter 'SyncConflict|JSONProjectStoreConflict|SyncMutationJournal|JSONProjectStoreCanonicalDurabilityTests|JSONProjectStoreSyncPublicationTests|SyncPublicationEvidenceDurabilityTests|recoveryAttachmentReadCannotExceedRemainingCaptureBudget' > /tmp/conflict-rebase-final-fix-core-covering.log 2>&1
```

Exact discovery and App commands, workdir `/private/tmp/conflict-rebase-harness`, run separately and serially:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --cache-path /tmp/conflict-rebase-harness-cache --config-path /tmp/conflict-rebase-harness-config --security-path /tmp/conflict-rebase-harness-security list > /tmp/conflict-rebase-final-fix-discovery.log 2>&1
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-harness-cache --config-path /tmp/conflict-rebase-harness-config --security-path /tmp/conflict-rebase-harness-security --filter 'KnitNoteCloudSyncCoordinatorTests|CloudSyncEngineTransportTests|CloudAccountTransitionCoordinatorTests|CloudAssetFileStoreTests|RemoteBatchCommitterIntegrationTests|ConflictRebaseIntegrationTests' > /tmp/conflict-rebase-final-fix-nohost.log 2>&1
```

The actual-source harness and separate caches remain as previously documented. Empty XCTest compatibility results are not used as acceptance.

Fix-wave behavioral provenance (literal filters and command prefixes are retained in `final-fix-report.md`): Core aggregate-media RED exited 1 with a real `tooLarge` error, one issue in 0.264 s (build 18.72 s); focused Core GREEN 2/2 in 0.452 s (build 31.17 s). Initial App RED had 17 classification/native-file issues in 2.155 s (build 5.37 s), confirmed with a current-error wait at 2.010 s (build 5.21 s). Focused App GREEN was four tests/nine cases in 2.821 s (build 16.29 s). The final native-IO oracle RED temporarily restored only the predecessor coordinator, producing 27 issues in four tests/eight cases, 2.511 s (build 8.36 s); byte-identical fixed restoration preceded GREEN, four/eight in 2.439 s (build 6.15 s). These were behavioral failures, not compiler or fixture errors. The earlier Core fixture used opaque verified bytes; its final content became valid JSON plus whitespace without altering the actual 40,000,000-byte sizes or capacity assertions. None of this supplies an oversized-single-file negative test for the newly open finding.

All logs below are under `/tmp/`. Final three hashes were freshly verified against the captured files; earlier RED/GREEN hashes are the retained fix report's provenance.

| Log | SHA-256 |
| --- | --- |
| conflict-rebase-final-fix-core-red.log | d13f8c7c2e2bc160511bdb1d34fb956de7b68c3abc0617f9eac052388eea593f |
| conflict-rebase-final-fix-app-red.log | d65a9cf24c35a294a0f66942036d8d5dbd796e17f7bfabeb1f1cf04352cf6dd2 |
| conflict-rebase-final-fix-app-red-confirmed.log | 393f08395d95fd85b7b19a62c13523d6fe1281ea675d34e4af957f6fae40696e |
| conflict-rebase-final-fix-core-focused.log | 84f9b03fd6957d600a2ad0df61bec99a1d7896a79d76afd3a1a5739111a649f1 |
| conflict-rebase-final-fix-app-focused.log | 4033447c11ba787ec113a396ea96d7a16fe1987e6aecefea966e7e46c9827dca |
| conflict-rebase-final-fix-app-native-oracle-red.log | 89355af8f226644f778731693a06a29255be97f8d10d7bc1acac10653a9eb0c2 |
| conflict-rebase-final-fix-app-native-oracle-green.log | 0e80bfd268c2197a0f95ce1a214f0f2c4c8582a732c1407dbf2020615eadd452 |
| conflict-rebase-final-fix-core-covering.log | e51ab6e192368ff0c2dca4a5e9cd464f62f8f8f8d7369721e6a7e93b74669490 |
| conflict-rebase-final-fix-discovery.log | cee7af748ea4e3a8854f06d17cec97a6ef3fee62ec71aec2a17ef0f15f98ded7 |
| conflict-rebase-final-fix-nohost.log | 74acf92ee360805e5ee366fbf5eb3a1cb6f600d7caee32e12b9b189619a4f095 |

## Current source/test changed-file manifest (not a freeze)

Scope: every source/test/Xcode file changed between execution base `c1b96789e2e1abddb5b7548f61ae0e203c23b11e` and blocked commit `165d958796b101aa850745b4cfe0551d0573735b`. All 26 SHA-256 values were freshly read from the clean current checkout before report edits. The mutable report is excluded from this source/test manifest; its report-only commit/hash is recorded separately in scratch.

| File | SHA-256 |
| --- | --- |
| KnitNote.xcodeproj/project.pbxproj | 7f2ef0a9409c132900527d725c1e8c0a54da934dcc9d0dfd181e41478f73576d |
| KnitNote/CloudSync/CloudRecordSystemFieldsStore.swift | 75402d3916d8a5cc0e50fe145a87beee8cee7f3c3ca5466d270ae1fbd0659409 |
| KnitNote/CloudSync/CloudSyncEngineTransport.swift | 9e32195769735fd74706ebb9ce756fdfff1f13813d1eb5b81fcd775196468263 |
| KnitNote/CloudSync/JSONProjectStoreRemoteBatchCommitter.swift | 5f9adc562de2eb73c50003d7a492660bd2291e9a9ffd869535abb861238a016d |
| KnitNote/CloudSync/KnitNoteCloudSyncCoordinator.swift | 72c9fcd4a828e7bffaef63cdc830047026be442d3b642500eab52634171ef589 |
| Sources/KnitNoteCore/CloudSync/SyncConflictRebase.swift | b8cb12cad246690232114235db05fee81679f0d82b5b38ddf328f7261cb8124f |
| Sources/KnitNoteCore/CloudSync/SyncMutationJournal.swift | 5f82187f2779b28be9e8d313c619fb30ac6e653467f8bb96242607f0fe4f1a10 |
| Sources/KnitNoteCore/CloudSync/SyncMutationPublishing.swift | be6b5dafccd76bedd1f3affd203e467778745fcd64bb99fc0d0a3ae6557f5d4d |
| Sources/KnitNoteCore/Projects/JSONProjectStore.swift | 92ea1b1efffef3989cc4f629c8979c90333e2b11401f2ac50b8c64810eb0ea12 |
| Tests/KnitNoteAppTests/CloudAccountTransitionCoordinatorTests.swift | 9f05ebd00e2788c8a8199294abbe7d3bc2655a78da67eec238d0aa1bb6e2ce5e |
| Tests/KnitNoteAppTests/CloudKitDevelopmentIntegrationTests.swift | d837cc325958131553c1609564f8ffadf1c6b997220308c78c10deae211054ab |
| Tests/KnitNoteAppTests/CloudSyncEngineTransportTests.swift | 8a8f4ab5d02dc3de6ac6a71d1c315ec55509b9a2b04be4ed5c7a0006a0abd14e |
| Tests/KnitNoteAppTests/ConflictRebaseIntegrationTests.swift | e751256e413615a5005ff0cde7d44fe7d2088e97dfc7c842aa57d9e0c7a8a2be |
| Tests/KnitNoteAppTests/KnitNoteCloudSyncCoordinatorTests.swift | f1690d7b9158f9202bd90096db8c4385a240779f49b3a8a2832cd3a22b9331a2 |
| Tests/KnitNoteAppTests/RemoteBatchCommitterIntegrationTests.swift | 7901808914f5b291539de29029d09f76120574a1007d8c035d3974853787a677 |
| Tests/KnitNoteCoreTests/ConflictRebaseFixture.swift | 52d598f0ed1143a5d25d286b9befa700f900ecaf353c4fc97954fbab39738467 |
| Tests/KnitNoteCoreTests/JSONProjectStoreConflictRebaseTests.swift | cd6016a3d39f99b52fed847ba7261ae1d789835a8325e2d61270387ba2be7ff5 |
| Tests/KnitNoteCoreTests/JSONProjectStoreConflictRecoveryTests.swift | e4233235f1139052f90c2c9c04aea07473411870a7f8016e31e9e192bfa578ef |
| Tests/KnitNoteCoreTests/SyncCanonicalPublicationTransactionTests.swift | 7b1b8f39d266e4fc5d02c39b566a0e3f5c45354cf86d2855505f319154313706 |
| Tests/KnitNoteCoreTests/SyncConflictInputTests.swift | e958aea6da68ee479e9c6f5238da1383fde7d0cb59e357e31b2c39086026604a |
| Tests/KnitNoteCoreTests/SyncConflictJournalTests.swift | 58146245979c76b0eb927062b157e0cfc3bad1d8af9ce36b12a11f794726020d |
| Tests/KnitNoteCoreTests/SyncConflictPublicationTests.swift | 81b56db4b5746dcd8c7f74a9d43f8366f957f0d39868f3d374f4c977f9e9ea42 |
| Tests/KnitNoteCoreTests/SyncMutationJournalFinalFixTests.swift | 69c733797bc4f4271e82d4aeea7e904a477603a7c7c6190c4222f7f09415b9f1 |
| Tests/KnitNoteCoreTests/SyncMutationJournalSegmentTests.swift | befecd24c529ac69187df3db9aac48dbc78d2ec122bd95e9353045ceea83af78 |
| Tests/KnitNoteCoreTests/SyncPendingRecoveryPacketTests.swift | 0db798e86ac543bf99e6f23480aee087b5bc30ff308b257863feb326bf7ed26d |
| Tests/KnitNoteCoreTests/SyncRemoteBatchTransactionTests.swift | 9482693aa18c3fbe0a2db78fd9307198e733235b2846786be607c96d24cbd34b |

## Deferred final commands and gates

The following commands remain deferred and were **not executed**. They must not run on the currently blocked source/test state. After explicit direction, correction and the required accepted review, any later freeze must re-read `/tmp/task4-run-bounded.py`. It was inspected in phase 1: subprocess owns a new session/process group; timeout sends TERM only to that group, waits ten seconds, then KILL if needed, and returns 124. It does not kill unrelated builds. Future authorized commands would run serially outside the managed sandbox, from the workdir, each with its separately captured exit:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/python3 /tmp/task4-run-bounded.py 1800 /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-swift-cache --config-path /tmp/conflict-rebase-swift-config --security-path /tmp/conflict-rebase-swift-security > /tmp/conflict-rebase-full-core.log 2>&1
/usr/bin/xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/conflict-rebase-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing > /tmp/conflict-rebase-macos-build.log 2>&1
/usr/bin/xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/conflict-rebase-ios-derived CODE_SIGNING_ALLOWED=NO build > /tmp/conflict-rebase-ios-build.log 2>&1
```

Full Core, macOS build-for-testing, and iOS build are all **NOT RUN / NOT PASSED; blocked before freeze**. No `--skip-build` binary reuse is claimed. The earlier full Core 2,369/174 belongs to `c7465f8` and does not validate this candidate.

The required 100,000,000-byte authority/transaction/file bounds and 64 MiB native checkpoint bound have not been redefined; **the newly reachable ordinary versioned/ACK per-file enforcement gap remains OPEN**. Retained rebase history is not pruned: exhaustion fails closed and remains a capacity/latency activation gate. Account-scoped raw-source storage retains evidence without new cleanup permission; its storage lifetime and real-device performance remain gates. MainActor construction plus actual worker codec/transport coverage does not prove arbitrary nonisolated small-stack constructor safety.

Lifecycle/account-switch/deletion end-to-end acceptance, UI/Watch activation, device acceptance, capacity/latency measurement, and release gates are deferred. This work uses temporary fixtures only, no App test host, live CloudKit, Keychain, user data, installation, signing/archive/export, purchase/localization changes, upload, submission, merge or push. Keep the worktree and plan scratch until separately authorized integration. Even successful final tests/builds will establish only the disabled-sync milestone, not release readiness.
