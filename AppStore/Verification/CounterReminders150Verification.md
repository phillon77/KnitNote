# KnitNote 1.5 Counter Reminders Verification

Date: 2026-08-10

Branch: `feature/knitnote-1.5`

Exact source closure: `a91cf724c036202fcdad444afbe1b3dcc4d2878d`

Status: **AUTOMATED VERIFICATION PASSED; SCOPED PHYSICAL ACCEPTANCE RECORDED;
RELEASE CANDIDATE PENDING.**

This record distinguishes source/unit contracts, unsigned builds, and physical
acceptance. Automated results do not establish physical layout, VoiceOver,
keyboard, haptic, synchronization, persistence, overlay-install data
preservation, signed-candidate, archive, or release acceptance.

## Automated verification

| Scope | Exact command | Result |
| --- | --- | --- |
| Complete Swift suite | `swift test --disable-sandbox` | PASS, exit 0; 1,472 tests in 125 suites, zero issues |
| Static release audit | `AppStore/Verification/release_audit.sh --static-only` | PASS: metadata, offline commercial, and static audit |
| Metadata checker | `python3 AppStore/Verification/metadata_check.py` | PASS, exit 0 |
| Shell and diff checks | `bash -n AppStore/Verification/release_audit.sh`; `bash -n AppStore/Verification/create_release_candidate.sh`; `git diff --check` | PASS, exit 0 |

The focused layout/accessibility matrix statically requires explicit
iPhone/iPad/Mac presentation sizing, no scroll-dependent essential controls,
minus/plus/reset/value/reminder affordances, reminder-card actions, semantic
accessibility labels/hints, adaptive minimum action heights, and installed
synthetic fixture loading through the production store. The focused behavior
matrix verifies whole-number validation, combined crossings, durable offline
queueing, and duplicate acknowledgement rejection. Neither matrix exercises
real platform UI or hardware.

## Unsigned Debug builds

