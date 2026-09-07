# App session producer stop — verified local subplan

**Latest: all three local tasks, whole-current-plan review and the single final fix rereview are complete. Frozen candidate `4710efc96fa70b9f8705b04c6141182b0519714d` passed full Core, no-host and unsigned macOS/iOS validation.** Read the final frozen-validation section for current status. Earlier pending/uncommitted statements below are retained historical snapshots, not current blockers. This completes only the local producer-stop subplan, not full App account integration or release acceptance.

Cutoff: 2026-09-07 08:00 Asia/Taipei. This is NOT a completed-plan verification or release approval.

## Candidate and scope

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
- Branch: `docs/cross-device-sync-design`.
- Plan BASE: `fb8c372a84994c17aa3c81aa70b06d5982556560`.
- HEAD at cutoff: `ad2983e77899e23d9b85503be2092a2e499433e0` (plan amendments).
- Task 1 approved code commit: `c9abf8f4a14da3e170f55bc940e04f6d1fbb8236`.
- Project settings read back as version 1.7.0, build 13. This does not establish an archive identity or platform compilation.
- Task 2 fix1 remains six uncommitted source/test/PBX files; its scoped rereview was accepted before cutoff and may safely finish. Task 3 was not dispatched. No new implementation or test work starts after cutoff.

## Verified partial results

Task 1 passed independent review after two fix rounds and was committed. It adds irreversible inbox stop/drain, retains retired notice tasks through termination, and preserves later presenter actions during synchronous reentry.

Task 2 implements Watch callback admission/serial/timer lifetime tracking and explicit transport injection. Its initial review found three Important evidence/teardown gaps and a related fixture cycle. Fix1 is implemented; tests alone do not establish review approval.

Controller read back all six fix1 SHA-256 identities, raw final result tails and log hashes, `git diff --check`, and PBX plist lint. Results:

| Evidence | Result | SHA-256 |
| --- | --- | --- |
| `/tmp/app-session-producer-task1-task2-fix1-green-20260907-02.log` | 26 tests / 2 suites, exit 0, 3.439 s | `eb56000551b5282182fdb5a14acfb9b8f122e102adc84f0b278f7a11b549cbff` |
| `/tmp/app-session-producer-task2-fix1-core-affected-20260907-01.log` | 277 tests / 34 suites, exit 0, 11.945 s | `e1ee60b717ebde2e452c9aa47502ab6b6ae94c05f069718d32b232b095a629e5` |
| `/tmp/app-session-producer-task2-fix1-retired-mutation-red-20260907-01.log` | Recorded deliberate mutation failure, exit 1 | `79ab6e860e369431796b9447b260aa79239c30deaf8f5c660c8d21caf38bf16f` |
| `/tmp/app-session-producer-task2-fix1-foreign-duplicate-mutation-red-20260907-01.log` | Recorded deliberate mutation failure, exit 1 | `ad2428e2d00e76a2fd6916db845b6965b4e801a7dc11c50cb461d3f2d2890cf3` |

Actual-source harness: `/tmp/knitnote-app-producer-nsUcPJ`; source/test entries link to this checkout. No App host or live cloud factory ran. An exact scoped process scan after cutoff showed only the scan itself, not a remaining harness/runner process. Detailed API RED, compile errors, intermediate attempts, cleanup limitations and Task 1 evidence remain in the preserved SDD reports; do not relabel intermediate attempts as final passes.

### Uncommitted Task 2 identities

| File | SHA-256 |
| --- | --- |
| `KnitNote.xcodeproj/project.pbxproj` | `c5a14e62b005d1f51dc15f7dfa6f05373a41720498553a9972a5dbd36d18964c` |
| `KnitNote/App/KnitNoteApp.swift` | `651b703bba05c2ecad150e4c9d4a0109c0d1e897ad9b18b136e69a8fb9dbf5bb` |
| `KnitNote/App/AppSessionCallbackGate.swift` | `0e4f979b6ad30ba72f2d063375058d4d849074bac8f8e9ba555be866200f1d12` |
| `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift` | `fc865ee15a57f01c0d52ec112db1785431c359b5ae8a4cb7a78c004f07342edc` |
| `Tests/KnitNoteAppTests/AppSessionProducerFixtures.swift` | `f17f37b4b1710a4d75db86587cb92e837b4e2d3e4eeb91e26284850b9b17c707` |
| `Tests/KnitNoteAppTests/PhoneWatchSessionProducerTests.swift` | `2df523e1d9052c6c63191156bb663436c2166e062e4dc28fe7a2dcdb60445b08` |

