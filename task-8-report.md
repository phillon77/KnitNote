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

## Review Fix Round 1

- Added an executable PBX membership test that resolves native targets, Sources phases, build files, and file references instead of grepping comments. It proved the new Task 8 files were absent from the App target.
- The first genuine Xcode builds exposed 15 cumulative Task 5–7 pattern sources that were already consumed by production but still absent from the canonical project. Added those sources to the App target and only the eight shared Core dependencies required by the existing Watch `JSONProjectStore`; App UI, library presentation, reader context, and Task 8 sources remain excluded from Watch. The membership test also rejects duplicate source membership.
- Reproduced the import transaction gap with a blocked inbox move: backup export and restore both entered while the candidate copy was in flight, and export could remove the candidate. One outer async pattern transaction now owns enqueue → prepare → publish, while public processing owns its own non-nested transaction scope. Success, injected failure, and cancellation all release the gate.
- Added a pure operation coordinator with executable tests for replacement, cancellation, and stale-result rejection. `PatternImportResultView` stores one task, cancels before replacement, cancels from the toolbar and on disappearance, and publishes UI state only for the current operation identity.
- Files picker failures are no longer ignored. Every pattern-file, inbox, library/store, picker, cancellation, and fallback failure maps to concise localized presentation instead of `localizedDescription`. The error alert exposes the localized message to VoiceOver.
- Added exact English and Traditional Chinese copy for empty, oversized, invalid, storage, missing-project, cancelled, picker, and fallback failures.

## Review Fix Round 1 Verification

- Membership RED failed for the missing App and shared Watch Core sources; the final executable membership test passed with no duplicate source entries.
- Transaction RED allowed both export and restore during blocked enqueue. Three success/failure/cancellation transaction tests passed after the fix, and 52 import/library/fault compatibility tests passed.
- Operation coordinator RED failed to compile because the type did not exist. Two coordinator tests and the identity-checked UI wiring contract passed after the fix.
- Error mapping RED failed to compile on the missing mapper/context/message types, and localization/UI contracts failed on missing catalog entries and ignored picker failures. The final presentation, UI, localization, and membership focused run passed 14 tests.
- Full regression after the review fixes: `swift test --quiet` passed 727 tests in 58 suites.
- Canonical `xcodebuild` Debug builds passed for both the generic iOS Simulator `KnitNote` scheme (including its Watch dependency) and the generic macOS `KnitNote` scheme with code signing disabled.

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
