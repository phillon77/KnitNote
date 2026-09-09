# Legacy import source observation — verification evidence

Final status, 2026-09-10: all three tasks and their individual reviews are complete. The whole-unit review's Important inventory finding and Minor type-comment finding were fixed at cdd7a5e and independently re-reviewed with no remaining Critical/Important findings. Root re-ran the exact final source: 165 tests / 9 suites, EXIT0. This report is not release, account-authority, source-installation, or device acceptance evidence. Earlier handoff results below are preserved as chronological evidence; the final section supersedes pending statuses and earlier test counts.

## Revision scope

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`
- Branch: `docs/cross-device-sync-design`
- Approved-plan base: `99ece4bcdc400ec640178af4e4427f11f79a425e`.
- Task 3 base after reviewed Tasks 1/2: `25ed0c13c949414002c60f010e4041bbe1c208e4`.
- Task 3 implementation candidate: `968754cbb96a91a7624d3fea61c1ec848cab0ecb` (`feat: revalidate legacy preparation before confirmation`). This contains exactly the new coordinator and its tests. The following report-only commit does not alter that tested source.
- Source SHA-256: coordinator `683ede321fda423ae381d419e44f35c8e7835cc50994e927e2c35e1209bc7805`; tests `755df874c4f98d8abb0a50118c5b2b379d6630c384447eaf234d0bc4efe79c69`.

The controller ledger records Task 1 as reviewed through `d8ed6fb8b5b5e0211d691cb3efb575d5d0927c50`, Task 2 as reviewed through `25ed0c13c949414002c60f010e4041bbe1c208e4`. This Task 3 implementer did not repeat or independently certify those individual review verdicts. The related set below exercises their current code together with Task 3.

## Implemented behavior

`LegacyImportPreparationCoordinator` is an internal MainActor owner of one stored native worker handle. `prepare` invokes native preparation on that worker and uses actual source/backup digests to present the existing consent-model proposal. Account digest and source/session fields are caller observations. They are not authenticated account evidence. The context contains no source URL or caller content digest.

`confirm` first matches pending proposal identity with `===`, checks admission and context, captures the generation/context, runs native revalidation, then checks the generation/context on MainActor before consuming consent. Incorrect or foreign proposals return false without disturbing a newer pending proposal. A successful confirmation consumes intent once; no installer callback runs.

`invalidate()` synchronously changes generation and revokes pending consent. Owners must call it for every account/source/session change, including A -> B -> A. No production event listener was added. Busy admission throws the existing `operationInProgress` error before changing the pending owner. Successful native observations remain privately retained by package URL, and no package cleanup is performed.

`stopAndDrain()` revokes and waits for the current synchronous native operation; it is reusable rather than a permanent stop state. Caller cancellation is checked before admission and after the native await. Preparation cancellation returns `CancellationError`; confirmation cancellation returns false. Cancellation does not interrupt synchronous native I/O or abandon its handle. The initiating continuation and drain share ID-checked completion bookkeeping so late continuations cannot clear a newer worker or revoke a newer generation. A native failure is rethrown after invalidating its own generation, even if owner invalidation occurred during that operation.

The package app-version metadata uses `AppVersionInfo.current()?.version ?? "unknown"`; it has no authority meaning and is not a hardcoded release assertion.

## Exact validation command and timeout

All test invocations ran in the worktree above. Each uses the inspected `/tmp/task4-run-bounded.py` process-group runner with a 900-second timeout and exit/elapsed logging. No invocation timed out. There was one compiler lane; `ps` initially returned `operation not permitted` in the sandbox, then the formally escalated read confirmed no active Swift compiler/test process.

Each focused invocation used this exact command, replacing only `LOG` with the listed absolute filename (the full command is also recorded at the top of each log):

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'LegacyImportPreparationCoordinatorTests' > LOG 2>&1
```

| Log (`/tmp/` prefix) | Exit | Result and elapsed |
| --- | --- | --- |
| `legacy-observation-task3-red-20260909-01.log` | 1 | Expected missing-symbol RED: coordinator/context do not exist; no tests ran, 18.537s. |
| `legacy-observation-task3-green-20260909-01.log` | 1 | First implementation compile attempt failed: Swift Testing throwing closures implicitly returned the non-Sendable MainActor proposal as a sending result; no tests ran, 57.673s. Fixed test closures to discard the value on MainActor. |
| `legacy-observation-task3-green-20260909-02.log` | 1 | 13 tests / 1 suite, 12 passed; one copy-fixture failure plus its follow-on cleanup issue, 25.052s. The test tried to read a final media path before the existing writer renamed its hidden temporary file; early fixture teardown then raced the still-running worker. Fixed partial-file inspection and deferred propagation of inspection errors until after drain. |
| `legacy-observation-task3-error-red-20260909-01.log` | 1 | 14 tests / 1 suite, 13 passed; actual behavior RED: `nativeError == .invalidArchive` failed because generation invalidation masked the native error with cancellation, 24.726s. |
| `legacy-observation-task3-green-20260909-03.log` | 0 | 14 tests / 1 suite pass after preserving the native error; 7.447s including build, 0.214s test run. |

