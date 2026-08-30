# Task 3 report — schema 14 reminder migration

## Scope

Implemented the approved schema 13-to-14 conversion for legacy counter reminders. The shared `KnittingReminderMigrator` validates and migrates archives for startup and backup restore; the existing staged pattern migration transaction now writes the reminder-converted archive before install so startup leaves the original archive in place on failure.

## RED

`swift test --disable-sandbox --filter KnittingReminderMigrationTests` initially failed to compile because `KnittingReminderMigrator` did not exist.

## GREEN

- `swift test --disable-sandbox --filter 'PatternLibraryMigrationTests|KnittingReminderMigrationTests|KnitNoteBackupServiceTests'`
  - 120 tests passed.
- `swift test --disable-sandbox --filter 'KnittingReminderMigrationTests|KnitNoteBackupServiceTests|PatternLibraryMigrationTests|ReleaseConfigurationContractTests'`
  - 156 tests in 3 suites passed after 7.849 seconds.
- `swift test --disable-sandbox --filter KnittingReminderMigrationTests`
  - 6 tests passed, including version-13 startup migration and injected persistence-failure rollback.
- `swift test --disable-sandbox --filter 'KnittingReminderMigrationTests|KnitNoteBackupServiceTests|ReleaseConfigurationContractTests'`
  - 128 tests in 3 suites passed after 8.097 seconds.
- `git diff --check`
  - passed.

## Changed files

- Added `Sources/KnitNoteCore/Projects/KnittingReminderMigrator.swift` and `Tests/KnitNoteCoreTests/KnittingReminderMigrationTests.swift`.
- Bumped the archive contract to version 14 and updated release/static-audit expectations.
- Integrated validation/migration into JSON startup, staged backup restore, and the existing transactional pattern migration path.
- Preserved backup manifest summary fields while recomputing format-2 file integrity after staged archive transformation.
- Made invalid encoded legacy counter reminders fail closed instead of being dropped by decoding.
- Updated reminder decoding so a stopped migrated reminder can retain its required nil next target.

## Self-review

- Legacy reminder conversion preserves counter IDs/order, reminder IDs, rule/message, acknowledged/pending progress, state, next target, and revision; source counter reminder fields are cleared only in the returned archive.
- Derived repeating targets use checked arithmetic. Invalid, duplicate, dangling, or future-version archives throw before publication/installation.
- Version-14 archives validate and return unchanged through the migrator.
- Startup v13 conversion is composed with the existing rollback transaction; backup conversion occurs only in a fresh staged tree.

## Concerns

- No full-suite run was attempted because the task brief records an existing async-tail stall; the focused, adjacent archive/store/backup, and release-contract suites above cover the changed paths.
- `StoredProject` has private stored fields, so the migrator replaces its counters/reminders through its Codable representation and immediately decodes it again to retain all untouched persisted fields and enforce decoding validation.

## Review-fix round 1

- Backup staging maps reminder-migrator failures to the public `invalidArchive` result and still performs transformation only inside the staged tree.
- JSONProjectStore now routes the still-present legacy counter editor entry point to `knittingReminders`; direct legacy model APIs remain solely for decoding and migration compatibility. The post-migration startup test mutates and reloads a counter to prove no legacy reminder field reappears.
- Reminder decode validation now checks rule-derived pending targets and deferred display semantics while retaining reset/re-handle histories.
- Added a format-1 version-13 backup fixture that confirms staged reminder conversion while preserving the manifest summary fields.
- Review verification: `KnittingReminderMigrationTests` passed 7 tests; `KnittingReminderStoreTests` passed 9 tests; `KnitNoteBackupServiceTests|ReleaseConfigurationContractTests` passed 122 tests in 2 suites after 22.514 seconds; `git diff --check` passed.
- Retained prior `PatternLibraryMigrator` integration because it writes the shared reminder conversion into the already-existing rollback transaction; retained App Store/release-audit changes only because their schema contract requires the exact current version 14.

## Review-fix round 2

- Compatibility entry points now reject secondary-counter creation and reject an ambiguous legacy replace when independent v14 reminders already exist. Exact ID-based completion/stop/removal remains scoped to one reminder.
- Added regression coverage that secondary creation is rejected and that a legacy adapter edit cannot delete or replace two independent main-counter reminders.
- Added staged-backup failure fixtures for a broken v13 reminder-to-counter reference and a valid legacy repeating reminder whose next derived target overflows. Both return `KnitNoteBackupError.invalidArchive` and leave the pre-existing live archive bytes unchanged.
- Final focused migration fixture suite: 10 tests passed in 0.141 seconds. The requested combined filter was launched after these fixtures; its process completed, with detailed output truncated by the terminal stream.

## Review-fix round 3

- Updated legacy-counter corruption tests to expect fail-closed decoding while preserving absent-reminder decoding coverage.
- Updated JSON store reminder contracts to assert the v14 `knittingReminders` source rather than legacy counter fields. Task 4/6/7 UI and Watch rollout remain downstream work, not part of this migration task.
- `ProjectCounterTests` passed 28 tests and `JSONProjectStoreTests` passed 84 tests after these contract updates.
- Added the required end-to-end public boundary fixture: `prepareBackupRestore` receives a format-1 v13 archive whose otherwise-valid pending repeating target overflows during reminder migration. It returns `KnitNoteBackupError.invalidArchive`, and the live archive bytes plus published projects remain unchanged. Because preparation rejects before a staged restore object exists, `restoreBackup` is intentionally not called; this verifies the public pre-install rejection seam.
- Final verification: `swift test --disable-sandbox --filter 'ProjectCounterTests|JSONProjectStoreTests|KnittingReminderMigrationTests|KnitNoteBackupServiceTests|KnittingReminderStoreTests|ReleaseConfigurationContractTests'` passed 254 tests in 6 suites after 10.943 seconds.
- `git diff --check` passed.
