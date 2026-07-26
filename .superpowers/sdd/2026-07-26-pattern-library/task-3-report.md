# Task 3 Report: Owned Asset Storage and Durable Import Inbox

## Scope

Implemented only Task 3. No UI, localization, Share Extension target, or Xcode project changes were made.

## RED

1. Added focused tests for inbox restart/byte preservation, empty and disguised-file rejection, SHA-256 duplicate reuse, retained ambiguous migrated duplicates, and explicit selection retry.
2. Ran `swift test --filter PatternImport` before production implementation.
3. It failed because `PatternInboxFileService`, `PatternInboxItem`, `PatternImportOutcome`, `PatternStorageLocations`, and `JSONProjectStore.processPatternInboxItem` did not exist.

## GREEN

Implemented:

- `PatternStorageLocations`: private Application Support pattern assets, iOS App Group inbox with a throwing missing-container path.
- `PatternInboxItem` and `PatternImportOrigin` Codable durable sidecars.
- `PatternInboxFileService`: candidate copy, size/type/content validation, atomic item + sidecar publication, safe reload, and removal after publication.
- `PatternFileService`: SHA-256 metadata, owned `Patterns/Assets/<assetID>.<ext>` installation, byte-checked reuse, and export URL access.
- `PatternImportCoordinator`: detached validation/hash preparation, deterministic asset identifiers, and normalized-name matching support.
- `JSONProjectStore.processPatternInboxItem`: active pattern transaction accounting, current-array duplicate resolution after detached work, archive publication before inbox deletion, asset cleanup on persistence failure, optional project usage creation, and deterministic ambiguous outcomes.

The persistence path now validates the complete pattern library snapshot and advances `dataGeneration` on successful publication.

## Verification

- `swift test --filter PatternInboxFileServiceTests` — PASS (2 tests)
- `swift test --filter PatternImportCoordinatorTests` — PASS (3 tests)
- `swift test --filter PatternFileServiceTests` — PASS (3 tests)
- `swift test` — PASS (582 tests, 44 suites)
- `git diff --check` — PASS

## Files

- Replaced `Sources/KnitNoteCore/Patterns/PatternFileService.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternStorageLocations.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternInboxItem.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternInboxFileService.swift`
- Added `Sources/KnitNoteCore/Patterns/PatternImportCoordinator.swift`
- Modified `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- Added `Tests/KnitNoteCoreTests/PatternInboxFileServiceTests.swift`
- Added `Tests/KnitNoteCoreTests/PatternImportCoordinatorTests.swift`
- Extended `Tests/KnitNoteCoreTests/PatternLibraryTestSupport.swift` with the requested injected-root `PatternImportHarness`.

## Concerns

- The existing project-scoped `PatternDocument` APIs remain temporarily for source compatibility; Task 4 is responsible for moving caller/UI paths to the library pipeline.
- The App Group location is deliberately injected in tests and extension contexts. `PatternStorageLocations.live()` throws on iOS if the configured group is unavailable and does not substitute an unrelated directory.
