# Trial Unlock Release Repair Verification

Date: 2026-07-28

Branch: `codex/trial-unlock-release-repair`

Task 1 integration commit: `0e539e93eb5424aaa0d5e3a802ffa8b8412e110d`

Verified Task 2 baseline source commit:
`b259740e864a6e1d3c5218fee33eecad36f683a6`

Verified review-fix Round 1 source commit:
`043e0aa9c39ead5cff71ac4db1f3375316988054`

Verified review-fix Round 2 source commit:
`b5ce45bd781a84fda4082a015559a2fc61799871`

Verified review-fix Round 3 source commit:
`691383bd3a0cde330f4b76ed48d0dad8224f74b4`

Release candidate: `1.2.1` / Build `3`

This is local, unsigned verification only. No archive was uploaded, no App Store
Connect field was changed, and pricing, IAP, availability, review, and release
state were not changed.

## Repaired contracts

- A `trialNotStarted` entitlement now returns `.startTrial` for every
  user-authored mutation. Complete backup restore remains allowed without
  starting the trial, and reads and complete backup export remain available.
- `JSONProjectStore` commits the durable trial record through the entitlement
  coordinator before entering a mutation body. A failed Keychain trial commit
  fails closed without changing memory, files, or the project archive.
- Each async pattern import and journal-photo mutation now has one authorization
  boundary. An operation admitted before the exact seven-day expiry may finish
  across that boundary; entry at the exact expiry is rejected before mutation.
- Passive pattern open/close and browsing housekeeping no longer start a trial.
  Housekeeping is type-limited to page index, zoom, and content offsets and
  merges those fields into stored state; it cannot accept or overwrite
  highlights, page notes, per-page state, markup, or other explicit edits.
  `lastOpenedAt` remains a separate scalar browsing update; passive reader-state
  persistence changes neither it nor project `updatedAt`. Target-page
  highlight/note values are projected only into a temporary hydration copy.
  An explicit reader edit still starts the trial before saving its full state.
- An expired authoritative iPhone entitlement now rejects a queued Watch command
  with `.entitlementRequired`, durably records the command identity, sends an
  acknowledgement that removes it from the Watch queue, and publishes the
  current authoritative snapshot. A later lifetime unlock cannot replay that
  rejected command.
- Historical archive and Build 3 statements in `AppStoreSubmission.md` now name
  their exact versions and cannot be mistaken for `1.2.1` / Build `3` evidence.

## TDD evidence

| Phase | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Restored-data RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRed --filter 'FeatureAccessPolicyTests\|JSONProjectStoreEntitlementTests'` | 1 | 28 selected tests; 46 issues. Existing-data mutations returned `.allow`, the trial committer was not called, and restored archive data changed. |
| App ordering RED | `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTrialRepairCoordinatorRed CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests` | 65 | `trialStartDecisionCommitsBeforeStoreMutation` and `failedTrialCommitFailsClosedBeforeTheStoreWrite` failed against the old post-write ordering. |
| Restored-data GREEN | `swift test --scratch-path /tmp/KnitNoteTrialRepairGreen --filter 'FeatureAccessPolicyTests\|JSONProjectStoreEntitlementTests\|EntitlementCoordinatorTests\|KeychainTrialStoreTests'` | 0 | 28 selected Swift-package tests passed. This includes 17 trial-starting mutation cases, backup-restore allowance, and seven restored-data mutation entry points that preserve memory and disk when the trial commit fails. |
| Watch RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairWatchRed --filter 'WatchCommandApplicationTests\|PhoneWatchSyncSourceContractTests'` | 1 | 26 tests; 4 issues. The expired command threw `.accessRestricted`, remained replayable, and the coordinator lacked a durable rejection acknowledgement. |
| Watch GREEN (superseded baseline) | `swift test --scratch-path /tmp/KnitNoteTrialRepairWatchGreen --filter 'WatchCommandApplicationTests\|PhoneWatchSyncSourceContractTests\|WatchEntitlementSnapshotTests\|WatchOptimisticStateTests'` | 0 | 59 tests in 4 suites passed, but the tests did not exercise Watch-side `.entitlementRequired` queue removal. Review later found the command remained queued. This run is not accepted as no-replay evidence. |

The Swift package does not contain the Xcode-only `KnitNoteAppTests` target.
Those coordinator and Keychain tests were therefore also run through the app
scheme below.

## Review-fix Round 1 TDD evidence

