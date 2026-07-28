# Task 3 Final-Review Fix Report

Status: DONE

## Finding addressed

`JSONProjectStore` previously committed `.startTrial` at the authorization
entry point. Invalid project creation and imports could therefore consume the
trial before input or target validation failed.

The store now separates entitlement preflight from trial commitment:

- `.requiresUnlock` still rejects immediately, before file or archive work.
- `.allow` keeps the existing single authorization boundary.
- `.startTrial` validates the project name, target project, archive
  availability, and source pattern content before committing the trial.
- The trial commit remains before the first import copy/publication and fails
  closed if the commit returns `.requiresUnlock`.
- Existing operations admitted immediately before exact expiry do not perform
  a later expiry check.

Source and regression tests commit: `b859e69`.

The suggested removal of
`readerSession.acceptCanvasState(synchronizedState)` was tested and reverted:
the call is required by
`liveCanvasCallbacksSynchronizeBothCrossHighlightCoordinatesBeforeSessionAcceptance`.
It is not redundant.

No App Store submission wording was changed because this local verification
does not supply new signed archive, TestFlight, physical-device, IAP, or review
evidence.

## TDD evidence

RED at `8e1728c`:

```sh
swift test --scratch-path /tmp/KnitNoteTask3FixRed \
  --filter 'failedProjectCreationNeverCommitsTrialStart|archiveWriteFailureNeverCommitsTrialStart|failedPatternImportsNeverCommitTrialStart'
```

Exit `1`. Three selected tests recorded three issues. With real
`.startTrial`, invalid project creation and failed imports observed premature
committer calls.

Focused GREEN:

```sh
swift test --scratch-path /tmp/KnitNoteTask3FixGreen \
  --filter 'JSONProjectStoreEntitlementTests|PatternReaderCounterContractTests'
```

Exit `0`; 50 tests passed.

## Full verification

| Command | Result |
| --- | --- |
| `swift test --scratch-path /tmp/KnitNoteTask3FixFull` | Exit 0; 960 tests in 78 suites passed. |
| `xcodebuild test -quiet -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteTask3FixAppTests CODE_SIGNING_ALLOWED=NO -only-testing:KnitNoteAppTests` | Exit 0; 39 tests, 41 executions, 0 failures. |
| iOS/iPadOS unsigned Release build (`/tmp/KnitNoteTask3FixIOS`) | Exit 0. |
| macOS unsigned Release build (`/tmp/KnitNoteTask3FixMac`) | Exit 0. |
| watchOS unsigned Release build (`/tmp/KnitNoteTask3FixWatch`) | Exit 0. |
| Share Extension unsigned Release build (`/tmp/KnitNoteTask3FixShare`) | Exit 0. |
| `git diff --check` | Exit 0 before the source/test commit. |

Known diagnostics remained unchanged: the `String(contentsOf:)` deprecation
warning in `HighlightOverlayContractTests.swift`, the CoreGraphics PDF fixture
diagnostic, and the macOS destination-selection warning.

These results are local unsigned build/test evidence only. Signed archives,
Organizer validation, StoreKit sandbox, TestFlight, physical iPhone/iPad/Mac/
paired-Watch acceptance, App Store Connect IAP configuration, and submission
remain external gates requiring explicit authorization.
