# Task 8 Report — Project-Side Linking and Import

## Scope

Implemented only project-side pattern linking, relinking, unlinking, and durable import from Files or the existing iOS camera capture flow. No Share Extension or other Task 9+ behavior was added.

## RED

- Added `ProjectPatternsViewContractTests` before changing the UI. The first focused run produced 14 issues across seven tests because the project add menu, library chooser, result screen, unlink confirmation, durable import flow, long-name rows, and VoiceOver contracts did not exist.
- Added `ProjectPatternLinkIndexTests` and `ProjectPatternImportStoreTests` before production APIs. The first run failed to compile because `ProjectPatternLinkIndex`, `ProjectPatternLinkOption`, and `importPatternFromProject` did not exist.
- Added the approved English and Traditional Chinese Task 8 strings to `LocalizationContractTests` before the catalog entries. The focused localization run failed on the missing keys.
- The first full regression exposed six historical source-contract expectations for the old `project.patterns` population source and the previous calculator/tool-before-journal layout. Those contracts were updated only after reproducing the failures, preserving their other layout and feature checks.

## GREEN

- Replaced the project pattern screen with rows backed by active `PatternProjectUsage` records. Rows include the owned thumbnail, full multi-line name, localized file type/page count, and a combined VoiceOver label.
- The project `+` menu has exactly two top-level choices: link from the pattern library or import a new pattern.
- Added a library chooser that excludes already-active links, marks inactive usages as relinkable, and allows the same collection to link to different active or completed projects.
- Swipe now presents a localized unlink confirmation and calls only `unlinkPattern`. The collection, owned asset, and per-project reading data remain stored, and relinking restores the same usage.
- Added durable project import through the inbox with `.project` origin and `targetProjectID`. Created, existing, and ambiguous migrated-duplicate outcomes all link without creating duplicate collections or assets.
- Files import keeps security-scoped access alive while durable enqueue completes. On iOS, the existing camera capture flow appears only when a camera is available; encoded data is written off the main actor to a uniquely owned temporary file, imported durably, and cleaned up.
- Completed projects can link, unlink, and relink, but their project reader context remains read-only.
- Project detail now derives pattern population from active usage records and follows the approved photo → pattern → notes → counters → journal priority. Existing tool and calculator cards remain below the journal.
- Added complete English and Traditional Chinese copy and adaptive iPhone, iPad, and macOS SwiftUI layouts.

## Verification

- Focused Task 8 UI and localization: 8 tests passed.
- Project linking, durable import, library lifecycle, and reader compatibility: 61 tests passed.
- Updated layout compatibility: 48 tests across five suites passed.
- Completed-project link/unlink/relink lifecycle: 1 focused test passed.
- Full regression: `swift test --quiet` passed 718 tests in 56 suites.
- Real iOS Simulator and macOS SwiftUI type-checks of every `KnitNote` and `Sources/KnitNoteCore` Swift file passed with zero errors. Existing Sendable warnings remain in backup and journal-photo services.
- `jq empty` passed for `Localizable.xcstrings`; Swift parse passed for every touched Swift file; `git diff --check` passed.

## Files

- `Sources/KnitNoteCore/Patterns/ProjectPatternLinkIndex.swift`
- `Sources/KnitNoteCore/Projects/JSONProjectStore.swift`
- `KnitNote/Patterns/ProjectPatternsView.swift`
- `KnitNote/Patterns/ChooseLibraryPatternView.swift`
- `KnitNote/Patterns/ChoosePatternProjectView.swift`
- `KnitNote/Patterns/PatternImportResultView.swift`
- `KnitNote/Projects/ProjectDetailView.swift`
- `KnitNote/Localization/Localizable.xcstrings`
- `Tests/KnitNoteCoreTests/ProjectPatternsViewContractTests.swift`
- `Tests/KnitNoteCoreTests/ProjectPatternLinkIndexTests.swift`
- `Tests/KnitNoteCoreTests/ProjectPatternImportStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternLibraryStoreTests.swift`
- `Tests/KnitNoteCoreTests/PatternReaderCounterContractTests.swift`
- `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- `Tests/KnitNoteCoreTests/EvenStitchAdjustmentViewContractTests.swift`
- `Tests/KnitNoteCoreTests/ProjectDetailLayoutContractTests.swift`
- `Tests/KnitNoteCoreTests/GaugeCalculatorViewContractTests.swift`
- `Tests/KnitNoteCoreTests/ProjectJournalViewContractTests.swift`