## Next safe continuation and release gates

1. Read `.superpowers/sdd/2026-09-07-app-session-producer-stop/progress.md` first, then the final scoped Task 2 fix1 review. Do not redo completed Task 1 or the previous background-drain plan. Resolve any remaining review findings before a Task 2 commit.
2. Execute Task 3: fixed producer/store group, mixed A/B isolation and separate actual native-store pending-copy drain test. Review independently.
3. Complete whole-current-plan review, then freeze the exact candidate for full Core, actual-source no-host and unsigned macOS/iOS validation. None of those full frozen commands ran on this new partial candidate.
4. Finish App startup/account-session ownership integration and the remaining real CloudKit/cross-device/account-switch acceptance. Then verify purchase/localization/store metadata and bind the exact commit, archive, version/build and final submission authorization.

Previous background-drain candidate `81305f62af3e0eedc34de31a9097330ae05b3cc0` passed 2520 Core tests and unsigned platform builds; those older results are NOT this partial candidate's full validation. Its disclosed pre-existing CGPDF diagnostic is not a pristine-output claim.

No merge, push, signing, install, upload, submission or production-data cleanup occurred in this overnight continuation. Live App Store Connect state was not read back here. Existing heartbeat `knitnote-1-7-0-9-7` was updated and read back PAUSED at cutoff; no replacement automation was created. Evidence/harness/SDD workspace retained intentionally. No automatic continuation is promised after this pause.

## Final scoped-review outcome

The accepted review completed after cutoff: **needs fixes**, not approved. See preserved `.superpowers/sdd/2026-09-07-app-session-producer-stop/task-2-fix1-review.md` for exact evidence.

- Original retired-timer and foreign/duplicate assertions are addressed; normal thrown-error/cancellation teardown and weak hook captures are addressed.
- Important remaining: the retired-token mutation deliberately breaks the drain's ownership. Awaiting that defective drain plus its state observer does not independently join the discarded retired Task. The implementer's mutation-cleanup termination claim is unsupported, even though its intended failing assertion is recorded. A later empty process scan cannot retroactively establish correct deletion ordering.
- Important introduced: injecting the mutable `AppSessionCallbackGate` into the coordinator exceeds the read-only observation-seam ruling. Keep a freshly constructed private gate and accept observation only. The current production caller uses the default; no current shipping-call-site failure was established.

Task 2 stays uncommitted and incomplete. Next authorized development continuation should perform fix round 2 addressing exactly these findings, retain independent ownership for mutation cleanup, rerun covering evidence and request a scoped rereview. No such fix was dispatched after cutoff. Task 3 and full validation remain pending. This handoff report is also saved locally and uncommitted.

## Interactive continuation — Task 2 completed

After the user approved the proposed next step, the original implementer completed fix round 2 and a fresh independent reviewer verified both remaining findings. The overnight automation stayed paused. Review: `.superpowers/sdd/2026-09-07-app-session-producer-stop/task-2-fix2-review.md`; detailed execution evidence: `task-2-report.md` in that same preserved workspace.

- Coordinator constructs its own fresh private gate and accepts only immutable-state observations; no external mutable owner injection.
- The new deliberate retired-token mutant retains the exact retired Task handles independently, then awaits their Task values before fixture deletion. Reviewer reconstructed the exact mutant and matched SHA-256 `707cd35f684709a88cdf8f7fdd19758482a2206d0fefb5521a3ff1b6086a5b31` / blob `8143d835b62746b48e113ce122a4131dbb9b8fe3`. It still produced the intended 1-versus-2-token failure. The fallback was removed from final production source. Evidence is inspected joins plus completed failure path, not a separate per-Task runtime trace.
- Final actual-source combined tests: 26 tests / 2 suites, exit 0, 4.960 s; `/tmp/app-session-producer-task1-task2-fix2-green-20260907-01.log`, SHA-256 `2d3d4cd6ab709d49e6036d711a94e1de5ed296ce321ffd7a5475f5c914435335`.
- Final affected Core: 277 tests / 34 suites, exit 0, 12.963 s; `/tmp/app-session-producer-task2-fix2-core-affected-20260907-01.log`, SHA-256 `aa9ca9b24ba6a3dc03d7dd1fee81afc65e56a54db46994cc0b41417fd57f2acc`.
- Safe mutation RED: `/tmp/app-session-producer-task2-fix2-retired-safe-mutation-red-20260907-01.log`, exit 1, 6.244 s, SHA-256 `bce044771ff2808b411f93c582435a1afb77f5783eb3fe92cb8990a1861e0464`.
- Controller verified log hashes/results, six final source identities, actual harness links, fresh diff check and PBX lint. Commit `9900bc82b008891d37575901b70fbc3c7a78549e` contains exactly the six reviewed Task 2 files; committed blobs match final report.

