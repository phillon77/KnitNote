# Task 12 Report: Backup Reminder and Last Successful Date

## Scope

Implemented the canonical Task 12 behavior from the approved brief, plan, and
design:

- persist the last successful manual export date;
- update it only after `.fileExporter` reports success;
- show one local-storage reminder after the first `.created` pattern from any
  supported import entry point;
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
- Added one shared `PatternBackupReminderCoordinator` and one app-owned
  presenter. The library importer, project importer, and Share Extension inbox
  processor all feed their durable import outcomes through that presenter.
  `.existing`, `.needsSelection`, cancellation, and failure never trigger the
  reminder. Dismissing either action records the reminder as shown before the
  settings route can open; the settings action presents the existing
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

`swift test --scratch-path /tmp/KnitNoteTask12Green --filter 'BackupHistoryTests|BackupSettingsViewContractTests'`

Passed 17 tests in 2 suites, including:

- all three `.created` import entry points schedule the same one-shot reminder;
- `.existing`, `.needsSelection`, cancellation, and failure do not schedule it;
- dismissal persists `patterns.backupReminderShown` before opening Settings.

## Final Verification

- `swift test --scratch-path /tmp/KnitNoteTask12Green`
  - final rerun: 815 tests in 68 suites passed in 39.246 seconds.
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
