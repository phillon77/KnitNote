# Native Watch session stop — verified local subplan

Completed 2026-09-07, before the delegated 19:00 Asia/Taipei deadline. This completes the approved native phone Watch adapter stop/drain subplan only. It is not full cross-device sync, App-owner integration, physical acceptance, or release approval.

## Candidate and review

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`.
- Approved spec: `docs/superpowers/specs/2026-09-07-native-watch-session-stop-design.md`.
- Plan: `docs/superpowers/plans/2026-09-07-native-watch-session-stop.md`.
- Subplan baseline: `5b0dd6c`; plan commit `5c1d99e98531a13485d216d3d3985630acfd5422`.
- Implemented and frozen candidate: `41ff8a21e9d60cf3b9ab7dbf2a05c05a11b1831d`.
- Task review: `/tmp/native-watch-task-review.md`, spec compliant / quality approved, no Critical or Important findings. SHA-256 `fb554ab46de07af52c9fa17f3fab8ecb785f3b00da02ad6950408fcff5b3b32c`.
- Whole-subplan review: `/tmp/native-watch-final-review.md`, approved for frozen local verification, no Critical or Important findings. Range `5b0dd6c..41ff8a2`; SHA-256 `d948488041f190e59d4bde214656773e56acdd1ebdeb53aed4a7d6ccd86b6f48`.
- No review fix wave was needed. Both reviews inspected the native bridge and named unchanged gate/FIFO/coordinator boundaries; they did not duplicate test runs.

## Implemented behavior

The actual `PhoneWatchSession` is now platform-neutral with a thin iOS-only WCSession bridge and existing zero-argument iOS construction. Its private callback gate closes synchronously and irreversibly before callbacks are cleared and its owned delegate removed. It refuses new work after stop, joins locally accepted work, suppresses queued or retained old replies, preserves normal FIFO and one-shot completion, checks synchronous stop reentry, and cannot detach another adapter's delegate.

Native network transfers already started are not recalled. Drain tracks locally accepted work, not a remote reply that might never arrive. Coordinator work and native-adapter work remain separate producer lifetimes for the future owner to compose.

Only production file changed: `KnitNote/WatchSync/PhoneWatchSession.swift`. Added `Tests/KnitNoteAppTests/PhoneWatchNativeSessionLifecycleTests.swift`. No Core wire, Watch-side behavior, App owner, store, cloud activation, format, purchase, localization, limits or PBX changes. PBX readback remains version **1.7.0 (13)** and iOS 18/macOS 15/watchOS 11.

## Frozen validation

Controller ran all four serially, with the same clean candidate and no intervening source edits. Bounds use the inspected `/tmp/task4-run-bounded.py` subprocess-group runner. Swift/Xcode cache access used scoped sandbox escalation. No App host or native service was launched by the tests.

| Run | Result | Command elapsed | Log |
| --- | --- | --- | --- |
| Full Core | 2520 tests / 186 suites, exit 0 | 1349.480 s | `/tmp/native-watch-frozen-core-20260907.log` |
| Combined actual-source no-host | 50 tests / 4 suites, exit 0 | 10.357 s | `/tmp/native-watch-frozen-combined-20260907.log` |
| macOS unsigned build-for-testing | TEST BUILD SUCCEEDED, exit 0 | 43.580 s | `/tmp/native-watch-frozen-macos-20260907.log` |
| iOS unsigned build | BUILD SUCCEEDED, exit 0 | 4.404 s | `/tmp/native-watch-frozen-ios-20260907.log` |

Commands (Core and Xcode from worktree, combined Swift from harness):

```sh
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/native-watch-stop-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/native-watch-stop-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Log SHA-256, in table order:

```text
edc46d827dc5c6346f2d60caf52455619b1e5e8c6b0a67603259a626b5a7d2b7
f9804f552b0661cdeaf121196c6acbad59097ba01bf86d0598df5a599c99d878
4b2a96e5dd7989bb346f9a5ce4753ad03e243d753d5bc660fb98c0efb42403cc
54dc8568b5bc833c0e0665ebd176911c832f54e0e8b9bb1bdfb38cb5bb80011d
```