Final committed identities (supersede the earlier uncommitted table):

| File | Git blob |
| --- | --- |
| `KnitNote.xcodeproj/project.pbxproj` | `bdaa29c72c0d004e3603f1aff3be093c86e845c6` |
| `KnitNote/App/KnitNoteApp.swift` | `be517188b36c4ad3b8efcf0948cf37369854f59c` |
| `KnitNote/App/AppSessionCallbackGate.swift` | `f6838838c4babd4d6aa52258f7cdb7e9792758b9` |
| `KnitNote/WatchSync/PhoneWatchSyncCoordinator.swift` | `e6ddb1b440a7c9b2efb6e19b8f94b0ec5bae88f3` |
| `Tests/KnitNoteAppTests/AppSessionProducerFixtures.swift` | `a2eff485371e634bf952f2e68733851dd99abbb3` |
| `Tests/KnitNoteAppTests/PhoneWatchSessionProducerTests.swift` | `eeaa182d84589b0828f670c92ae325342a10631e` |

Next: Task 3 fixed producer/store group with mixed-session and actual native-store pending-work tests. Whole-plan review/frozen full Core/no-host/platform validation, App account ownership integration, real cloud/device acceptance and exact release-candidate gates remain pending. Version is still 1.7.0 (13). No push, upload, submission, signing, install or production-data cleanup occurred. Existing rulings were followed; no new architectural ruling was needed in fix2.

## Interactive continuation — Task 3 implementer evidence

Task 3 is implemented locally at unchanged HEAD `1c1a426ee634d8b18d0add21b7e99fbdb2a28cb4`, pending independent review and controller commit. This section appends evidence; it does not replace or revise the historical Task 1/2 record above.

- Added a fixed-reference `AppSessionProducerGroup` with the approved synchronous stop order: irreversible group state, fixed-store write revocation, then every fixed producer stop. Its drain rejects open use, joins every producer, delegates to the store aggregate background-write drain, and reports caller cancellation only at the specified entry/final checks.
- Added 7 actual-source group tests. Mixed A/B acceptance combines actual `PatternInboxDriver`/processor, actual Watch coordinator, transport spy and independent real JSON stores; it proves immediate A revocation, no late A UI/Watch/disk output, Watch completion while inbox keeps the group pending, and unchanged/writable B. A separate empty-producer native import proves the store drain is necessary with a blocked real `PatternFileService` copy, retained source bytes and no publication.
- API RED: `/tmp/app-session-producer-task3-api-red-20260907-03.log`, 80 lines, exit 1, 1.377s, SHA-256 `578b030ab2ecb2885a5bfe73fa7d50c181b4f6c9ec7eba9c522c69081e444ad6`; expected missing group type only.
- Compiling behavior RED: `/tmp/app-session-producer-task3-behavior-red-20260907-02.log`, 50 lines, 7 tests/1 suite with 13 expected issues, exit 1, 3.261s, SHA-256 `960d773ca2af16a8938c903f2fc8de7c84270e9be3526c089fb7fa90514a85dd`.
- Safe store-wait omission RED: `/tmp/app-session-producer-task3-store-drain-mutation-red-20260907-01.log`, 26 lines, 1 test/1 suite with the single required early-completion issue, exit 1, 3.793s, SHA-256 `a1fad3a1bf2c46d0dbd34090d2c1644f6a847abc52ca1be8f7886f1c510a62fe`. The copy was released and the independent import Task joined before deletion; final production source was restored.
- Final entire actual-source no-host package: `/tmp/app-session-producer-task3-entire-harness-green-20260907-01.log`, 93 lines, 33 tests/3 suites, exit 0, 3.554s, SHA-256 `6a78020c81165a43e2e3026da9580bf2672bab7f51fc37bc6af8266d89456485`.
- Final affected Core selector: `/tmp/app-session-producer-task3-core-affected-20260907-01.log`, 834 lines, 336 tests/41 suites, exit 0, 15.047s, SHA-256 `a67ea54f971aae2f6734071766249854366eeae2ba9395bfc24dd09decade9e3`.
- Final SHA-256 identities: group `7e5a5365512820de6267b91045808f020f3dfb288941b3b6d772408e247a7308`; group tests `1bad2dfa6864f3bcd27cd83b1c16bf32d0b9fcbf58850e808a88af89cf4b235a`; PBX `58c77511468f8807eba90c59e1b5582e40254faf9ffee0fb468935a7e0c403d0`. PBX lint and diff check passed. Harness `/tmp/knitnote-app-producer-nsUcPJ` retains exact source/test symlinks; no scoped fixture roots remain.
- Native temporary directories are not asserted byte-identical because real import may create then roll back native directories. Authority assertions are the store's unpublished pattern state, retained original source bytes and byte-identical independent B. Cleanup runs only after released/joined native work.

