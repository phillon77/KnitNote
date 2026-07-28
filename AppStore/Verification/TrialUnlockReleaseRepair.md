# Trial Unlock Release Repair Verification

Date: 2026-07-28

Branch: `codex/trial-unlock-release-repair`

Task 1 integration commit: `0e539e93eb5424aaa0d5e3a802ffa8b8412e110d`

Verified Task 2 source commit: `b259740e864a6e1d3c5218fee33eecad36f683a6`

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
| Watch GREEN | `swift test --scratch-path /tmp/KnitNoteTrialRepairWatchGreen --filter 'WatchCommandApplicationTests\|PhoneWatchSyncSourceContractTests\|WatchEntitlementSnapshotTests\|WatchOptimisticStateTests'` | 0 | 59 tests in 4 suites passed. Counter value stayed unchanged, the rejected command was recorded and acknowledged, and later unlock delivery did not replay it. |

The Swift package does not contain the Xcode-only `KnitNoteAppTests` target.
Those coordinator and Keychain tests were therefore also run through the app
scheme below.

## App and package tests

### App-layer Keychain and StoreKit lifecycle

Command:

```sh
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteTrialRepairAppTests \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:KnitNoteAppTests
```

Result: exit `0`.

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
swift test --scratch-path /tmp/KnitNoteTrialRepairFull
```

Result: exit `0`; `949` tests in `78` suites passed. The process exited
normally after the completion summary. The previously observed teardown-hang
limitation did not reproduce in this run.

## Release audit and metadata

| Command | Exit | Result |
| --- | ---: | --- |
| `bash AppStore/Verification/release_audit.sh` | 0 | `RELEASE AUDIT: PASS`; its internal full suite also completed with 949 tests in 78 suites. |
| `python3 AppStore/Verification/metadata_check.py` | 0 | `METADATA CHECK: PASS`. |
| `git diff --check main...HEAD` | 0 | No whitespace errors at verified source commit `b259740e864a6e1d3c5218fee33eecad36f683a6`. |

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
| KnitNote iOS / iPadOS | `generic/platform=iOS` | `/tmp/KnitNoteTrialRepairIOS` | 0 |
| KnitNote macOS | `generic/platform=macOS` | `/tmp/KnitNoteTrialRepairMac` | 0 |
| KnitNoteWatch | `generic/platform=watchOS` | `/tmp/KnitNoteTrialRepairWatch` | 0 |
| KnitNoteShare | `generic/platform=iOS` | `/tmp/KnitNoteTrialRepairShare` | 0 |

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
