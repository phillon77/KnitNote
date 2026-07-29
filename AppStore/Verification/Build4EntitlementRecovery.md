# KnitNote 1.2.1 Build 4 Entitlement Recovery Verification

Date: 2026-07-29 (Asia/Taipei)

Candidate: `1.2.1` / Build `4`

Base release-candidate commit: `ec1bbabb1651bde8c935e8de5da232f0a559ffc6`
(`chore: prepare KnitNote 1.2.1 Build 4`)

Status: `LOCAL AUTOMATED VERIFICATION PASSED — physical TestFlight/iPad acceptance remains outstanding.`

No archive, validation, upload, tester-group change, App Store Connect mutation,
submission, or release was performed.

## Candidate metadata

The XcodeGen source (`project.yml`) and generated
`KnitNote.xcodeproj/project.pbxproj` agree on
`CURRENT_PROJECT_VERSION = 4` for all shipping targets:

- `KnitNote`, `KnitNoteWatch`, and `KnitNoteShare` each declare Build `4` in
  the source configuration.
- The generated project has Build `4` in each target's Debug and Release
  configurations (six settings total).
- `MARKETING_VERSION` remains `1.2.1` everywhere.
- The static release audit and its contract tests now pin Build `4`; historical
  App Store documents still describe historical Build `3` evidence only.

## Automated verification evidence

| Command | Exit code | Result |
| --- | ---: | --- |
| `swift test --scratch-path /tmp/KnitNoteBuild4SwiftTests --filter ReleaseConfigurationContractTests` | `0` | `18` tests in `1` suite passed. |
| `swift test --scratch-path /tmp/KnitNoteBuild4SwiftTests --filter WatchPackagingContractTests` | `0` | `9` tests in `1` suite passed. |
| `bash AppStore/Verification/release_audit.sh --static-only` | `0` | `METADATA CHECK: PASS`; `RELEASE AUDIT: PASS`. |
| `swift test --scratch-path /tmp/KnitNoteBuild4SwiftTests` | `0` | `963` tests in `78` suites passed; zero issues. |
| `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4AppTests CODE_SIGNING_ALLOWED=NO` | `0` | `42` total tests: `42` passed, `0` failed, `0` skipped, `0` expected failures (xcresult). |

The macOS test command printed Xcode's existing multiple-matching-macOS-
destination warning, then completed successfully against the arm64 local Mac.

## Follow-up entitlement-outage correction

The base candidate initially treated every unavailable StoreKit lookup as a
trial refresh. The correction keeps a previously verified
`.permanentlyUnlocked` or `.legacyPaidOwner` snapshot intact and does not read
the trial store in that case. An initially unverified `.unavailable` lookup
still resolves the Keychain-backed trial and never receives permanent access.

The updated lifetime and legacy-paid regression expectations were first run
against the pre-fix implementation with:

```text
xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/KnitNoteBuild4OutagePreservationRedFull \
  CODE_SIGNING_ALLOWED=NO
```

The Swift Testing diagnostic reported six expected issues: for each preserved
entitlement it observed an unwanted trial-store read, a downgrade to
`.trialNotStarted`, and `.startTrial` instead of `.allow`.

After the minimal fix, the complete app suite was rerun with
`/tmp/KnitNoteBuild4OutagePreservationGreen`: exit `0`; xcresult reports `42`
total tests, `42` passed, and `0` failures. The final package and release
rechecks also completed with exit `0`:

| Command | Result |
| --- | --- |
| `swift test --scratch-path /tmp/KnitNoteBuild4SwiftTests` | `963` tests in `78` suites passed. |
| `bash AppStore/Verification/release_audit.sh --static-only` | `METADATA CHECK: PASS`; `RELEASE AUDIT: PASS`. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteBuild4Fix1-iOS CODE_SIGNING_ALLOWED=NO` | passed. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4Fix1-macOS CODE_SIGNING_ALLOWED=NO` | passed. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteBuild4Fix1-watchOS CODE_SIGNING_ALLOWED=NO` | passed. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNoteShare -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteBuild4Fix1-share CODE_SIGNING_ALLOWED=NO` | passed. |

## Unsigned clean Release build evidence

Each build used a separate derived-data path and
`CODE_SIGNING_ALLOWED=NO`. All four completed with exit code `0`.

| Scheme | Destination | Derived data | Command |
| --- | --- | --- | --- |
| `KnitNote` | `generic/platform=iOS` | `/tmp/KnitNoteBuild4-iOS` | `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteBuild4-iOS CODE_SIGNING_ALLOWED=NO` |
| `KnitNote` | `generic/platform=macOS` | `/tmp/KnitNoteBuild4-macOS` | `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4-macOS CODE_SIGNING_ALLOWED=NO` |
| `KnitNoteWatch` | `generic/platform=watchOS` | `/tmp/KnitNoteBuild4-watchOS` | `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteBuild4-watchOS CODE_SIGNING_ALLOWED=NO` |
| `KnitNoteShare` | `generic/platform=iOS` | `/tmp/KnitNoteBuild4-share` | `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNoteShare -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteBuild4-share CODE_SIGNING_ALLOWED=NO` |

## Required physical TestFlight acceptance — not executed