Task 3 tests do not establish whole-App freeze, account readiness, durable health, cleanup authority, real cross-device acceptance or release readiness. Independent review/controller commit and final whole-plan/frozen full Core/no-host/platform validation remain pending. App owner/account lifecycle integration and live cloud/device acceptance remain later work. No automation was restarted and no push, sign, install, upload or submission occurred.

## Consolidated final-review fix wave

The whole-plan review at HEAD `d97cb8db3aba7e94532bad4dcf5e9ae95ce77f19` found one Important test-cleanup gap and two Minor scope/proof items. This append records their local fix and implementer evidence; controller scoped rereview, commit and final frozen validation remain pending.

- Mixed-group fixture cleanup now runs its entire release/stop/join/delete sequence inside a fresh retained MainActor Task. The operation result is preserved separately. Inbox, Watch and group/store drains and root deletion are throwing operations, so a failed join cannot be reported as completion or reach deletion.
- A cancelled-fixture-caller regression admits actual inbox work, cancels the fixture owner, and observes the actual inbox drain result while the root still exists. On the old helper it deterministically saw `CancellationError` and failed 1 test / 1 suite with one issue. Its separate fresh MainActor safety task joined the real inbox work before the old helper deleted the root. Final source passes without that fallback.
- The unrelated empty MainActor Task fence was removed from the stopped-entry inbox test. No stronger negative-completion claim, deliberate mutant or production seam was added.
- The design now limits no-new-activation/send/reply and drain claims to coordinator-initiated or coordinator-accepted work. `PhoneWatchSession` native callback/FIFO/reactivation Tasks are not stopped or joined by the coordinator; a future App owner needs a separate local native-adapter gate, distinct from remote Watch/account/wire gates. No native adapter production work occurred.

Evidence:

| Evidence | Result | SHA-256 |
| --- | --- | --- |
| `/tmp/app-session-producer-final-fix-cancelled-fixture-red-20260907-01.log` | old-helper RED: 1 test / 1 suite, 1 issue, exit 1, 4.87s, 26 lines | `4249afbc1273ad5665a7b6aaded8dfa8ec46c82ab65af62412cf424535326917` |
| `/tmp/app-session-producer-final-fix-cancelled-fixture-green-20260907-02.log` | regression GREEN: 1 test / 1 suite, exit 0, 3.105s, 25 lines | `5f7575f4f7a3fdf2a58d647e24fbf1bde1518abd66b74c506ca1392060ae9547` |
| `/tmp/app-session-producer-final-fix-focused-green-20260907-01.log` | combined affected App: 19 tests / 2 suites, exit 0, 4.023s, 66 lines | `51cd90c4b0af6c3d0c6dae87c5ce0b573fa6bacf75f8ed22a6d44ef58d8e51fb` |
| `/tmp/app-session-producer-final-fix-entire-harness-green-20260907-01.log` | entire actual-source harness: 34 tests / 3 suites, exit 0, 0.818s, 90 lines | `c400e50b0c29f8a0caa487c7a4d2b708acee74675a38039c14f3531f42463f15` |
| `/tmp/app-session-producer-final-fix-core-affected-20260907-01.log` | affected Core: 336 tests / 41 suites, exit 0, 13.758s, 833 lines | `a9f6efa86089d80ddbcefea65dcb6a744aa54d42618f691e0725a13615d94cf8` |

