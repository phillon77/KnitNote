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

## Files

- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- `task-4-report.md`

## Tests

- RED: `swift test --filter 'PatternLibraryStoreTests|PatternMarkupFileServiceTests'` — failed as expected for missing Task 4 APIs.
- Original GREEN focused: same command — 11 tests passed.
- Review-fix RED: the new empty staged-transaction test failed with `.unreadableArchive`, proving a no-op journal would block startup.
- Review-fix focused: same command — 23 tests passed.
- Full regression: `swift test` — 627 tests in 44 suites passed.
- `git diff --check` — passed.

## Concerns

Reader UI routing is intentionally untouched for Task 6. The deprecated-layout markup methods remain temporarily to keep the pre-existing Task 2/3 reader and migration paths compiling; the new Task 4 store and markup APIs do not use them.
