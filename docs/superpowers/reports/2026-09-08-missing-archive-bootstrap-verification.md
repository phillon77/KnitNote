# Missing-archive bootstrap verification

**Core preparation subplan complete. Full missing-archive account sealing, App bootstrap and release remain incomplete.**

Version1.7.0(13), branch docs/cross-device-sync-design; baseline196404a, frozen source08c7475c9a433c0db28bfb2da83d078d65499fd4. Spec2462593, plan5955e8f. Current specification includes the explicit terminal-reader/full-seal scope clarification from the reproduced integration failure.

## Delivered and reviewed

Explicit prepareReconstruction uses complete caller-supplied remote records and required frozen pending snapshot without inventing an original archive. Typed source proof/custom codecs preserve v1 archive wire shapes and issue strict v2 absence/tree proofs. Ordinary checks remain; both routes share staging, merge, final validation, install/commit/rollback and handoff. Pending-only graph/media, exact FIFO/source bytes, every failure boundary, restart, v1/v2 tampering, actual canonical activation/edit and day-29 deletion restoration are tested.

Task report .superpowers/sdd/2026-09-08-missing-archive-bootstrap/task-1-report.md preserves all RED/failed/GREEN commands and hashes. Final scoped141/6 passed, log SHA d2b27060b0a05b32a0328208d82f18227c2ce1d5645720fe7e38733e6a270841. /tmp/missing-archive-task-review-20260908.md approved spec+quality. /tmp/missing-archive-final-review-20260908.md approved frozen local validation with no new Core blocker, retaining Important full-seal, canonical temporary-routing Minor1 and live-helper identity gates.

## Frozen validation

Session82508 completed/reaped exit0. Five commands ran serially, next only on exit0. No source changes during/after tests. No live factories, App launch, Keychain, devices, signing, cloud, push/upload/submission or schema action.

| Check | Final result | Log SHA256 |
| --- | --- | --- |
| Full Core | 2545/186,1410.617s; exit0,1412.6s command | f298f922620c1311bc437584a98b3b5f404fc3a9b7aa47a8168279f8deffd781 |
| Actual-source App | 241/12,51.697s; exit0,66.197s command | 570e511787170c5d6773a091a0485161da21f4fc035a8b2a62ae76f8cc1e34a8 |
| Actual-source root/Watch | 73/7,0.732s; exit0,10.962s command | 33665f32727376c40c9b8cc2c4142523a22c80778db4b16071b3b8bd0ce2149c |
| macOS unsigned build-for-testing | TEST BUILD SUCCEEDED; exit0,50.209s | ffa7df8b7e36a1c025382838d6788a381282b72cde71f1be92e551c70e96ffba |
| iOS unsigned build | BUILD SUCCEEDED; exit0,43.604s | ca6cf21782fa379c603159db42f24ca2d67f47a817f68ebf012fce16cf6a7690 |

Logs /tmp/missing-archive-bootstrap-frozen-01-{core,app,root,macos,ios}.log; derived /tmp/missing-archive-bootstrap-{macos,ios}-01-derived. One live-development App test intentionally skipped. Three AppIntents no-framework metadata warnings per platform. No errors, recorded issues or timeout. build-for-testing is compilation, not hosted/device acceptance.

Exact serial commands preserved in this plan's .superpowers/sdd/2026-09-08-missing-archive-bootstrap/frozen-validation-notes.md. Core: env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION plus bounded3600 arch -arm64 swift test --no-parallel. App: explicit KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0 and CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache, bounded900 swift test --disable-xctest --disable-sandbox with cache/config/security/package paths under /tmp/knitnote-account-domain-jnjVrd and --no-parallel. Root: explicit0, bounded900 arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel. Platform commands: bounded900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote, destinations platform=macOS,arch=arm64 (build-for-testing) and generic/platform=iOS (build), respective fresh derived paths above, CODE_SIGNING_ALLOWED=NO. Wrapper python3 /tmp/task4-run-bounded.py, outputs redirected separately, chained with &&. Core unsets override because production release audit rejects every KNITNOTE_ override.

Verified unchanged trees: Sources b4718144480ae30670b3bc6f3433f82c1e5f7cb1; App78721554b1f8c32862824939dc7ec2e986fded90; Tests4dfa8d9ef4b8c6544a7f02a784225cbee10ffa08; PBX534acbdd575b5e8093a1a277f519645149b66352. Source/test/PBX/project.yml diff empty; shipping targets1.7.0(13).

Harness SHA256: accountPackage be651083b0427f1d2067dbc2b4fe0e6f1248d46211ff0d125baf7ef7d3c3f04b; source manifest537c8219ca4bab4b5df11b49dc2b8a6ff3a9dc289e9b0673cf1c8b7b805f2fe4; rootPackage9d80d3ca53ffbb96203f5cb590a54dac7a095a102d5bba3148afa4eb828e89eb; runnerc9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b.

## Rulings made and costs if wrong

1. Extend existing transaction with explicit missing-source proof, not fake archive/separate installer. Cost: source-evidence migration/recovery rework; v1/v2 and all boundary tests required.
2. Optional sourceArchiveFingerprint plus typed sourceProof: absence has no real archive digest and no external repository callers were found. Cost: API adaptation; full App/platform and legacy wire checks now passed.
3. Core route precedes App transport/ACK integration as independently testable prerequisite. Cost: later exact-input commitment may require evidence evolution; no ACK/readiness follows from this work.
4. Rolled-back v2 uses actual terminal validator under storage inventory; committed v2 uses full seal/cleanup. Independent Inventory archive-required format is not weakened. Cost: full missing-archive switching remains unavailable until separate source authority work. Genuine full-seal failure is preserved, not silently replaced with success.

## Failures preserved

Initial cache failures were environment-only; API compile RED distinguished from behavior. Intermediate test macro/throw/private-property compilation failures fixed/retained. Behavioral mutation removed only absence consistency checks: contradictory archive/file-directory originals installed and four assertions failed; restored guards passed. Real rolled-back v2 full account seal failed unsafeBinding; checked-in regression preserves that limit and pending bytes. No timeout increased, Inventory guard removed or failure hidden by cleanup. Task report has exact logs/hashes.

## Immediate next work

- Load-bearing absent-source recovery/sealing authority: Inventory.capture/decode requires archive. Cover valid v2 rollback and restored pending cancelled before first prepare (no v2 manifest). App currently consumes replayComplete intent before installation; durable provenance must precede consumption. ENOENT, corrupt/lost data or cached identity is not cleanup authority. See this SDD's next-recovery-authority-notes.md.
- Actual full-fetch/consumption/ACK: /tmp/remote-fetch-authority-design-20260908.md proposes isolated manual engine namespace, durable active selection, exact Core input commitment/retirement and one stream owner. Resolve fixed-path recovery ownership, nonexistent-zone authority and repeated-version ordering. Incoming128batches/16MiB, journal64MiB, canonical/batch/file100,000,000-byte caps unchanged. Completed maps/design must not be redispatched.
- Retain four canonical temporary-routing cases, live helper queried account/container, shipping/native notifications, product UI/localization, backup/Watch, real cloud/devices, schema/privacy/store and exact-candidate release authorization. No push, merge, upload or submission performed. Preserve worktrees/ledgers/evidence.