All four fresh commands at exact source closure `a91cf72` used independent
DerivedData paths, exited `0`, and ended in `BUILD SUCCEEDED`:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNote150Final-a91-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath /tmp/KnitNote150Final-a91-macOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/KnitNote150Final-a91-Watch CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteShare -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNote150Final-a91-Share CODE_SIGNING_ALLOWED=NO build
```

The standalone Share build used its scheme, so the simulator destination was
honored. The iOS scheme also compiled and embedded the Watch and Share products.
No archive, distribution signing, export, or upload was performed.

## Physical overlay-install availability

Physical checks recorded on 2026-08-10 found:

| Required device | OS | Discovery state | Install result |
| --- | --- | --- | --- |
| iPhone 17 Pro Max | iOS 26.6 | available | 1.5.0 (9); multiple data-preserving exact-source checks are identified below |
| iPad Air (5th generation) | iPadOS 26.5.2 | available | 1.5.0 (9); exact `a91cf72` overlay accepted |
| Apple Watch Ultra 2 | watchOS 26.6 | available | 1.5.0 (9); exact `a91cf72` overlay accepted |
| MacBook Pro | macOS 26.6.1 | available | exact `a91cf72` signed Debug app launched and exercised |

No app or device was uninstalled, erased, or reset. Existing projects were
preserved. Detailed scoped evidence and exact source boundaries follow below.

## Required physical acceptance

Checked items have explicit physical evidence below. Unchecked items remain
pending and must not be inferred from builds, contracts, or adjacent checks.

### iPhone and iPad

- [x] Overlay-install without uninstalling or erasing data.
- [x] Original projects and all prior counter values remain present.
- [x] iPad portrait: minus, plus, reset, value editing, reminder summary/editor,
  Cancel, and Done are initially visible without scrolling.
- [x] iPad landscape: the same controls remain initially visible without
  scrolling.
- [x] Narrow iPhone layout remains usable and exposes all essential controls.
- [ ] Direct entry accepts `2048` and rejects empty, negative, fractional,
  alphabetic, signed-plus, non-ASCII digit, and overflowing values without
  corrupting the prior stored value.
- [x] A repeating reminder starting from value 8 with interval 10, followed by
  direct entry 35, presents one combined pending reminder covering targets 18
  and 28 with count 2.
- [x] Complete acknowledges the visible combined pending reminder once; Stop
  disables and clears the applicable reminder state.
- [ ] A rejected or failed Complete/Stop transaction keeps the visible card
  open without publishing a partial state change.

The direct-input matrix was physically accepted on exact source
`18869d302d989c14411e21a887704c16d484a8a7`: `2048` saved, while empty,
negative, fractional, alphabetic, signed-plus, non-ASCII-digit, and overflowing
values were rejected without changing the stored `2048`. Between that source
and `a91cf724`, the only counter-manager production change was iPad layout; the
parser and store were unchanged. The strict exact-closure checkbox above stays
unchecked so this record does not copy physical acceptance across source SHAs.

### Apple Watch

- [x] An increment that newly crosses a known target produces exactly one
  notification haptic after persistence.
- [x] An authoritative refresh of an already-visible pending reminder does not
  replay the haptic.
- [x] Complete synchronizes once to iPhone/iPad and clears the pending state.
- [x] Stop synchronizes once, clears the reminder, and prevents later counter
  changes from reviving it.
- [ ] Replaying a stale Complete after Stop does not revive or acknowledge the
  stopped reminder.
- [x] While offline, perform one reminder action, reconnect, and observe one
  final authoritative result with no duplicate completion or haptic.

### Mac

- [x] The counter manager remains usable while resizing down to its supported
  minimum and keeps essential controls visible.
- [x] Keyboard focus/navigation order follows name, value, decrement,
  increment, reset, reminder controls, Cancel, and Done without trapping focus.
- [ ] VoiceOver announces editable value, next target/combined count, Complete,
  and Stop with distinct truthful labels/hints.
- [x] Counter value, reminder configuration, Complete, and Stop persist after
  closing and reopening the app.
- [ ] Reminder cards adapt without clipped actions at accessibility text sizes.

## Acceptance and commit gate

Automated source/build verification: **PASS**.

Scoped physical acceptance: **PASS where checked and documented below**.

Overall release acceptance: **PENDING / STOP**. Audible Mac VoiceOver,
accessibility text-size layout, immutable Release Candidate creation, archive
audit, exported-product inspection, upload, App Store Connect selection, and
submission remain outside this record.

## Scoped compact-control iPhone re-acceptance — PASS

Date: 2026-08-10

Exact source: `ad11a433ed9e996a10e2fb1e3e41ad4a55427b55`

Installed product: `com.phillon.KnitNote`, version `1.5.0`, build `9`, on the
paired iPhone 17 Pro Max running iOS 26.6.

The exact committed Debug product was installed as a data-preserving overlay;
no uninstall or erase was performed. The user explicitly reported **PASS** for
this scoped checklist:

- [x] Existing projects remained present after the overlay installation.
- [x] The counter manager displayed aligned `−1`, `+1`, and `↶ 0` actions
  without wrapping.
- [x] Decrement, increment, and reset behaved correctly, including the existing
  reset confirmation.
- [x] VoiceOver announced the full localized decrement, increment, and reset
  actions.

This PASS applies only to the compact counter controls on this iPhone and exact
source. It does not accept reminder behavior, Watch, iPad, Mac, metadata,
archive, export, upload, App Store Connect, or release gates; every unrelated
checkbox above remains PENDING.

## Scoped project-detail reminder card iPhone acceptance — PASS

Date: 2026-08-10

Exact source: `d059ddabdee4e26cd884caf57149bd326a3a5e2a`

Installed product: `com.phillon.KnitNote`, version `1.5.0`, build `9`, on the
paired iPhone 17 Pro Max running iOS 26.6.

The exact committed Debug product was installed as a data-preserving overlay;
no uninstall, erase, reset, or container deletion was performed. The user
explicitly reported **PASS** for this narrowly scoped project-detail reminder
card checklist:

- [x] Existing projects and counter values remained present.
- [x] The prior combined reminder appeared directly below the counter grid,
  without opening a pattern, at latest row `28` with count `2`.
- [x] VoiceOver truthfully announced the reached row, combined count,
  **Complete**, and **Stop**.
- [x] **Complete** cleared the card once and it remained cleared after reopen.
- [x] Raising the value to `38` showed a new reminder card.
- [x] **Stop** cleared and disabled that card; after reopen and increasing past
  `48`, it did not revive.

This PASS is limited to this exact iPhone source/build and project-detail
reminder-card flow. It does not accept the remaining iPhone/iPad checklist,
iPad, Apple Watch, Mac, Share, archive, export, upload, App Store Connect, or
release gates. The overall feature acceptance above remains **PENDING / STOP**.

## Scoped iPad counter-manager layout acceptance — PASS

Date: 2026-08-10

Exact source: `a91cf724c036202fcdad444afbe1b3dcc4d2878d`

Installed product: `com.phillon.KnitNote`, version `1.5.0`, build `9`, on the
paired iPad Air (5th generation) running iPadOS 26.5.2.

The exact committed Debug product was installed as a data-preserving overlay
over the existing app; no uninstall, erase, reset, or container deletion was
performed. The user explicitly reported **PASS** for this scoped checklist:

- [x] Existing projects and counter values remained present.
- [x] The counter name editor appeared above the value editor at full width.
- [x] The value editor and `−1`, `+1`, and reset `↶ 0` controls were aligned
  and visually comfortable.
- [x] Portrait and landscape kept the essential counter and reminder controls
  visible without clipping or required scrolling.

This PASS is limited to the iPad counter-manager layout and data preservation
at this exact source/build. It does not yet accept the iPad reminder-card
Complete/Stop flow or VoiceOver, Apple Watch, Mac, Share, archive, export,
upload, App Store Connect, or release gates. Overall feature acceptance remains
**PENDING / STOP**.

## Scoped project-detail reminder card iPad acceptance — PASS

Date: 2026-08-10

Exact source: `a91cf724c036202fcdad444afbe1b3dcc4d2878d`

Installed product: `com.phillon.KnitNote`, version `1.5.0`, build `9`, on the
paired iPad Air (5th generation) running iPadOS 26.5.2.

Using a disposable test project after a data-preserving overlay installation,
the user explicitly reported **PASS** for this scoped checklist:

- [x] A repeating reminder anchored at value `8` with interval `10` displayed
  next target `18` before the crossing.
- [x] Direct entry to `35` produced a project-detail reminder card without
  opening a pattern, showing latest reached row `28` and combined count `2`.
- [x] Portrait and landscape displayed the card without clipping.
- [x] VoiceOver truthfully announced row `28`, count `2`, **Complete**, and
  **Stop**.
- [x] **Complete** cleared the card once; after reopening, the counter remained
  `35`, the card stayed cleared, and the next target was `38`.
- [x] Raising the value to `38` produced the next card; **Stop** cleared and
  disabled it. After reopening and raising the value to `49`, no card revived
  and the manager reported no active reminder.

This PASS is limited to the iPad counter-manager and project-detail reminder
flow at this exact source/build. Apple Watch, Mac, Share, archive, export, upload,
App Store Connect, and release gates remain unaccepted. Overall feature
acceptance remains **PENDING / STOP**.

## Scoped Apple Watch counter-reminder acceptance — PASS

Date: 2026-08-10

Exact source: `a91cf724c036202fcdad444afbe1b3dcc4d2878d`

Installed products: `com.phillon.KnitNote` and
`com.phillon.KnitNote.watch`, version `1.5.0`, build `9`, on the paired iPhone
17 Pro Max (iOS 26.6) and Apple Watch Ultra 2 (watchOS 26.6). Both were
installed as data-preserving overlays; no uninstall, erase, reset, or container
deletion was performed.

The user explicitly reported **PASS** for this scoped checklist:

- [x] Existing iPhone projects remained present after the overlay installation.
- [x] A counter at `17` with next target `18` synchronized to Watch.
- [x] One Watch increment to `18` produced exactly one notification haptic and
  one pending reminder with **Complete** and **Stop** actions.
- [x] Re-entering the counter after an authoritative refresh did not replay the
  haptic or duplicate the reminder.
- [x] Watch **Complete** synchronized once to iPhone, cleared the pending state,
  preserved value `18`, and advanced the next target to `28`; reopen did not
  revive or replay it.
- [x] At target `28`, Watch **Stop** synchronized once, cleared and disabled the
  reminder, and raising the iPhone value to `38` did not revive it or replay a
  haptic.
- [x] For offline verification, a reminder at value `9` with next target `10`
  was synchronized first; the iPhone was then powered off. Watch incremented
  to `10`, produced one haptic, and completed the reminder locally. After the
  iPhone restarted, the final authoritative state synchronized once: value
  `10`, pending cleared, next target `12`, with no duplicate completion,
  reminder, or haptic.

This PASS is limited to the Watch counter-reminder flow at this exact source/build.
Mac, Share, archive, export, upload, App Store Connect, and release gates remain
unaccepted. Overall feature acceptance remains **PENDING / STOP**.

## Scoped Mac counter-reminder acceptance — PASS

Date: 2026-08-10

Exact source: `a91cf724c036202fcdad444afbe1b3dcc4d2878d`

Tested product: `com.phillon.KnitNote`, version `1.5.0`, build `9`, from the
exact signed Debug app on the Mac. Testing used only the disposable `test2`
project; no formal project was edited or deleted.

The Mac UI was exercised directly and produced the following evidence:

- [x] At the minimum window size, the name, value, `−1`, `+1`, reset `↶ 0`,
  reminder, Cancel, and Done controls remained visible without overlap or
  clipping.
- [x] With macOS Keyboard Navigation temporarily enabled, focus advanced from
  the editors through `−1`, `+1`, reset, Edit Reminder, Cancel, and Done. The
  original Keyboard Navigation setting was restored to off afterward.
- [x] Accessibility exposed distinct truthful labels for the value editor,
  decrement, increment, reset, reminder summary, Edit Reminder, Complete, and
  Stop. Audible VoiceOver speech was not independently captured.
- [x] A repeating reminder anchored at value `8` with interval `10` reported
  next target `18`; direct entry to `35` displayed row `28` with combined count
  `2` in the project-detail card.
- [x] Complete cleared the card and advanced the persisted next target to `38`.
- [x] At `38`, Stop cleared and disabled the reminder. Raising the value to
  `49` did not revive the card.
- [x] After fully quitting and relaunching the exact app, project `test2`
  retained value `49` and the stopped reminder remained absent.

This PASS is limited to the Mac counter-manager and project-detail reminder
flow at this exact source/build. Share, archive, export, upload, App Store Connect,
and release gates remain unaccepted. Overall feature acceptance remains
**PENDING / STOP**.

## Scoped iPhone Share Extension acceptance — PASS

Date: 2026-08-10

Exact source: `a91cf724c036202fcdad444afbe1b3dcc4d2878d`

Installed product: `com.phillon.KnitNote`, version `1.5.0`, build `9`, on the
paired iPhone 17 Pro Max running iOS 26.6. The installed identity was queried
immediately before this check. No uninstall, erase, or overlay reinstall was
performed.

The Share flow was exercised through iPhone Mirroring with the system UI in
Traditional Chinese and KnitNote deliberately switched from its original
English selection to Dutch:

- [x] `KnitNote` appeared directly in the share sheet for the supported
  one-page `KnitNote-Share-Test.pdf` file.
- [x] The Share Extension followed KnitNote's selected Dutch language rather
  than the Chinese system language, displaying `Voeg toe aan KnitNote`,
  `Toegevoegd aan KnitNote`, and `Sluit` without key or placeholder leakage.
- [x] Opening the main app processed the shared inbox and displayed the Dutch
  success notice `Gedeeld patroon bewaard`.
- [x] The existing `Pattern` library entry remained a single one-page PDF row;
  sharing the same file again did not create a duplicate library item.
- [x] KnitNote's language selection was restored to its original English value
  after verification.

This PASS is limited to the supported PDF Share Extension, selected-language
projection, inbox handoff, and duplicate handling on this exact iPhone
source/build. Archive, export, upload, App Store Connect, and release gates remain
unaccepted. Overall feature acceptance remains **PENDING / STOP**.
