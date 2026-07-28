# KnitNote 1.2 Pattern Library Verification

Date: 2026-07-27
Candidate: `1.2.1` / Build `2`
Scope: local release-candidate verification only; no archive upload, App Store Connect edit, submission, or release is authorized by this report.

Status legend:

- `PASS`: the listed command or reproducible check completed successfully in this worktree.
- `NOT RUN`: the check requires human interaction or a device session that was not performed.
- `BLOCKED`: the check was attempted but an external prerequisite prevented completion.

## Automated verification

Status: `PASS`

Fresh verification completed in this worktree:

- `swift test --disable-sandbox --scratch-path
  /tmp/KnitNotePatternLibraryTask14-20260727-final-swift-clean`
  passed `831` tests in `68` suites after the final release-candidate cleanup.
- The release-configuration, privacy-manifest, and Share-target contract subset
  passed `16` tests in `3` suites.
- `bash AppStore/Verification/release_audit.sh --static-only`
  completed with `METADATA CHECK: PASS` and `RELEASE AUDIT: PASS`.
- `everySupportedLegacySchemaMigratesThroughTheStore(version:)` passed for
  every supported legacy schema, including schema 9 to schema 10.
- `formatTwoBackupRoundTripRestoresSharedPatternStateAndMarkupPrecisely` and
  `formatOneLegacyPatternBackupRestoresAndMigratesToSchemaTen` passed.
- Pattern inbox publication, duplicate resolution, retry, discard, recovery,
  project linking, shared pattern state, completed-project write rejection,
  reader persistence, and accessibility contract suites passed as part of the
  complete suite.
- Static release checks confirmed project archive schema `10`, backup manifest
  `2`, the production App Group in both app and Share entitlements, no tracking
  or collected-data declarations in all three privacy manifests, and complete
  English/Traditional Chinese string values and variation leaves in all three
  string catalogs.

The complete-suite build emitted only the pre-existing deprecation warning in
`HighlightOverlayContractTests.swift`; it did not produce a test failure.

## Build verification

Status: `PASS`

Fresh unsigned Release builds completed successfully with
`CODE_SIGNING_ALLOWED=NO`:

- generic iOS at
  `/tmp/KnitNotePatternLibraryTask14-20260727-final-iOS`;
- generic macOS at
  `/tmp/KnitNotePatternLibraryTask14-20260727-final-macOS`;
- standalone `KnitNoteShare` at
  `/tmp/KnitNotePatternLibraryTask14-20260727-Share`;
- standalone `KnitNoteWatch` at
  `/tmp/KnitNotePatternLibraryTask14-20260727-Watch`.

The iOS product audit confirmed:

- `KnitNote.app`, embedded `PlugIns/KnitNoteShare.appex`, and embedded
  `Watch/KnitNoteWatch.app` are present;
- bundle identifiers are `com.phillon.KnitNote`,
  `com.phillon.KnitNote.share`, and `com.phillon.KnitNote.watch`;
- the app, Share extension, Watch app, and macOS app all report version `1.2.1`
  and build `2`;
- app, Share, Watch, and macOS privacy manifests are present and pass
  `plutil -lint`;
- fresh standalone Share and Watch products also report version `1.2.1`,
  build `2`, and contain valid privacy manifests.

These are unsigned local build checks. They are not substitutes for signed
archives, Organizer validation, or App Store Connect processing.

## Device and manual matrix

Signed iPhone Share Sheet: `PASS`

Remaining manual matrix: `INCOMPLETE`

| Surface | Scenario | Status | Evidence |
| --- | --- | --- | --- |
| iPhone portrait | Import from Files and Share Extension; search; duplicate handling; link, unlink, and relink; read-only open | BLOCKED | A clean install launched successfully with PID `38773`, but the unsigned simulator build could not open the production App Group and presented the inbox/storage error UI. Functional interaction was not accepted as a pass. Screenshot: `/tmp/KnitNoteTask14-iPhone-clean.png`. |
| iPad portrait and landscape | Confirm readable PDF size, unobstructed page controls, highlight, and per-linked-project markup | BLOCKED | After reboot and clean install, launch succeeded with PID `38855`, but the same unsigned-build App Group limitation blocked functional interaction and rotation checks. Screenshot: `/tmp/KnitNoteTask14-iPad-clean.png`. |
| macOS | Import, search, sort, detail, and export original | NOT RUN | Requires an interactive macOS app session. |
| Completed project | Link and unlink remain available while all reader writes are blocked | NOT RUN | Automated completed-project link and write-rejection contracts passed; no manual interaction was performed. |
| Legacy schema 9 fixture | Names, ordering, page state, page notes, markup, and cover survive migration | NOT RUN | The automated legacy migration matrix passed, including schema 9 to schema 10; no manual fixture inspection was performed. |
| Backup manifest 2 | Round trip preserves inactive usage and markup while excluding inbox and thumbnails | NOT RUN | Automated manifest 2 round-trip, archive allowlist, and restore tests passed; no manual exported-package inspection was performed. |
| Backup manifest 1 | Restore remains backward compatible | NOT RUN | Automated legacy restore passed and migrated the result to schema 10; no manual restore session was performed. |
| Share inbox | Share one supported PDF twice from Files and confirm publication and duplicate handling | PASS | On a signed iPhone 17 Pro Max running iOS 26.5.2, KnitNote appeared in the Files Share Sheet, imported the one-page PDF, and kept one library record after the same PDF was shared again. Full evidence: `ShareExtensionActivationVerification.md`. Retry and discard remain covered only by automated tests. |
| VoiceOver | Labels, values, hints, and reading order | NOT RUN | Automated accessibility contracts passed; no manual VoiceOver session was performed. |

The iPhone and iPad observations prove only that the processes launched. They
do not claim a functional pattern-library smoke pass. The app and Share
Extension require the production App Group, which was unavailable after
building with signing disabled. One additional normal Simulator build completed
successfully, but its ad-hoc app and Share signatures both contained empty
entitlement dictionaries, so it could not provide the production App Group
needed to repeat the functional matrix safely.

## Not executed

The following actions are intentionally outside this report unless explicitly performed and recorded later:

- signed archives and Organizer validation;
- App Store Connect upload, metadata edits, submission, or release;
- signed iPhone pattern-library interaction beyond the scoped Share Sheet import
  and duplicate check recorded above;
- signed iPad pattern-library, PDF reader, rotation, highlight, markup, and page
  control acceptance testing;
- manual VoiceOver acceptance testing.