Initial missing-symbol RED produced 28 `warning:` lines about unresolved async expressions. The first implementation compile attempt produced 48 repeated `warning:` lines for the existing unrelated `HighlightOverlayContractTests.swift:92` deprecated `String(contentsOf:)` initializer. Neither was suppressed. Subsequent focused runtime logs and the final related log contain zero `warning:` lines; this is an incremental-build observation, not proof that all repository warnings were removed.

The full related set ran once after the final implementation change, with formal sandbox escalation for the existing Unix socket fixture:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'LegacyImport|LegacyLocalImport|KnitNoteBackupServiceTests|KnitNoteBackupManifestTests|KnitNoteBackupPackagePlanTests|SyncRegularFileReaderTests' > /tmp/legacy-observation-task3-related-20260909-01.log 2>&1
```

Result: **160 tests / 9 suites, EXIT 0**, 7.534s including build, 5.428s test run; zero warnings in this log.

| Actual suite | Tests passed |
| --- | ---: |
| KnitNoteBackupManifestTests | 4 |
| KnitNoteBackupPackagePlanTests | 13 |
| KnitNoteBackupServiceTests | 87 |
| LegacyImportPreparationCoordinatorTests | 14 |
| LegacyImportSourceObservationTests | 18 |
| LegacyImportContentProjectionTests | 5 |
| LegacyLocalImportConsentModelTests | 6 |
| LegacyLocalImportPolicyTests | 1 |
| SyncRegularFileReaderTests | 13 |

The controller's earlier baseline was not green: 122 tests / 6 suites, EXIT 1, with `unixSocketIsRejectedWithoutOpeningIt` fixture EIO under sandbox; a focused sandbox rerun reproduced it, and the unchanged focused test passed only with formal escalation. Task 3 follows that recorded environment ruling. No socket fixture or assertion was relaxed.

## Log integrity

SHA-256 values below correspond to the completed logs, not running snapshots.

```text
f0d44249a14127de0f32000e08482eaab1bfe6ea9827bbbdf07becb82a9beeed  /tmp/legacy-observation-task3-red-20260909-01.log
f4fbf0d5b062381a67dad5e7e1db79ff837f3deac0c16f4fa5bf1eaf48fc83ca  /tmp/legacy-observation-task3-green-20260909-01.log
1d8de0c50e46d848b5a5a1dc54f2bf75966caaf0d08e72dac62b5e2e8dc19def  /tmp/legacy-observation-task3-green-20260909-02.log
2f94fa79e241609907f4846fe115302f1619c7ba4b35e1520d874398089db6b9  /tmp/legacy-observation-task3-error-red-20260909-01.log
1ff4328df01f87f4c16efda8ebb46f2683200b19a0c4ca7b67ecadb24f3d2832  /tmp/legacy-observation-task3-green-20260909-03.log
71df89459885a52b189c07ef661399b5be218a3b02ecbc86cfb2078a748b9337  /tmp/legacy-observation-task3-related-20260909-01.log
2038d26eeccf7dea33553a2edc2e749a1cc0dae35c6a45b05427ff235652797f  /tmp/legacy-observation-task3-reference-audit-20260909.log
```

## Behavior and unchanged-file evidence

- Real source fixtures use synthetic 32-byte account observations and locally created project archives; no real account access is established.
- Initial prepare asserts unchanged native source observation (including identities) and equal source/archive bytes. It still requires an explicit first confirmation and rejects the second confirmation.
- Source mutation, missing source, and tampered backup archive reject confirmation, revoke the proposal, and retain the backup. Restoring bytes does not resurrect the revoked proposal.
- The controlled copy test uses a 70,000-byte photo. Two source-observation chunks precede the first actual copy hook; while blocked, the hidden temporary backup file contains exactly 65,536 bytes. Cancelling and invalidating keeps retry busy, and drain has not completed. After release and drain, both original and completed backup contain all 70,000 original bytes and package inspection passes; retry creates a second retained package.
- Other barriers cover caller cancellation after a successful backup, native failure after owner invalidation, revalidation across explicit A -> B -> A invalidations, caller cancellation during confirmation, and busy calls leaving an active confirmation usable. The test barrier uses synchronous `NSCondition` sections plus async continuations, never sleeping or holding a lock across an await.
- `git diff --check` and `git diff --cached --check` passed before the implementation commit.
- `git diff --exit-code 25ed0c13c949414002c60f010e4041bbe1c208e4 -- Sources/KnitNoteCore/Backup Sources/KnitNoteCore/CloudSync/LegacyLocalImportConsentModel.swift Sources/KnitNoteCore/CloudSync/LegacyLocalImportPolicy.swift Sources/KnitNoteCore/Projects/JSONProjectStore.swift Package.swift KnitNote KnitNoteWatch` returned 0 with no output. Task 3 changes none of those existing entries, limits, models, production factories, or platform floors.
- `rg -n 'LegacyImportPreparationCoordinator|observeLegacyImportSource|prepareLegacyImportBackup' Sources Tests KnitNote KnitNoteWatch` produced the reference-audit log above. Searching it for `^KnitNote/|^KnitNoteWatch/` returned no matches (rg exit 1). Source usage is limited to the native service and isolated coordinator; all other calls are tests.
- Pre-existing dirty design, plan, reports and `.superpowers/absent-source-design-progress.md` were not staged or edited by Task 3. No production data cleanup occurred. Fixture teardown affects only each test's UUID temporary directory.

## Capacity and scope boundaries

The unchanged native admission uses the smaller of the backup category limit and **100,000,000 bytes** per file. Manifest and content projection are **1,000,000 bytes**; archive **20,000,000 bytes**; markup **2,000,000 bytes**; package **4,000,000,000 bytes**. Existing portable general-file compatibility remains **200,000,000 bytes**. The new coordinator adds no file readers or allocations of whole packages; native hashing/copying remains in 64 KiB chunks. Existing platform floors remain iOS 18 / macOS 15 / watchOS 11, and Task 3 changes no version/build settings from 1.7.0 (13).

The output proves matching content at the observations used. It does not prove historical account ownership, confer read/write or installation authority, or guarantee global source/backup snapshot isolation. Changes outside the native optimistic observation window remain a separate synchronization concern.

No installation, persistent receipt, crash-recovery protocol, formal source issuer, App/Watch/CloudKit/Keychain wiring, automation, push, merge, upload, signing, submission, or device acceptance was performed. Successful packages are intentionally retained; this slice introduces no cleanup policy.

## Reviews

Task 3 implementer self-review corrected test macro isolation, the partial-copy fixture/teardown assumption, and native error precedence. The final tested implementation has no known Task 3 correctness concern at handoff. Its lifecycle still requires owner invalidation and drain, as documented above.

Task 3 independent review: Approved by /root/legacy_preparation_review at3d01de6, no Critical/Important; optional exact interleaving coverage and pre-existing warning deferred.

Whole approved-unit review from `99ece4bcdc400ec640178af4e4427f11f79a425e`: completed by /root/legacy_observation_final_review at3d01de6; one Important inventory bound and Minor native result comments required a fix. Both addressed atcdd7a5e and /root/legacy_final_rereview approved the scoped fix, no new breakage.

Root verification and final review candidate: cdd7a5e63cf73fa51f0fb9a512c6edc3c11cbde8. Documentation-only completion updates do not change this tested source.

## Final controller verification and decisions

2026-09-10 00:18:31 local runner timestamp: root independently ran the full related filter on cdd7a5e. Result165 tests /9 suites, EXIT0,12.563s including build;11.320s test execution. No warning/error lines in this incremental log. Earlier160-test results predate the five final native inventory tests; final source-observation suite has23 tests instead of18. No full clean build, whole repository suite, device or release acceptance is implied.

The first root invocation failed before tests (EXIT2) because /tmp/task4-run-bounded.py no longer existed; cause unknown. Its error is preserved in /tmp/knitnote-legacy-final-iHUGGh/root-related.log. Root recreated the inspected equivalent process-group runner using apply_patch at /tmp/knitnote-legacy-final-iHUGGh/run-bounded.py. The same900s cap, exact flags and cache paths were retained. The pre-final-fix rerun passed160/9; the post-fix run below is the final evidence. No test or assertion was skipped.

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/knitnote-legacy-final-iHUGGh/run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'LegacyImport|LegacyLocalImport|KnitNoteBackupServiceTests|KnitNoteBackupManifestTests|KnitNoteBackupPackagePlanTests|SyncRegularFileReaderTests' > /tmp/knitnote-legacy-final-iHUGGh/root-final-cdd7a5e.log 2>&1
```

