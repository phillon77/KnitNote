# Task 7 Report: Apple Watch Entitlement Snapshot and Command Enforcement

## Outcome

Task 7 adds a schema-2 Watch snapshot with an explicit iPhone-authored
entitlement projection. The Watch remains usable offline when its last valid
snapshot was an active trial, permanent unlock, or legacy paid-owner
qualification. A newer expired or not-started snapshot makes counter controls
read-only and shows localized “Unlock on iPhone” guidance.

Blocked commands are not acknowledged, are not recorded in the processed
ledger, and do not mutate project or prepared-command persistence. Existing
queued commands remain durable and resume delivery after a newer writable
entitlement snapshot arrives.

## Implementation

- Added `WatchEntitlementSnapshot` and made entitlement mandatory in
  `WatchSyncSnapshot`; schema version is now 2 and schema 1 is rejected.
- Project snapshots and command acknowledgements carry the verified iPhone
  entitlement projection.
- Added an explicit authoritative entitlement gate before Watch command
  deduplication and durable mutation.
- Made entitlement changes reliable snapshot structure and scheduled an iPhone
  refresh at the trial-expiry boundary.
- Preserved generous offline behavior by freezing trial validity to the
  snapshot generation time until the iPhone sends a newer state.
- Paused Watch command delivery in read-only state without dropping the queue;
  a defensive `.entitlementRequired` acknowledgement is also refused.
- Disabled tap, long-press, dialog, and accessibility mutation actions while
  read-only and added English and Traditional Chinese iPhone-unlock guidance.
- Updated screenshot fixtures and all schema-2 test fixtures to provide an
  explicit entitlement rather than assuming write access.

## Plan Deviation

The written plan's Task 7 Step 3 says an entitlement-rejected command is
acknowledged and removed. The parent task's later explicit acceptance rule
requires the opposite: blocked commands must not be acknowledged, must retain
retry state, and must resume after entitlement synchronization. The later
instruction is implemented and covered by tests. Permanent command rejections
such as unsupported schema, missing project/counter, and completed project
retain their existing acknowledgement behavior.

## TDD Evidence

- First RED: missing entitlement model, schema-2 snapshot/builder APIs, and
  iPhone entitlement command overload.
- First GREEN: 8 tests across 2 suites.
- Second RED: missing entitlement-aware deliverable command, Phone entitlement
  subscription, reliable entitlement fingerprint, and Watch read-only UI.
- Second GREEN: 27 tests across 4 suites.
- Offline-expiry RED: an active snapshot locked itself from the Watch clock,
  active-to-expired state did not change the reliable fingerprint, and the
  phone had no expiry refresh.
- Offline-expiry GREEN: 3 focused tests passed.
- No-ack RED: `.entitlementRequired` acknowledgement removed the queued
  command (2 issues).
- No-ack GREEN: the focused retention test passed.
- Review RED: `trialNotStarted` recovery and handshake lacked authoritative
  entitlement inputs; 2 tests failed to compile on the missing API.
- Review GREEN: 2 no-write recovery/handshake tests passed.
- Unlock-side-effect RED: the expired Watch command test failed because generic
  authorization published an iPhone unlock request.
- Unlock-side-effect GREEN: the full entitlement coordinator suite passed after
  moving the Watch gate before generic authorization.

## Fresh Final Verification

| Verification | Result |
| --- | --- |
| `swift test --filter Watch` | 132 tests in 15 suites passed |
| `swift test` | 927 tests in 78 suites passed |
| Full `KnitNoteAppTests` | 29 tests / 31 executions passed |
| Unsigned generic iOS Simulator build | passed |
| Unsigned generic watchOS Simulator build | passed |
| Unsigned generic macOS build | passed |
| `git diff --check` | passed |
| Watch localization JSON parse | passed |
| Final independent re-review | no Critical or Important findings |

## Scope and Artifacts

No Task 8 implementation was added. Xcode DerivedData from verification was
removed. Pre-existing untracked `KnitNote 5.xcodeproj/` and
`KnitNote/Info 2.plist` were preserved and excluded from the Task 7 commit.