No physical TestFlight or iPad acceptance has been performed. After an
explicitly authorized archive/upload and availability to testers, verify on an
iPad:

1. A previously verified lifetime entitlement remains usable during a later
   StoreKit outage; it must not be downgraded or show a false unlock prompt.
2. A previously verified legacy-paid entitlement remains usable during a later
   StoreKit outage; it must not be downgraded or show a false unlock prompt.
3. A new, unpurchased installation can use the local seven-day trial when
   StoreKit is unavailable, but does not gain permanent ownership.
4. An expired trial remains restricted while StoreKit is unavailable.
5. Restricted project creation dismisses the child create sheet before showing
   the root unlock presentation; it must not expose `ProjectStoreError error 6`.
6. Reopen after each case to confirm durable entitlement/project state in iPad
   portrait and landscape layouts.

## External-action boundary and self-review

This local verification does not authorize archive, validation, upload,
TestFlight tester-group changes, App Store Connect metadata/IAP/price changes,
submission, or release. Explicit authorization is required **before** any
archive or upload; only then can a TestFlight build be available for the iPad
acceptance run.

Self-review confirmed that the only functional changes already present are the
Task 1 StoreKit-outage trial recovery and Task 2 deferred unlock presentation;
the follow-up correction preserves prior verified lifetime and legacy-paid
ownership during StoreKit outages while retaining local-trial preparation for
initially unverified users. Automated checks are green, but no physical
acceptance is claimed.

## Final review correction

Final functional candidate commit:
`b1eda5981ce448996ba50af39f322c97c7e44d05`
(`fix: defer project unlock and retain outage status`).

This correction closes the final review findings:

- Root unlock presentation now uses an explicit orchestration state. A
  `.createProject` request remains false at the root while the create sheet is
  presented, then transitions false-to-true only after the child sheet's
  `onDismiss`. Other mutation requests remain immediate.
- StoreKit verification availability is published separately as
  `unknown`, `available`, or `unavailable`. It is neither an entitlement
  snapshot nor an input to the Watch entitlement projection.
- Initial StoreKit unavailability still resolves the Keychain trial; later
  outages preserve verified lifetime and legacy-paid snapshots.
- Restore maps `.unavailable` to the existing retry/error notice rather than
  the no-purchase notice.
- The first successful `JSONProjectStore.add` after initial `.unavailable`
  starts a real `KeychainTrialStore` record that can be loaded through a fresh
  store instance.

### Final-review TDD evidence

| Phase | Command | Exit/result |
| --- | --- | --- |
| RED | `swift test --scratch-path /tmp/KnitNoteBuild4FinalFixCoreRed --filter UnlockPresentationTests` | Exit `1`; expected compile failures for the missing `UnlockPresentationOrchestrator`, `UnlockRestorePresentation`, and restore mapper. |
| RED | `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFixAppRed CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests` | Exit `65`; expected compile failures because `purchaseVerificationAvailability` did not exist. |
| GREEN | `swift test --scratch-path /tmp/KnitNoteBuild4FinalFixCoreGreen --filter UnlockPresentationTests` | Exit `0`; `8` tests in `1` suite passed. |
| GREEN | `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFixAppGreen2 CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests/EntitlementCoordinatorTests -only-testing:KnitNoteAppTests/CreateProjectPresentationTests` | Exit `0`; xcresult reports `34` logical tests, `35` parameterized cases, `0` failures. |

### Final full verification

All commands below ran against functional candidate
`b1eda5981ce448996ba50af39f322c97c7e44d05`.

| Command | Exit/result |
| --- | --- |
| `swift test --scratch-path /tmp/KnitNoteBuild4FinalFixSwiftTests` | Exit `0`; `966` tests in `78` suites passed. |
| `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFixAppTests CODE_SIGNING_ALLOWED=NO` | Exit `0`; xcresult reports `44` logical tests, `47` parameterized cases, `0` failed, `0` skipped, and `0` expected failures. |
| `bash AppStore/Verification/release_audit.sh --static-only` | Exit `0`; `METADATA CHECK: PASS`; `RELEASE AUDIT: PASS`. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFix-iOS-OutsideSandbox CODE_SIGNING_ALLOWED=NO` | Exit `0`. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFix-macOS CODE_SIGNING_ALLOWED=NO` | Exit `0`. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Release -destination 'generic/platform=watchOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFix-watchOS CODE_SIGNING_ALLOWED=NO` | Exit `0`. |
| `xcodebuild clean build -quiet -project KnitNote.xcodeproj -scheme KnitNoteShare -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnitNoteBuild4FinalFix-share CODE_SIGNING_ALLOWED=NO` | Exit `0`. |

The first sandboxed iOS build attempt at
`/tmp/KnitNoteBuild4FinalFix-iOS` exited `65` because CoreSimulator and
watchsimulator asset-catalog services were unavailable. The identical unsigned
Release build was rerun with normal Xcode service access at
`/tmp/KnitNoteBuild4FinalFix-iOS-OutsideSandbox` and exited `0`.

Version remains `1.2.1`, Build `4`. No pricing, App Store metadata, archive,
upload, tester-group, submission, or release action was performed. Physical
TestFlight/iPad acceptance remains required.
