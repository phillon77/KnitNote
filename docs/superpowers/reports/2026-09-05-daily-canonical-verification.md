# Daily canonical durability verification — 2026-09-05

## Candidate and boundaries

Task 4 extends reviewed Task 3 commit `c55702dd0ee5113eac447ba5bde2970b317c92e0` in `.worktrees/cross-device-sync-design`. Version remains **1.7.0 (13)**. The tested source/test/project patch SHA-256 is `63d9d8f2908079134531252446386756b8a000cb9f06cfe112937f330284298a` (six scoped files, excluding this report). Final commit identity is recorded in the Task 4 worker report.

No App test host was launched. All runtime tests use isolated temporary fixtures. No live CloudKit, Keychain, user data, UI, signing, schema deployment, upload, submission, or push was performed.

## Verified contracts

- Five internal no-op-by-default publication hooks observe completed intent, archive/artifact, journal and checkpoint writes, and the boundary before intent removal. They do not replace disk operations or introduce another recovery coordinator/file.
- The real fixture fails once at each phase, releases its used store/journal instances, and activates fresh instances twice. Before archive commit the exact predecessor survives; after commit the exact marker candidate survives. Assertions compare complete records, commit UUID, exact pending mutation array and unique mutation identities.
- Checkpoint file-sync, rename and parent-directory-sync failures are retried with another failure, then repaired. The original transaction and exact journal identities survive both failures and two successful reopens. Existing unprovable-state tests continue to require marker retention.
- Recovery inventory binds the real canonical file digest/length, but pending packets contain only unacknowledged mutations. The fixed `.canonical-next.json` slot, including partial bytes or a directory, blocks cleanup authorization. Authenticated unchanged selection is required to remove `canonical.json`; refused cleanup retains ciphertext and plaintext. Torn and complete pending-only replay both refuse canonical activation without full authority. Account B refuses account A's checkpoint unchanged.
- Six actual wire-decoded Watch commands with subsecond timestamps preserve all six counter states/proofs through ACK, two reopens and duplicate replay. Prepared/archive/ledger interruption recovery retains the exact command identity and does not increment again.
- Both legacy and usage markup paths preserve the original PDF attachment identity and bytes, exact checkpoint records, and no-op behavior through two reopens. Usage markup legitimately advances the archive's optimistic-lock revision; legacy artifact-only markup does not change archive bytes.
- Acknowledged project deletion retains tombstones. Day-29 restoration followed by another reopen restores the original photo bytes and live domain records while preserving superseded attachment tombstones.
- Both checkpoint sources are explicitly members of the same app and Watch Core consumer targets as `SyncBootstrapTransaction.swift`. No unrelated project settings or Watch CloudKit contract changed.

## Watch precision correction

A newly allocated processing stamp could differ from its Watch-file roundtrip by one floating-point unit. With a real wire-decoded command, only `processingStamp.modifiedAt` differed (`800000010.000002` versus `800000010.0000019` seconds since reference date); command identity, prepared command and effect proof matched. A second increment failed in both canonical and pre-canonical modes.

The bounded correction allocates **new** processing timestamps using the existing codec's millisecond-Double representation before first issuance. It does not round to integer milliseconds, change logical revision/device ID, normalize received command identity, modify prepared commands, or rewrite retained proofs. Three repeated actual codec cycles, sequential commands, replay and interrupted recovery cover stability. Existing mismatched issued history remains fail-closed; no migration or tolerance comparison is introduced.

## Execution evidence

All Swift runs use `CLANG_MODULE_CACHE_PATH=/tmp/daily-canonical-clang-cache` and task-owned `--cache-path /tmp/task4-swift-cache --config-path /tmp/task4-swift-config --security-path /tmp/task4-swift-security`, with `--disable-sandbox`. HOME and CODEX_HOME were not changed. The existing `.build` scratch is reused.

The bounded runner records the exact command, start, exit status and elapsed time in each log, terminates the process group after 900 seconds, and reports timeout as **incomplete**, never PASS.