Diagnostics: Core deliberately emitted three provenance inventory mismatches and chained FileNotFoundError/ValueError tracebacks for four missing archive/Info.plist fixtures. Controller checked the enclosing passing tests and `ReleaseAuditLocalizationTests.swift:1194-1205`, which explicitly requires nonzero manifest results. No Swift test failures or compiler warnings were present; no CGPDF diagnostic appeared in this run. The combined log has no warnings/errors. macOS emitted three AppIntents metadata-extraction-skipped warnings. Frozen iOS incremental build emitted none; its earlier same-SHA full preflight compiled the adapter successfully in 43.818 s and emitted three such warnings (`/tmp/native-watch-ios-preflight.log`, SHA-256 `e4afa29930ab8c6295d73755ff93b4c337054a4f486932510fea0dbd6c597ce3`). These are qualified diagnostics, not a claim that every log is pristine.

## Harness and TDD provenance

New harness: `/tmp/knitnote-native-watch-voYax4`; manifest SHA-256 `6b46583bbc7b668071ea3c66598b3551f8e498b65558db3b36a8a9e79c29a2fe`. Swift 6, macOS 15, KnitNote source target and KnitNoteAppTests test target, Core resources processed. Every source/test is symlinked to this exact worktree; no production copies or App host.

Final inventory has 17 links:

- `Sources/KnitNote/Core` -> worktree `Sources/KnitNoteCore`.
- `Sources/KnitNote/App/` -> actual files AppSessionProducerLifecycle, AppSessionCallbackGate, AppSessionProducerGroup under `KnitNote/App`; PhoneWatchSession and PhoneWatchSyncCoordinator under `KnitNote/WatchSync`; PatternInboxProcessor and PatternBackupReminderPresenter under `KnitNote/Patterns`; EntitlementCoordinator, StoreKitPurchaseService, PurchaseService and KeychainTrialStore under `KnitNote/Entitlements` (all `.swift`).
- `Tests/KnitNoteAppTests/` -> actual PhoneWatchNativeSessionLifecycleTests, PhoneWatchSessionProducerTests, AppSessionProducerFixtures, AppSessionProducerGroupTests and PatternInboxProcessorSessionTests (all `.swift`).

This combines 16 new native tests and the existing 34 producer tests; it does not imply every Xcode App test was executed. macOS build-for-testing compiles its configured tests but does not run an App host.

Detailed test-name matrix, exact command outputs and cleanup proof are preserved in `.superpowers/sdd/2026-09-07-native-watch-session-stop/task-1-report.md`. Missing-type extraction RED is explicitly separate from a cache-permission failure and six actual runtime mutations: callback stopped guard, FIFO stopped guard, empty drain, synchronous reentry, retained reply, and stopped public APIs. Each mutation produced the intended expectation failures, then was restored. Broken-drain testing released and independently joined real admitted work before finishing; ordinary helper error cleanup was inspected, while outstanding-work cancellation was directly exercised. Intermediate warnings/failures are not final GREEN results.

## Frozen source identities

```text
Sources: e95550a541be26609812713062a5dfe0fc5dd166
KnitNote/App: 0ff6f9c049df7ef6a8c911027ae49ef6d88182d6
KnitNote/WatchSync: 0bf3bbf33b7283806dde04c4f9fd9058b4e76b4d
Tests: bc4ca3577e118c9006a8df82a69d9d37f5693afb
KnitNote.xcodeproj/project.pbxproj: cebc700c6197bcd794e658272f4cab24ab4dcc35
```

Final evidence commit is documentation-only and must preserve these trees. All validation sessions completed with exit 0. Local branch, harness and SDD evidence are retained; no deletion is required.

## Decisions made under delegation

1. One cohesive adapter implementation task with separate controller validation: preserves the shared stop/drain invariant. Cost if wrong: larger review/fix unit.
2. Review this subplan from `5b0dd6c`, not the ancient feature ancestor: previous producer work already verified. Cost if wrong: unchanged integration risks require focused cross-boundary review and combined tests; both were performed.
3. Preserve evidence workspace rather than delete it: supports durable handoff. Cost if wrong: small retained scratch files.
4. Document nonblocking AppIntents metadata warnings instead of adding unused dependencies: build succeeds and review found no AppIntents declarations. Cost if wrong: a future intentional AppIntents feature needs separate metadata verification.

## Next boundary and release status

Next separately scoped work is App session/generation owner composition: hide old UI, stop/drain the fixed store, coordinator and native adapter together, then bind the new session. Real CloudKit, device/account-switch behavior, Watch account ownership/wire acceptance and exact release-candidate purchase/localization/store metadata remain separate gates.

No merge, push, signing, installation, upload, submission or production-data cleanup occurred. Live App Store Connect was not checked. This subplan's completion is not permission to bypass remaining release acceptance. Pause automation `knitnote-1-7-0-9-7` after saving this completed evidence; do not start a new feature merely because time remains before 19:00.