Formal escalation was used only for the established local socket-test restriction. Completed log SHA256: ae7897a02070b2034355a2d8fccd84e2c6dde3c8325e9f0e60504f106041e4fd. Runner SHA256: c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b.

### Task1/Task2 and final-fix history

| Stage | Commit / evidence |
| --- | --- |
| Task1 native observation |3cc7ae1; missing API and missing attachment behavior RED;11/3 native GREEN;133/8 related GREEN. |
| Task1 review fix |d8ed6fb; aggregate projection validation-before-allocation defect fixed. Oversized input precedence RED;13/3 scoped GREEN. Identical-roots fixture corrected to share the same archive bytes, keeping strict equality. Task review + scoped re-review approved. |
| Task2 verified backup |733233d; missing API RED; first21-test runtime run had9 issues from dup-shared directory offsets, fixed independent openat description; post-shared-reader refactor21/2 focused +144/8 related GREEN. |
| Task2 review fix |25ed0c1; stricter admission moved before semantic inspection, fresh work/package/Data/manifest path binding added. Old-order oversized prepared-file RED;23/2 scoped +87/1 backup GREEN. Both findings independently approved. |
| Task3 coordinator |968754c, report3d01de6; detailed RED/runtime fixes and160/9 evidence above. Independent review approved. |
| Final whole-unit fix |cdd7a5e; original native enumeration produced7 failed expectations in27/2 runtime RED:103 names instead of<=18,102 root names instead of<=3, wrong depth/manifest error precedence. Native-only streaming budget/depth admission fixed this.27/2 focused then115/3 affected and165/9 related GREEN; final scoped review approved both resource fix and type comments. |