| Validation | Result | Evidence |
| --- | --- | --- |
| Fixed canonical temporary RED | Exit 1; 1 test / 2 cases / 2 issues | `/tmp/task4-account-red-01.log` |
| Publication hook behavioral RED | Exit 1; 1 test / 5 cases / 11 issues | `/tmp/task4-boundary-red-04.log` |
| Wire-decoded Watch processing-stamp RED | Exit 1; 1 test / 2 modes / 4 issues | `/tmp/task4-watch-wire-red-01.log` |
| Watch precision/replay/interruption GREEN | Exit 0; 3 tests / 1 suite; 2.070 s | `/tmp/task4-watch-green-02.log` |
| Repeated checkpoint faults and reserved directory | Exit 0; 2 tests / 2 suites; 0.709 s | `/tmp/task4-retry-green-01.log` |
| Final focused Core + Watch | Exit 0; 476 tests / 31 suites; 29.109 s (137.476 s including rebuild) | `/tmp/task4-focused-final-01.log` |
| Full Core, exactly one bounded run | **INCOMPLETE, exit 124 at 900.011 s; 4 failed tests / 46 issues recorded** | `/tmp/task4-full-core-01.log` |
| Signing-disabled macOS build-for-testing | Exit 0; TEST BUILD SUCCEEDED; 56.139 s | `/tmp/task4-macos-build-for-testing-01.log` |
| Single isolated Share timeout diagnostic after full exit | Exit 0; 1 test / 1 suite; 0.001 s | `/tmp/task4-share-isolated-01.log` |
| Whitespace/project syntax | `git diff --check` and `plutil -lint` passed during self-review | Final readback recorded in worker report |

Final focused command:

```sh
swift test --disable-sandbox --cache-path /tmp/task4-swift-cache --config-path /tmp/task4-swift-config --security-path /tmp/task4-swift-security --filter 'SyncCanonical|JSONProjectStoreCanonical|SyncBootstrap|SyncAccountRecovery|SyncPublication|JSONProjectStoreSyncDeletion|Watch'
```

Full Core removes only the filter. Build command:

```sh
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/daily-canonical-derived CODE_SIGNING_ALLOWED=NO build-for-testing
```

Output is not warning-free: the Swift rebuild reported the existing deprecated `String(contentsOf:)` use in `HighlightOverlayContractTests`; Xcode reported unavailable CoreSimulator services and skipped AppIntents metadata extraction for targets without that framework. The native macOS build nevertheless completed successfully. None of these diagnostics authorized a host launch or live-data workaround.

The full run has **no final test-run summary**. Its log records 2,280 test functions started, 2,275 passing summaries and 4 failing summaries (46 issues); 170 suites started, 166 passing and 3 failing summaries. These are observed partial counts, not a full-suite PASS or configured-total claim. `ReleaseAuditLocalizationTests.provenanceRequiresBothRetainedArchivesAndTheirInfoPlists` has no completion summary before the timeout; the final buffered output contains a missing fixture `Info.plist` traceback. No second full run was attempted.

The four recorded failures are:

- `generatedReleaseBuildSettingsUseAutomaticDevelopmentSigningWithoutProfiles`: 28 missing-field issues.
- `generatedDebugBuildSettingsUseAutomaticDevelopmentSigningWithoutProfiles`: 16 missing-field issues. A single read-only settings diagnostic returned exit 0 but JSON reported PIFCache/DerivedData permission failure and omitted the required fields (`/tmp/task4-buildsettings-diagnostic-01.log`). The settings gate therefore remains unverified in this sandbox.
- `unixSocketIsRejectedWithoutOpeningIt`: fixture socket creation/bind threw generic EIO before the reader ran. Sandbox restriction is suspected; the fixture discarded the actual errno, so the cause is not confirmed.
- `cancelDuringProcessingSuppressesLatePublication`: a 10-second semaphore wait timed out under full-suite load. Its only isolated rerun, after the full process ended and with unchanged source/settings, passed in 0.001 seconds. This supports a transient/load-related failure but does not erase the failed full-run result.

## Remaining acceptance gates

Injected exceptions and in-process object replacement do not establish sudden power-loss or real process-termination durability. A macOS build does not establish iPhone, iPad, Mac, Watch or extension physical acceptance. Live account transitions, remote refetch completion, CloudKit transport, actual caller freeze/ownership integration and complete-device validation remain separate gates. Pending-only account recovery intentionally cannot reconstruct acknowledged full canonical history. No release readiness is claimed.
