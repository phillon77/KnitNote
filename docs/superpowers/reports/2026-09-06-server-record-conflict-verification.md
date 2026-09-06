# Server-record conflict durable rebase — provisional verification

Status: **Task 7 phase 1 acceptance implemented and covering tests passed; final review and frozen validation pending.** This report is not release or sync-activation approval. No full Core run or Xcode final build has been performed for this phase.

## Candidate and scope

Workdir: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
Branch: `docs/cross-device-sync-design`.
Execution base: `c1b96789e2e1abddb5b7548f61ae0e203c23b11e`.
Accepted Tasks 1–6 base: `47e9db6647d822ae18c277590b6ee06fdce3e517`; initial checkout was clean.
Version/build remains **1.7.0 (13)**. Phase 1 changes only the two named acceptance-test files and this report; production trees remain:

- `Sources`: `72ce79f0d5a2dc6a9106929e48e1604a5e0bef3a`
- `KnitNote/CloudSync`: `b8b92b48e86f6bec932d97c6c6a541b5a20d5dba`

The final reviewed SHA, final `Tests` tree, changed-file SHA-256 manifest, and final validation log hashes will be frozen after the controller's Task 7 scoped review and one whole-plan review/fix loop. The later report-only commit must preserve those frozen source/test trees. This is explicitly not that freeze.

## Combined acceptance

Core `combinedThreeSavesSixWatchProofsAndMediaRecoverTwice` reuses the actual attachment-history fixture, native journal, publication fault hook, released-handle helper and complete filesystem snapshot. It issues exactly three selected project saves (`Local 1`, `Local 2`, `Local 3`), interleaves two other-project saves and six durable Watch increments, retains two photo versions and a nonempty remote receipt, then resolves server fields to `Server`. Before commit, a manually derived full pending/version list preserves every unrelated global slot and each selected save's entity summary; a full expected checkpoint preserves all other records and receipts. The retained archive is independently compared with the complete predecessor archive after the explicit name change and deterministic ordering. Full attachment evidence and the six exact command IDs are retained before the fault.

The real `.afterJournal` boundary throws and the store reports `pendingRepair`; the test requires one hook hit, exact durable intent, rebased native queue and the predecessor canonical checkpoint. Initial store, journal and checkpoint handles are released with weak witnesses. Two separately constructed sets then recover the same full checkpoint, pending payloads/tokens, native transition/head, archive, six-proof ledger, evidence and files; each set deallocates before the next reopen. Whole path inventory is checked, preexisting unrelated files/media/proof shards keep bytes and inode, and the second recovered tree equals the first byte-for-byte and inode-for-inode. The other counter must retain all six increments.

App `combinedConflictHandoffEditRetryAndExactACKs` uses the real transport callbacks, actual account epoch, JSONProjectStore adapter and native versioned journal. An unrelated project/photo FIFO is present throughout. The existing failing-boundary probes inject one stale preparation and one stale handoff, so the single event uses exactly three Core attempts and two handoffs. The handoff fault hook first proves the exact durable revision-1 queue and canonical remote content, then creates a local edit whose stamp exceeds 1000, captures that immutable native save and performs normal versioned transport scheduling. The actual retry commits and accepts the full queue with selected revisions `[2, 1]`; it does not reset the attempt budget.

The failed old record's actual late success callback returns through the real transport rejection boundary before `.sent` emission. A direct verifier control using the exact captured original token/attempt/production epoch also requires `staleOperation`; this is not evidence that the coordinator consumed a queued old `.sent`. The existing Task 6 `staleSentQueuedBeforeRebasePreservesSameIDNewRevision` covers that separate coordinator boundary with an observable verification attempt. This combined case asserts unchanged exact pending and zero cleanup after the awaited old callback, then uses the correct new callback as positive progress: it waits for actual cleanup invocation after journal CAS, checks the complete resulting FIFO, and requires a native `alreadyAcknowledged` receipt. The original issued token reports `staleVersion`, and the later local save is ACKed separately. Unrelated FIFO, canonical records, evidence, actual photo and native staged media bytes/inodes remain unchanged. Expected queues are retained before the callbacks they check, with no production merge helper or mutated-result-derived replacement oracle. Success still goes through the actual transport verifier; only failure injection is simulated.

## Phase 1 commands and evidence

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

The source of these decisions is this plan's `.superpowers/sdd/2026-09-06-server-record-conflict-durable-rebase/progress.md`. Its headings interleave the numbered entries; all nine are retained here in decision order, including the superseded first ruling.