Final pre-report source identities: group test SHA-256 `c8569315a3fb72fd2ae817058db4b06c5fd94aec6da5a4d79e01baad18f2c458` / blob `8b22d433c0a7417697840ecb339a2ff26083727d`; inbox test `a305664b5f275817fdb97c7ec5e95696ee4daf5aeba5f86997ca858cf67109df` / `afc063f0f49b91bf57f993fef05900a5e069a193`; spec `21c8149d943f790dfc60360bcabfc26c93c62c05ce1b0140b50c3c99c2b0d1b0` / `4fc33a5cbabfd83df4ad8bb4682b382b3c027eea`; unchanged production group `7e5a5365512820de6267b91045808f020f3dfb288941b3b6d772408e247a7308` / `c665f6d4255b598b01e2ad09b3b2fe64d65476db`; unchanged PBX `58c77511468f8807eba90c59e1b5582e40254faf9ffee0fb468935a7e0c403d0` / `cebc700c6197bcd794e658272f4cab24ab4dcc35`.

The final GREEN logs contain no warning/error/issue/failure diagnostics. `git diff --check` and PBX lint passed, and no scoped fixture roots remained. Harness `/tmp/knitnote-app-producer-nsUcPJ`, caches `/tmp/knitnote-app-producer-cache-nsUcPJ` and runner `/tmp/task4-run-bounded.py` remain preserved. Detailed commands, excluded compile-only attempt, all finding dispositions, self-review and cannot-verify boundaries are in `.superpowers/sdd/2026-09-07-app-session-producer-stop/final-fix-report.md`.

No source mutant was used in this fix wave; the old helper supplied the behavioral RED. This evidence does not establish final whole-plan approval, complete Core or platform validation, native adapter shutdown, App owner integration, live cloud/device/account-switch acceptance, release identity or release authorization. No automation was restarted and no commit, push, signing, install, upload or submission occurred.

## Final frozen validation — controller execution

Candidate: `4710efc96fa70b9f8705b04c6141182b0519714d`; branch `docs/cross-device-sync-design`; version 1.7.0 (13). Task 3 was committed as `d97cb8db3aba7e94532bad4dcf5e9ae95ce77f19`; the final test/documentation fix was committed as the candidate above. Final review found one Important and two Minor issues; all were addressed and the scoped rereview passed (`final-review.md` and `final-fix-review.md` in the preserved SDD workspace). No new architectural ruling was required in the final fix.

All four commands were run serially by the controller. HEAD and all tracked content remained unchanged from before the first command until after the final native process ended. Each command had a bounded outer watchdog and a unique no-clobber raw log. All exited 0 without timeout. Afterward, the working tree was clean and HEAD/trees matched the freeze; an exact scoped process scan found only the scan itself, not remaining validation processes. This report update happened only after that readback.

| Check and raw log | Final result | SHA-256 |
| --- | --- | --- |
| Full Core: `/tmp/app-session-producer-final-core-20260907-01.log` | 2520 tests / 186 suites, exit 0, 1407.618 s | `b14c7df4a5a08818d0d597e265e5de7f3e4455ce2d3c93d9984137defbd8d393` |
| Full no-host: `/tmp/app-session-producer-final-nohost-20260907-01.log` | 34 tests / 3 suites, exit 0, 1.927 s | `85fbe4e083cb5e9615a36a86ce3e839af3d89bec369a7b188a9ca3cfc86962e3` |
| macOS: `/tmp/app-session-producer-final-macos-20260907-01.log` | TEST BUILD SUCCEEDED, exit 0, 45.597 s | `9a9e7fca1d1bf3f55fcc3072049ab8be17902b7aecb3002e1c8b4bf68cb3061d` |
| iOS: `/tmp/app-session-producer-final-ios-20260907-01.log` | BUILD SUCCEEDED, exit 0, 45.212 s | `5dc8d628156f457679a97c9dc0ae5b826ec3b1a016aa24443f972e1cf73ca411` |

Commands (full Core from the worktree, no-host from `/tmp/knitnote-app-producer-nsUcPJ`, builds from the worktree):

