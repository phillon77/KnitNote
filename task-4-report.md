# Task 4 Report — Pattern Lifecycle and Reader Mutations

## RED

Added `PatternLibraryStoreTests` and converted markup file tests to the usage-ID API. The first focused run failed because the required lifecycle and usage-owned markup interfaces did not exist. The failures named missing `linkPattern`, `unlinkPattern`, `deletePatternPermanently`, usage-based reader mutation APIs, and `PatternMarkupFileService` usage-ID APIs.

## GREEN

- Implemented one stable usage per `(patternID, projectID)`, including inactive usage reactivation with preserved ID, sort order, reading state, page notes, and markup.
- Added usage-owned reader state, page-note, and markup writes; inactive and completed-project usages reject writes.
- Made unlink idempotent and non-destructive.
- Made project deletion remove every active/inactive usage and its usage markup while preserving library patterns and assets.
- Added permanent-delete protection for active links, removal of inactive usages/markup, shared-asset retention, and staged file deletion with archive-persistence rollback.
- Kept the pre-library markup calls only as compatibility paths for the existing Task 2/3 callers; all new Task 4 paths are keyed by usage ID.

## Deletion-recovery review fix

- Replaced the in-memory deletion staging with a durable, checksummed transaction journal. Each journal records its UUID, phase, exact canonical relative paths, staging names, and usage/asset metadata.
- Startup recovery runs before archive validation. If the archive still references a journal item it restores staged files; otherwise it finalizes the deletion. Invalid or unsafe artifacts make the archive unreadable and keep mutations blocked.
- Journal and markup roots are physically validated, symlinked roots are rejected, and no-op deletions write no journal.
- Added fresh-store tests for pre-publication rollback and post-publication cleanup of both project and permanent-pattern deletion, plus two-project state/markup isolation, persistence rollback, relink persistence, inactive-write rejection, malformed journals, no-op staging, and symlink safety.

## Second review fix

- Closed the completed-project bypass in the project-scoped legacy reader APIs. Store writes now throw `PatternLibraryMutationError.projectCompleted`; direct `StoredProject` legacy state and note mutations remain no-ops, matching their existing non-throwing contract.
- Centralized physical path validation in `PatternMarkupFileService`. Usage and legacy read/save/delete paths, legacy-copy routing, and deletion transactions all reject symlinked or non-canonical roots, subdirectories, and existing page files.
- Added regression coverage for all completed legacy reader writes (state, highlight, note, markup), exact archive/markup byte preservation after a fresh reopen, active-project writes, direct model no-op behavior, and usage/legacy symlink targets remaining untouched.

## Final markup-copy review fix

- Replaced recursive legacy markup directory copying with a whitelist copier. Only canonical, non-symlink, regular `0.json`, `1.json`, and later numeric page files are accepted; unexpected files, directories, and symlinks reject migration with `PatternMarkupFileError.unsafePath`.
- Each approved source page is revalidated and written atomically to a validated usage-owned destination page. This leaves no path that follows a legacy page or nested-directory symlink.
- Added multi-page copy coverage, unexpected-file rejection, and on-disk migration regressions for page-file and nested symlinks. Both prove the legacy archive/tree and external target stay unchanged and no `UsageMarkup` installation occurs.

## Files

- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Sources/KnitNoteCore/Projects/StoredProject.swift`
- `Sources/KnitNoteCore/Patterns/PatternMarkupFileService.swift`
- `Tests/KnitNoteCoreTests/PatternDocumentTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternMarkupFileServiceTests.swift`
- `task-4-report.md`

## Tests

- RED: `swift test --filter 'PatternLibraryStoreTests|PatternMarkupFileServiceTests'` — failed as expected for missing Task 4 APIs.
- Original GREEN focused: same command — 11 tests passed.
- Review-fix RED: the new empty staged-transaction test failed with `.unreadableArchive`, proving a no-op journal would block startup.
- Review-fix focused: same command — 23 tests passed.
- Full regression: `swift test` — 627 tests in 44 suites passed.
- `git diff --check` — passed.
- Second review RED: the focused legacy reader and markup tests failed as expected: completed project-scoped writes changed archive/markup data and symlinked roots were followed.
- Second review focused: `swift test --filter 'PatternDocumentTests|PatternMarkupFileServiceTests|PatternLibraryStoreTests'` — 46 tests passed.
- Second review full regression: `swift test` — 632 tests in 44 suites passed.
- Second review final diff check: `git diff --check` — passed.
- Final markup-copy RED: page-file and nested legacy markup symlink migrations completed and modified the archive, proving recursive copying was unsafe.
- Final markup-copy focused: `swift test --filter 'PatternMarkupFileServiceTests|PatternLibraryMigrationTests'` — 31 tests passed.
- Final markup-copy full regression: `swift test` — 636 tests in 44 suites passed.
- Final markup-copy final diff check: `git diff --check` — passed.

## Concerns

Reader UI routing is intentionally untouched for Task 6. The deprecated-layout markup methods remain temporarily to keep the pre-existing Task 2/3 reader and migration paths compiling; the new Task 4 store and markup APIs do not use them.