1. Checkpoint 5 initially required sorted unique `versionedAcknowledgements: [SyncMutationVersionToken]` alongside history, because compaction would otherwise lose exact kind-5 ACK proof. Validation had to require absent pending and effective issued/history authority; identity-only legacy ACK could not count. Cost if wrong: v5 migration/recovery rework and bounded metadata/latency. **Superseded by ruling 2.**
2. The final field is `[SyncVersionedMutation]`, retaining full acknowledged mutation and exact token. Issued shards retain a record digest, not enough full data to recompute a revision-0 portable token. Receipts validate against issued/effective proof, remain loadable after authorized staged cleanup, and retained paths do not grant new cleanup. All bytes remain under 64 MiB, with no pruning or legacy-format/shard changes. Cost: larger checkpoints, earlier fail-closed capacity exhaustion and v5 validation work.
3. The unexpected exact untracked `Sources/KnitNoteCore/CloudSync/SyncConflictRebase 2.swift` was recoverably moved to this plan's `preserved-scaffold-duplicate.swift.txt`. The author recognized the constant-digest scaffold bytes but not the duplicate-path origin. Compiling both would fail; preservation retained external-change evidence. SHA-256 stayed `b1680cad4368223f1d0950089d1e272c2607419413f952cacab46eb7fb4c0307`. Cost if wrong: restore the preserved file after provenance clarification. No bytes were deleted.
4. Unpublished transition v1 binds `predecessorRebaseHeadSHA256`; genesis is SHA256 of UTF-8 `KnitNote.SyncMutationJournal.RebaseHistory.v1`, next head is transition integrity. Checkpoint 5 stores final head, and a lease exposes the real head. Live CAS compares full global pending plus head; replay validates every link and final head. Genesis is fixture-only for first history, never fallback for nonempty authority. This detects independently reordered/missing transitions without duplicate historical global snapshots. Cost: bounded metadata and v1/v5/call-site compatibility work; unsigned integrity is not adversarial authenticity.
5. Conflict intent requires `write(_:preflightingWith:)`, binding safe journal location, validating/encoding the full transaction within 100,000,000 bytes and invoking actual lease `preflightRebase` immediately before the same synchronous private atomic writer. Ordinary `write(_:)` rejects conflict sources. Core uses the actual exclusive lease after full CAS under ownership; no callbacks/await or duplicate writer. Reason: only the real lease can project retained 64 MiB history. Cost: internal call-site migration and possible safe-path false rejection.
6. Retained media role is derived without a wire field: every planned file matches a live raw source or final live candidate attachment; all live raw sources need exact files; files matching neither reject. Artifact evidence covers every retained file. Source-only data survives deletion/tombstone resolution without domain resurrection or new cleanup authority. Reason: final-candidate-only matching contradicted durable raw evidence. Cost: extra retained bytes/lifetime management and installer/recovery complexity.
7. Keep attachment transaction construction on MainActor, matching current JSONProjectStore ownership, and separately run encode/decode/real-lease/write on detached workers, including after the 100 MB test. Task 3's two SIGBUS runs located nested integrity JSONEncoder construction at a 544 KiB cooperative-stack guard. This is a supported-context restriction, not a universal constructor fix. Cost if wrong: future/background construction or deeper worker paths can still crash. The original reports are `swiftpm-testing-helper-2026-09-06-093339.ips` and `swiftpm-testing-helper-2026-09-06-093357.ips` under the user's DiagnosticReports directory; corresponding Task 3 logs and detached controls remain listed in `task-3-report.md`.
8. Raw-only files use `SyncMetadata/conflict-source-attachments/<accountIDHash>/<lowercase-versionUUID>`, with canonical-matching lowercase 64-hex account. Existing installer verifies immutable version/hash/size, actual path/inode/ancestor authority, pre-intent collision/symlink refusal and evidence-backed identical-byte reuse. Narrow recovery exclusions support only this retained path. No mapper expansion, domain resurrection, pruning or guessed cleanup. Reason: final-domain mapping cannot name deleted/unselected source evidence. Cost: retained storage growth and account-specific lifetime/capacity coordination.
9. The causal allocator observes every actual logical stamp in validated hydrated canonical records, not merely entity summaries. Accepted field 1000/entity 0 otherwise produced a local revision 4 and erased the post-commit edit on retry. Existing merge policy/formats and immutable attachment bytes remain; overflow still blocks. Tests cover entity 0 and 1000, new local stamps above 1000, surviving edits and unrelated FIFO. Genuine edits issued before observation still follow merge ordering. Cost: larger monotonic revisions and allocation/overflow regression risk, covered by existing publication/allocator tests. The earlier weakened tail oracle was withdrawn.

Task 6 operational clarifications are separate from these wire rulings. A local suffix not yet scheduled to transport must fail full-queue handoff; three attempts terminate with a durable-commit blocker and retained data until normal scheduling/retry or restart. Prefix matches cannot authorize it. Keep the existing single configured-zone send kick after an accepted handoff and recheck epoch/generation after awaits; add no nested retry loop or unconditional self-scheduling. Omitting the kick risks stalled progress; missing post-await checks risks obsolete success. These limitations remain visible to activation planning.

## Prior evidence and review provenance