```text
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination platform=macOS,arch=arm64 -derivedDataPath /tmp/app-session-producer-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination generic/platform=iOS -derivedDataPath /tmp/app-session-producer-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Swift commands used `SWIFTPM_MODULECACHE_OVERRIDE=/tmp/knitnote-app-producer-cache-nsUcPJ/swiftpm` and `CLANG_MODULE_CACHE_PATH=/tmp/knitnote-app-producer-cache-nsUcPJ/clang`. Harness Package SHA remains `60e88476a87fc23d4de02399f83d65276c8000c7a1756641716facbadea5a44f`; all 15 source/test links resolve to this checkout. Xcode was `/Applications/Xcode.app/Contents/Developer`, Swift 6.3.3. Builds compile targets only; no App host, physical device, live service, signing, installation or upload ran.

### Frozen tree identities

| Candidate path | Git tree/blob |
| --- | --- |
| `Sources` | `e95550a541be26609812713062a5dfe0fc5dd166` |
| `KnitNote/App` | `0ff6f9c049df7ef6a8c911027ae49ef6d88182d6` |
| `KnitNote/Patterns` | `4afafac064a09a7b7fabdfe1f20a38507cffe76c` |
| `KnitNote/WatchSync` | `083f032a092a118a3902aaa097c2bd474dbae44b` |
| `Tests` | `145b3cf833b8c3c152cfd43df7a64ae6ba3d46d8` |
| `KnitNote.xcodeproj/project.pbxproj` | `cebc700c6197bcd794e658272f4cab24ab4dcc35` |

### Diagnostics, not a pristine-output claim

- Full Core has no recorded Swift Testing failure. It prints three `release archive provenance inventory mismatch` messages in deliberate rejection cases, plus chained Python FileNotFoundError/ValueError tracebacks for four deliberately missing archive/Info.plist fixtures. `ReleaseAuditLocalizationTests.swift:1194` explicitly expects those manifest commands to return nonzero, and the enclosing tests pass. These diagnostics are retained, not suppressed or called compiler failures.
- The prior CGPDF diagnostic is historical; it was not observed in this frozen full-Core log. This is not a claim that its underlying cause was fixed.
- macOS and iOS each print three App Intents metadata-extraction warnings because those targets have no AppIntents.framework dependency; the same warning exists in the prior platform baseline. Both builds succeed; no compiler error was recorded. Full no-host output has no warning/error/recorded-issue diagnostic.

### Remaining integration and release gates

The next subplan is the App-owned session/generation wiring: hide and invalidate old UI/entry points, own the fixed producer/store group, and coordinate account lifecycle without rebinding old work. Native `PhoneWatchSession` callback/FIFO/reactivation work still needs its own local admission/stop/drain boundary. That is distinct from remote Watch clearing/account-wire evidence. Live CloudKit, screenshot/live-factory isolation, physical cross-device/account-switch acceptance, purchase/localization/store metadata, exact signed archive/submission identity and release authorization remain open. None is inferred from this local subplan's pass.

Keep this branch, worktree, SDD reports, raw logs and harness in place. The existing overnight automation remains paused. No merge, push, signing, install, upload, submission or production-data cleanup occurred. Live App Store Connect state was not checked. The later docs-only commit preserves this evidence and must retain the frozen code/test/PBX trees above.

### Rulings retained in decision order

1. Controller-owned frozen full validation after reviews, implementer focused checks only — cost: cross-range failures may surface later.
2. Review actual precommit diffs and commit only approved files — cost: extra covering checks after fixes.
3. Preserve SDD workspace and evidence — cost: disk usage.
4. Final review covers the current plan plus concrete callers, not all historical branch changes — cost: separate pre-release historical review remains necessary.
5. Add an independent actual native-store pending-work test — cost: fixture complexity and boundary-specific validation.
6. Retain all retired inbox notice tasks and handle synchronous reentry, allowing only a narrow production-equivalent delay seam — cost: internal ownership and regression-test complexity.
7. Track all three Watch timer lifetimes through the existing gate and test transport reentry — cost: broader gate responsibility and controlled fixtures.
8. Exercise expiry through actual entitlement logic with in-memory purchase/trial inputs — cost: fixture maintenance.
9. Permit minimal presenter mutation/publication bookkeeping to preserve newer user actions and history — cost: reentry bookkeeping and regression coverage.
10. Make gate async wait MainActor while synchronous admission methods remain thread-safe — cost: a future non-UI waiter needs an actor hop.
11. Permit immutable/read-only lifecycle observations and require cancellation-isolated release/join-before-delete cleanup, including RED paths — cost: observation/test-fixture maintenance; no mutable authority or Task-list seam.