| Phase | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Watch queue RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1WatchRed --filter 'WatchOptimisticStateTests\|WatchEntitlementSnapshotTests\|PhoneWatchSyncSourceContractTests\|WatchCommandApplicationTests'` | 1 | 60 tests in 4 suites; 7 issues. `.entitlementRequired` returned `false`, remained persisted, preserved the optimistic increment, and became deliverable after unlock. |
| Async import RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1AsyncRed --filter 'JSONProjectStoreEntitlementTests'` | 1 | 23 tests; the import admitted 1 ms before expiry published successfully and then incorrectly threw `.accessRestricted` at the exact boundary. |
| Passive browsing RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1BrowsingRed --filter 'passivePatternOpenDoesNotStartTrialButExplicitMetadataEditDoes'` | 1 | 1 test; 2 issues. `markPatternOpened` started the trial and the later explicit edit caused a duplicate trial commit. |
| Inbox authorization RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1InboxRed --filter 'patternInboxConvenienceOverloadUsesOneEntryAuthorizationBoundary'` | 1 | 1 test; the convenience overload authorized `.importPattern` twice. |
| Combined GREEN | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1Green --filter 'WatchOptimisticStateTests\|WatchEntitlementSnapshotTests\|PhoneWatchSyncSourceContractTests\|WatchCommandApplicationTests\|JSONProjectStoreEntitlementTests\|FeatureAccessPolicyTests\|PatternReaderCounterContractTests'` | 0 | 115 tests in 5 suites passed. |
| Focused boundary GREEN (superseded for browsing isolation) | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1Green --filter 'passivePatternOpenDoesNotStartTrialButExplicitMetadataEditDoes\|exactSevenDayBoundaryRejectsAsyncMutationEntry\|trialNotStartedReaderSeparatesBrowsingHousekeepingFromExplicitEdits'` | 0 | All selected tests and both exact-boundary argument cases passed. This proved that browsing did not start the trial, but did not prove that the browsing endpoint excluded explicit reader fields; Round 2 supplies that evidence. |
| Inbox authorization GREEN | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound1InboxRed --filter 'patternInboxConvenienceOverloadUsesOneEntryAuthorizationBoundary'` | 0 | The convenience overload used exactly one entry authorization and no post-publication entitlement commit. |

## Review-fix Round 2 TDD evidence (superseded)

The passive projection contains only `pageIndex`, `zoomScale`, `offsetX`, and
`offsetY`, but the Round 2 persistence merge called `loadPage` on a page
change. That call wrote target-page highlight positions and note into the
stored top-level fields. The legacy path then performed a full update that also
changed `lastOpenedAt` and project `updatedAt`. Round 2 therefore narrowed the
input but did not satisfy the exact-four-field persistence contract.

| Phase | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Browsing projection RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound2Red --filter 'passivePatternOpenDoesNotStartTrialButExplicitMetadataEditDoes'` | 1 | 1 test; 6 issues. Housekeeping overwrote highlight enablement, mode, both positions, page note, and the full per-page state dictionary. |
| Reader boundary RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound2Red --filter 'trialNotStartedReaderSeparatesBrowsingHousekeepingFromExplicitEdits'` | 1 | 1 test; 2 issues. Reader call sites still passed the whole `PatternReadingState`, and the store endpoint still accepted it. |
| Focused GREEN (superseded) | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound2Green --filter 'PatternReaderCounterContractTests\|JSONProjectStoreEntitlementTests\|FeatureAccessPolicyTests\|PatternDocumentTests'` | 0 | 79 tests in 1 suite plus parameterized cases passed, but the new test incorrectly expected target-page highlight positions and note to replace stored top-level fields and did not cover legacy timestamps. This is not accepted as exact-four-field evidence. |

Unsigned Round 2 Release builds:

| Target | Destination | DerivedData | Exit |
| --- | --- | --- | ---: |
| KnitNote iOS / iPadOS | `generic/platform=iOS` | `/tmp/KnitNoteTrialRepairRound2IOS` | 0 |
| KnitNote macOS | `generic/platform=macOS` | `/tmp/KnitNoteTrialRepairRound2Mac` | 0 |

## Review-fix Round 3 TDD evidence

| Phase | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| Library and legacy persistence RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound3Red --filter 'passivePatternBrowsingPreservesExplicitFieldsAndExplicitEditStartsTrial\|legacyBrowsingChangesOnlyPassiveScalarsWithoutTouchingTimestamps'` | 1 | 2 tests; 7 issues. Library persistence changed three explicit top-level fields. Legacy persistence changed the full document equality, `lastOpenedAt`, and project `updatedAt`. |
| Hydration projection RED | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound3Red --filter 'loaderProjectsTargetPageExplicitFieldsWithoutMutatingStoredUsage'` | 1 | 1 test; 3 issues. The loader did not yet derive target-page highlight positions and note into a temporary display copy. |
| Focused GREEN | `swift test --scratch-path /tmp/KnitNoteTrialRepairRound3Green --filter 'PatternDocumentTests\|PatternReaderReloadSafetyTests\|PatternReaderCounterContractTests\|JSONProjectStoreEntitlementTests\|FeatureAccessPolicyTests\|PatternLibraryStoreTests'` | 0 | 116 tests in 2 suites plus parameterized cases passed. Library and legacy stored equality changed only the four passive scalars; explicit fields and timestamps remained unchanged. Display hydration projected target-page values without mutating the stored usage. Explicit endpoints still started the trial and fully persisted edits. |

