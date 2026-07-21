# KnitNote Complete Backup and Restore Design

Date: 2026-07-20
Status: Approved design

## Goal

Give people a simple way to export all user-created knitting data to one backup document and restore it later on iPhone, iPad, or Mac. Version 1 restores by completely replacing the current KnitNote data set. It does not merge records or provide automatic cloud synchronization.

## User experience

The Settings screen gains a localized `Data Backup` section with two rows:

- `Export Complete Backup`
- `Restore from Backup`

Export opens the system file exporter with a suggested name containing the date. The result uses the `.knitnote-backup` extension and appears as one document in Files and Finder.

Restore opens the system file importer. After KnitNote validates the selected document, it presents a summary containing:

- backup creation date;
- project count;
- yarn count;
- a clear warning that current KnitNote data will be replaced.

The user must confirm the replacement. Controls remain disabled while export or restore is running. Success and failure use short, localized alerts. Failed validation never reaches the confirmation or replacement stage.

## Backup format

Version 1 uses an Apple file package with a custom `.knitnote-backup` document type. This avoids a third-party ZIP dependency while allowing binary photos and pattern files to remain as files rather than expanding them into base64 JSON.

The package contains:

```text
manifest.json
Data/
  projects-v1.json
  ProjectPhotos/
  YarnPhotos/
  ProjectJournalPhotos/
  Patterns/
```

`manifest.json` contains a format version, creation date, app version, project count, and yarn count. The `Data` tree mirrors KnitNote's managed Application Support layout. Only the five known data locations are exported; cache files, temporary files, unknown files, device permissions, and device-local language selection are excluded.

The project archive supplies the authoritative list of user records. The referenced media include project photos, yarn photos, journal originals and thumbnails, pattern PDFs/images, and pattern markup JSON. Pattern reading state, page notes, counters, row notes, project completion state, calculator-related project data, and captions already live in `projects-v1.json` and therefore travel with the archive.

## Architecture

`KnitNoteBackupManifest` is a Codable value owned by KnitNoteCore. It defines format version 1 and the summary shown before restore.

`KnitNoteBackupService` owns filesystem work. It receives an explicit live data root and temporary root so tests can use isolated directories. Its responsibilities are:

- create a consistent backup package from the known live data locations;
- decode the manifest and project archive;
- validate package structure and referenced content;
- stage an imported package outside the live data directory;
- atomically replace the live data root with rollback protection.

`KnitNoteBackupTransfer` is the SwiftUI `Transferable` adapter. Its CoreTransferable `FileRepresentation` passes the already validated package URL to the system exporter with access to the original file, avoiding a `FileWrapper` copy of the package in memory. The app keeps that source package alive until export completes or is cancelled. UI code does not parse project JSON or directly move live files.

`JSONProjectStore` gains an explicit reload operation. After a successful filesystem replacement it reloads `projects-v1.json`, republishes projects and yarns, and reconciles managed photo directories. A restore is not reported as successful until this reload succeeds.

## Export consistency

Export first reads and decodes `projects-v1.json`. It then copies only files referenced by that archive into one new temporary `.knitnote-backup` package. It does not copy orphaned media. The temporary package is validated with the same validator used for import before its file URL is offered to the exporter as one document. This file-based handoff keeps export memory use independent of the package's media size.

The export operation runs off the main thread except for reading the store's stable public state and presenting SwiftUI UI. It never mutates live data.

## Import validation

Validation must finish before showing the destructive confirmation. It rejects:

- an absent or undecodable manifest;
- a backup format newer than the app supports;
- an absent, unreadable, or unsupported project archive;
- manifest counts that do not match the archive;
- duplicate project or yarn identifiers;
- invalid yarn-to-project links;
- unsafe file names, absolute paths, parent traversal, or symbolic links;
- missing referenced project, yarn, journal, or pattern files;
- files placed outside the known package locations;
- malformed pattern markup JSON;
- unreasonable aggregate or individual file sizes.

Extra unreferenced content is rejected instead of installed. This keeps the restore surface deterministic and prevents an imported package from smuggling arbitrary files into Application Support.

## Atomic replacement and rollback

Restore uses three roots on the same volume: live, staged, and rollback.

1. Build and fully validate `staged` without touching live data.
2. Rename the existing live root to `rollback`.
3. Rename `staged/Data` to the live root.
4. Ask `JSONProjectStore` to reload and validate the installed archive.
5. Delete `rollback` only after reload succeeds.

If any operation after step 2 fails, remove the incomplete live root, rename `rollback` back to live, and reload the original store. The app reports failure only after rollback has been attempted. Temporary and rollback directories are cleaned on the next launch if an interrupted operation left them behind; the presence of a rollback directory is resolved conservatively in favor of keeping the last known live data.

## Concurrency and interaction safety

Backup and restore operations are serialized. During confirmed restore, Settings disables its backup controls and the store rejects or prevents concurrent mutations until replacement finishes. The implementation must not capture a half-written journal photo transaction or permit a counter update between archive validation and live replacement.

The first version can enforce this by coordinating all store mutations and backup lifecycle through the main-actor `JSONProjectStore`, while filesystem copying and validation use immutable snapshots off the main actor.

## Localization and accessibility

All new section titles, buttons, summaries, warnings, progress states, and errors are added to the string catalog in Traditional Chinese and English. File names use a locale-neutral safe prefix plus an ISO date. Buttons retain semantic labels and Dynamic Type support; warnings do not rely on color alone.

## Error handling

User-facing errors distinguish:

- unable to create backup;
- backup damaged or incomplete;
- backup created by a newer unsupported version;
- insufficient storage or file access failure;
- restore failed but original data was preserved;
- restore and rollback both failed, which requires a prominent recovery message.

Internal errors retain detailed causes for tests and diagnostics without exposing filesystem paths to users.

## Testing

Core tests cover manifest encoding, complete export, referenced-file selection, each validation failure, size limits, path traversal, symlink rejection, atomic replacement, simulated failures at every replacement step, successful reload, and rollback recovery.

Store tests cover explicit reload and mutation exclusion during backup/restore. View contract tests verify the Settings section, both localized actions, destructive confirmation, disabled progress state, and success/error presentation. Final verification runs the full Swift test suite, localization-key checks, project generation consistency if needed, and iOS/macOS builds supported by the environment.

## Not included in version 1

- merging a backup into existing records;
- selecting individual projects to restore;
- automatic scheduled backups;
- iCloud synchronization or conflict resolution;
- restoring operating-system permissions or device-local language selection;
- compatibility guarantees for manually modified backup packages.
