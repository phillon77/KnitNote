# Task 12 Report: Backup Reminder and Last Successful Date

## Scope

Implemented the canonical Task 12 behavior from the approved brief, plan, and
design:

- persist the last successful manual export date;
- update it only after `.fileExporter` reports success;
- show one local-storage reminder after the first `.created` library import;
- persist reminder dismissal and never repeat it;
- provide a direct route from the reminder to the existing manual backup
  settings surface;
- provide English and Traditional Chinese copy.

No cloud sync, background scheduling, notification permission, recurring
7/14/30-day reminders, snooze/disable controls, analytics, external-file
location tracking, or restore event history was added. Those behaviors are not
defined by the canonical Task 12 documents.

## Implementation

- Added `BackupHistory`, backed by `UserDefaults` keys:
  - `backup.lastSuccessfulExportAt`
  - `patterns.backupReminderShown`
- Recorded `.success` only in the system file exporter's successful completion
  branch. Cancellation and failure explicitly preserve the previous date.
- Added a localized, VoiceOver-combined Settings row showing either the saved
  date or “Never” / “尚未備份”.
- Added the one-time local-only reminder to `PatternLibraryView`. `.existing`
  and `.needsSelection` outcomes never trigger it. Dismissing either action
  records the reminder as shown; the settings action presents the existing
  `BackupSettingsSection`.
- Regenerated `KnitNote.xcodeproj` so the new core source belongs to the
  generated app targets.

## TDD Evidence

### Core RED

`swift test --filter BackupHistoryTests`

Failed as expected before implementation with:

```text
error: cannot find 'BackupHistory' in scope
```

### Core GREEN

The same command passed 3 tests:

- successful export date persists across a new history instance;
- cancelled and failed exports preserve the prior successful date;
- reminder dismissal persists across a new history instance.

### UI RED

`swift test --filter BackupSettingsViewContractTests`

Failed with 14 expected issues because exporter-result recording, the Settings
date row, the one-time `.created` reminder, and the six localized keys were
absent.

### UI GREEN

`swift test --filter 'BackupHistoryTests|BackupSettingsViewContractTests'`

Passed 14 tests in 2 suites.

## Final Verification

- `swift test`
  - final rerun: 812 tests in 68 suites passed in 44.415 seconds;
  - an earlier run had one existing high-load timing failure in
    `exportSerializesProjectYarnAndJournalMutations`;
  - the failed test passed in isolation in 0.199 seconds and passed again in the
    final full parallel rerun; no unrelated gate code or test was changed.
- Fresh independent builds with `CODE_SIGNING_ALLOWED=NO`:
  - iOS app: exit 0;
  - macOS app: exit 0;
  - iOS Share Extension: exit 0;
  - watchOS app: exit 0.
- Localization catalog: `jq empty` passed and Xcode localization compilation
  passed in app builds.
- Generated Xcode project: `plutil -lint KnitNote.xcodeproj/project.pbxproj`
  passed.
- Scope scan found no notification center, CloudKit, recurring interval, or
  snooze additions in the Task 12 production files.
- `git diff --check` passed.