Unsigned Round 3 Release builds:

| Target | Destination | DerivedData | Exit |
| --- | --- | --- | ---: |
| KnitNote iOS / iPadOS | `generic/platform=iOS` | `/tmp/KnitNoteTrialRepairRound3IOS` | 0 |
| KnitNote macOS | `generic/platform=macOS` | `/tmp/KnitNoteTrialRepairRound3Mac` | 0 |

## App and package tests

### App-layer Keychain and StoreKit lifecycle

Command:

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteTrialRepairRound1AppTests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests
```

Review-fix Round 1 result: exit `0`.

`xcresulttool` reported:

- result: `Passed`
- total tests: `39`
- device/configuration executions: `41`
- failed: `0`
- skipped: `0`
- destination: MacBook Pro, arm64, macOS `26.5.2` (`25F84`)

This target includes the real Keychain duplicate/corruption tests and StoreKit
purchase-service lifecycle tests.

### Complete Swift package suite

Command:

```sh
swift test --scratch-path /tmp/KnitNoteTrialRepairRound1Full
```

Review-fix Round 1 result: exit `0`; `955` tests in `78` suites passed. The process exited
normally after the completion summary. The previously observed teardown-hang
limitation did not reproduce in this run.

## Release audit and metadata

| Command | Exit | Result |
| --- | ---: | --- |
| `bash AppStore/Verification/release_audit.sh` | 0 | `RELEASE AUDIT: PASS`; its internal full suite also completed with 955 tests in 78 suites. |
| `python3 AppStore/Verification/metadata_check.py` | 0 | `METADATA CHECK: PASS`. |
| `git diff --check` | 0 | No whitespace errors before review-fix Round 1 source commit `043e0aa9c39ead5cff71ac4db1f3375316988054`. |

The first sandboxed release-audit attempt exited `1` before tests because
SwiftPM could not write its user module cache. The exact command was rerun with
approved cache access and passed. The first no-argument metadata invocation
exited `2` because the checker required an explicit path; the checker was
repaired to default to `AppStore/Metadata`, and the exact required command then
passed.

## Unsigned Release builds

All commands used `CODE_SIGNING_ALLOWED=NO`.

| Target | Destination | DerivedData | Exit |
| --- | --- | --- | ---: |
| KnitNote iOS / iPadOS | `generic/platform=iOS` | `/tmp/KnitNoteTrialRepairRound1IOS` | 0 |
| KnitNote macOS | `generic/platform=macOS` | `/tmp/KnitNoteTrialRepairRound1Mac` | 0 |
| KnitNoteWatch | `generic/platform=watchOS` | `/tmp/KnitNoteTrialRepairRound1Watch` | 0 |
| KnitNoteShare | `generic/platform=iOS` | `/tmp/KnitNoteTrialRepairRound1Share` | 0 |

These four builds preceded the final three-line inbox self-review delta. That
delta only removes duplicate/post-publication entitlement checks and was
separately compiled, linked, and behavior-checked by the focused inbox test;
the four-product matrix was not repeated.

The macOS product contains no `Watch` or `PlugIns` directory. `otool -L`
confirmed that both arm64 and x86_64 slices link
`StoreKit.framework/Versions/A/StoreKit`. The iOS product contains the expected
`Watch/KnitNoteWatch.app` and `PlugIns/KnitNoteShare.appex`.

## Known diagnostics and limitations

- Swift compilation emits the pre-existing deprecation warning in
  `HighlightOverlayContractTests.swift` for `String(contentsOf:)`.
- Some PDF fixture tests emit the pre-existing CoreGraphics diagnostic
  `CoreGraphics PDF has logged an error`; no related test failed.
- The macOS test destination warning reports matching arm64 and x86_64
  destinations and selects arm64. The selected run passed.
- These builds are unsigned compile/package evidence, not signed archives,
  Organizer validation, TestFlight, or physical-device acceptance.

## Remaining release gates

- Run the physical iPhone, iPad, Mac, and paired Apple Watch matrix, including
  restored-data first mutation, trial expiry, offline Watch reconciliation,
  Share Extension expiry, backup restore/export, rotation, accessibility, and
  persistence after relaunch.
- Test StoreKit sandbox purchase, restore after reinstall, same-Apple-Account
  cross-device unlock, legacy paid-owner upgrade, and redeem-code behavior.
- Create signed iOS/Watch and macOS archives, run Organizer validation, and run
  the archive/product privacy and entitlement audit.
- Configure and verify the non-consumable IAP, free App price, pricing schedule,
  review screenshot, storefront availability, submission metadata, and review
  linkage in App Store Connect.
- Obtain explicit user authorization before any upload, App Store Connect
  write, pricing/IAP/availability change, submission, or release.