The specification coverage map remains: §§1–3 → Tasks 1/4/6 (existing merge policy); §4 → Tasks 1–4/6 (raw authority, CAS and ownership); §5 → Tasks 2–4/6 (capacity preflight and shared budget); §6 → Tasks 2–5 (native history, format 7 and fresh recovery); §7 → Task 6 (attempt/version ACK, cleanup and exact handoff); §8 → Tasks 1–7 (behavioral fault/acceptance matrix); §9 → Task 7 (disabled-sync evidence and deferred activation gates). The whole-plan review must assess retained checkpoint history capacity/latency, portable-token path exclusion versus complete source CAS, same-attempt retry ancestry versus newer failures, and effective cleanup proofs after rebase; these are review targets, not exemptions.

Tasks 1–6 reports and scoped reviews in the plan scratch retain exact predecessor commands, logs, exits, warnings, fixture corrections and causal failures. They are predecessor evidence, not fresh Task 7 full-suite results. Tasks 4 and 5 scoped reviews were accepted without fixes. Task 6 review identified an Important throwing-materializer continuation that could poison newer versions/reset contexts and a Minor stale-sent test with an unobservable wait. Commit `47e9db6` fixed both; the scoped rereview accepted the guard and observed-verification regression. Its final six suites were 150/150, 28.138 s, exit 0. Prior 159/8 Core evidence was bound to unchanged Core trees, not rerun by that App-only fix.

Task 7 scoped review and the single whole-plan review from `c1b96789e2e1abddb5b7548f61ae0e203c23b11e` are **pending**. Any source finding must be fixed and its scoped fix reviewed before freeze and expensive full validation. No independent review is claimed from this implementer's self-review.

Legacy publication formats 2–6 use fixed nonempty bytes generated at accepted old-writer commit `cfcbfb83836c0562c1d8cacd0262b9553a9afa2c`, captured in `/tmp/conflict-rebase-task3-fixture-capture.log`, then embedded in tests before the format-7 writer change. They are **not historical release artifacts**. Tests validate and byte-exactly re-encode those bytes and reject injected conflict sources. The temporary generator's unnecessary-try warning was removed with the generator. Native journal versions 1–4 retain their old replay semantics; reviewed migration coverage verifies exact ACK successors while v5 retains rebased receipts/history. These cases are included in the covering selection.

Test provenance remains distinct: Task 1/2 fail-closed scaffold and missing API compilation are not behavioral success/failure proof; Task 3 includes real omitted relationship checks, raw-only media failures, fixture-size/tombstone corrections and separate constructor crashes; Task 4 includes actual stale authority, causal observation and retained inode failures; Task 5's deliberate checkpoint UUID mutation tests its oracle; Task 6 includes real missing raw-asset authority, deliberate budget/token/CAS regressions and the actual suspended-throw regression. Task 7's intentional revision mutation is an oracle check, and its initial compilation/error-wrapper expectations are fixture corrections. No test-count summary conceals these categories.

## Deferred final commands and gates

After controller review, freeze SHA/trees/manifest and re-read `/tmp/task4-run-bounded.py`. It was inspected in phase 1: subprocess owns a new session/process group; timeout sends TERM only to that group, waits ten seconds, then KILL if needed, and returns 124. It does not kill unrelated builds. The following are required serially outside the managed sandbox, from the workdir, each with its separately captured exit:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/conflict-rebase-clang-cache /usr/bin/python3 /tmp/task4-run-bounded.py 1800 /usr/bin/arch -arm64 /usr/bin/swift test --disable-sandbox --no-parallel --cache-path /tmp/conflict-rebase-swift-cache --config-path /tmp/conflict-rebase-swift-config --security-path /tmp/conflict-rebase-swift-security > /tmp/conflict-rebase-full-core.log 2>&1
/usr/bin/xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/conflict-rebase-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing > /tmp/conflict-rebase-macos-build.log 2>&1
/usr/bin/xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/conflict-rebase-ios-derived CODE_SIGNING_ALLOWED=NO build > /tmp/conflict-rebase-ios-build.log 2>&1
```

Full Core, macOS build-for-testing, and iOS build are all **pending**. No `--skip-build` binary reuse is currently claimed. The earlier full Core 2,369/174 belongs to `c7465f8` and does not validate this candidate.

The existing 100,000,000-byte authority/transaction/file bounds and 64 MiB native checkpoint bound remain unchanged. Retained rebase history is not pruned: exhaustion fails closed and remains a capacity/latency activation gate. Account-scoped raw-source storage retains evidence without new cleanup permission; its storage lifetime and real-device performance remain gates. MainActor construction plus actual worker codec/transport coverage does not prove arbitrary nonisolated small-stack constructor safety.

Lifecycle/account-switch/deletion end-to-end acceptance, UI/Watch activation, device acceptance, capacity/latency measurement, and release gates are deferred. This work uses temporary fixtures only, no App test host, live CloudKit, Keychain, user data, installation, signing/archive/export, purchase/localization changes, upload, submission, merge or push. Keep the worktree and plan scratch until separately authorized integration. Even successful final tests/builds will establish only the disabled-sync milestone, not release readiness.
