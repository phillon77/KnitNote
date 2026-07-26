# Task 11 Report: Backup Manifest 2 and Pattern Round Trips

## Scope

Implemented only Task 11. KnitNote complete manual backups now use manifest
format 2 and preserve the archive-level pattern library. Task 12 backup history
and reminder behavior was not added. Storage remains local-first with manual
backup and restore; no cloud sync or tracking was introduced.

## Manifest 2

Format 2 adds:

- the exact `patternCount` shown in backup preview;
- a closed list of every regular file below `Data`;
- each file's canonical relative path, exact byte count, and lowercase SHA-256;
- the recognized critical feature `data-file-sha256`.

Format 1 continues to decode, preview with `patternCount == nil`, stage, restore,
and migrate legacy project-owned patterns to archive schema 10.

Validation rejects:

- unsupported manifest or archive versions and unknown critical features;
- absolute, traversal, backslash, hidden, empty-component, or noncanonical paths;
- duplicate paths and Unicode-normalized case collisions;
- symbolic links, unknown tree entries, and missing referenced files;
- manifest/physical file-set mismatch, size mismatch, or SHA-256 mismatch;
- duplicate asset, pattern, usage, project, or pattern-project identifiers;
- dangling asset, pattern, project, or yarn references;
- unsafe owned filenames, oversized files/packages, and invalid markup.

The external package is checked before staging. The app-owned staged copy is
checked again after bounded copying and immediately before installation.

## Included Pattern Data

The backup contains:

- `projects-v1.json`, including `PatternAsset`, `StoredPattern`, and every active
  or inactive `PatternProjectUsage`;
- each referenced original PDF or image under `Patterns/Assets`;
- each accepted usage markup page under `Patterns/UsageMarkup`;
- usage reading page, zoom, offset, highlight mode/positions, page notes, and
  project counter state stored in the archive;
- active usage ordering required by automatic project-cover fallback.

The backup does not contain thumbnail caches, PatternInbox data, candidates,
transaction journals, publication receipts, or quarantine artifacts.

## Transaction and Recovery Boundaries

The existing backup operation gate remains the single store boundary. Active
pattern or journal transactions reject export and restore. While replacement is
in progress, project, yarn, reader, markup, import, link, unlink, and deletion
mutations are rejected.

Restore remains:

1. nonmutating external-package inspection;
2. bounded copy into an app-owned staging directory;
3. staged-tree revalidation;
4. same-volume live-to-rollback rename;
5. staged-data-to-live rename;
6. store reload;
7. rollback and original reload on failure;
8. rollback cleanup only after the restored archive reloads successfully.

The transaction-gate race tests are serialized as a suite so their synchronous
injected latches cannot exhaust Swift's cooperative worker pool. Timeouts were
not enlarged, and every test still waits for the exact injected boundary before
asserting that mutations are rejected.

## TDD Evidence

First manifest RED:

```text
swift test --filter KnitNoteBackupManifestTests
error: KnitNoteBackupPreview has no member patternCount
error: cannot find KnitNoteBackupManifestFile in scope
error: extra arguments patternCount/files/criticalFeatures
```

Security RED:

```text
swift test --filter KnitNoteBackupServiceTests
error: KnitNoteBackupError has no member integrityMismatch
```

The new tests then drove the manifest model, archive-level path walker,
streaming integrity checks, staged revalidation, and schema-10 reference
validation. Mutation-backed integration tests export complete pattern state,
destroy the live projects/pattern/files, restore, and compare exact IDs, bytes,
reader states, notes, counters, markup, active/inactive relationships, and
cover-fallback relationship. Separate tests restore a real format-1 legacy
pattern package and prove corrupt format-2 preflight does not change live data.

## Verification

Focused tests:

- `swift test --filter KnitNoteBackupManifestTests`: 4 passed.
- `swift test --filter KnitNoteBackupServiceTests`: 56 passed.
- `swift test --filter KnitNoteBackup`: 60 passed.
- `swift test --filter JSONProjectStoreTests`: 69 passed.
- `swift test --filter PatternShareInboxEnqueuerTests`: 8 passed.

Full tests:

```text
swift test --quiet
785 tests in 67 suites passed
```

Fresh builds with separate DerivedData and `CODE_SIGNING_ALLOWED=NO`:

- iOS App: exit 0.
- macOS App: exit 0.
- iOS Share Extension: exit 0.
- watchOS App: exit 0.

Static verification:

- localization catalog parses as JSON;
- Xcode project, App/Share/Watch Info plists, and all entitlements pass
  `plutil -lint`;
- every touched Swift source parses with `xcrun swiftc -parse`;
- `git diff --check` passes.

## Files

- `Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift`
- `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`
- `Tests/KnitNoteCoreTests/KnitNoteBackupManifestTests.swift`
- `Tests/KnitNoteCoreTests/KnitNoteBackupServiceTests.swift`
- `Tests/KnitNoteCoreTests/JSONProjectStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternShareInboxEnqueuerTests.swift`
- `task-11-report.md`