Detailed preserved task reports and review packages live in .superpowers/sdd/2026-09-09-legacy-import-source-observation/. Those are recovery notes, not additional production code. Final fix logs are under /tmp/knitnote-legacy-final-iHUGGh/: fix-red-api.log, fix-red-behavior.log, fix-green-focused.log, fix-green-affected.log, fix-green-related.log. Behavioral RED SHA2567781722848d22983f5001c33b45938a01661454d62a8b50919b04ccc9f6002db; related GREEN SHA256a0e1dfb3acf70e63b48983812bc2c25d658b992aa17251d5354be094985dd1e4.

### Inventory bounds added by final review

Native-only file inventory retains the1,000,000-byte projection budget. Framing is40 bytes (32-byte tag+8-byte count); each file48+UTF8 path bytes. Directory inventory has a separate4,000,000-byte budget with48+path bytes per entry. Maximum Data-relative directory depth4 is checked before child open, derived from deepest supported shape Patterns/<project>/Markup/<pattern>. Package root streams exactly the two allowed names, with early rejection of extras. Real fixtures cover3,500 zero-byte files and14,000 empty directories, reduced-budget visit counts, exact104-byte single-archive inventory and forbidden cap raising. Ordinary portable enumeration and200MB general-file cap remain unchanged. Future deeper supported layouts require explicit bound review.

### Rulings made under delegation, in decision order

1. Use actual service helper signatures/errors where illustrative plan snippets differ; wrong interpretation costs interface rework, never weaker checks.
2. Review the complete approved unit from99ece4b, not all earlier branch history; earlier integration defects remain a separate release-review risk.
3. Preserve this plan's ledger/reviews and existing worktree; cost is small local disk usage, no record destruction.
4. Continue after proving the baseline socket failure is sandbox-specific, and use formal escalation for relevant tests; if diagnosis were wrong, final regressions could reveal a baseline defect. Initial122-test run is not called green.
5. Perform native bounded admission before full inspectPackage despite the plan's original ordering; cost is an extra metadata pass, required by the stronger pre-read limit.
6. Adopt native file1MB/directory4MB/depth4 streaming bounds; cost is bounded metadata memory and rejection of excessive empty directories, plus future schema-bound maintenance. Ordinary backup compatibility is preserved.

### Final audit / remaining boundaries

Root git diff --check passed. Root diff against99ece4b for KnitNote, KnitNoteWatch, KnitNoteShare, KnitNote.xcodeproj, Package.swift, existing consent model and policy returned0/no output. New-entry reference scan in those production directories returned no matches. Version remains1.7.0(13); platform floors unchanged. Six source/test files form this unit. Final service SHA25615136309f4241fd393ee514bf8cf8c3af060d2a85c9996943a5f8ce453d99357; projection3389b7b4bd30c52a0fab18aa54840243ad2467c895c873cc045fd229208a0934; source tests a6b4c8b5c45f7639597e9fcf250b54bcece7e2a99f42cfa8657888485f9991a1. Coordinator/test hashes remain as recorded above.

Optional exact new-worker-after-drain-before-old-continuation test remains deferred; ID/generation guards were reviewed as correct. Existing clean-build deprecation remains deferred; no warning suppression. No known Critical/Important finding remains for this isolated unit.

Keep branch docs/cross-device-sync-design and its worktree as-is. No merge, push, signing, upload, submission, production activation, automation or cleanup. Existing unrelated untracked reports and protected absent-source scratch remain untouched. Next distinct work is the persistent import transaction/final producer freeze/native installation contract, followed by remaining source authority/Watch/zone/App integration and real-device/cloud/release gates; none is claimed complete by these165 tests.
