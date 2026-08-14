# Task 7 Report — Automated and Physical Acceptance Preparation

Status: **pre-gate contract fix complete / Task 7 pending**

## Current candidate and scope

- Starting HEAD for this narrow fix: `5a8fd54865faae7691d669d3a7ef0786108dd63d`.
- Branch: `feature/knitnote-1.5`.
- Task 6 final combined review is complete and clean at the starting candidate.
- This pre-gate fix changes only the stale YouTube Pattern Library source contract and verification reports/ledger. It does not perform the remaining Task 7 full-suite, builds, generated-project, verification-record, or physical-acceptance steps.

## Root cause and RED

- Task 5 split the list/import owner from `PatternLibraryView.swift` into `PatternLibraryCollectionView.swift` so folder scope could drive search and import destinations.
- `YouTubePatternLibraryContractTests` still read the old root file and required the obsolete one-line `AddYouTubePatternView(targetProjectID: nil)` source shape.
- Fresh isolated RED:

```bash
swift test --disable-sandbox --filter YouTubePatternLibraryContractTests
```

- Result before the contract correction: **8 tests / 1 suite, 7 issues**. Six issues came from the add-actions test and one from the locale test.
- Direct source inspection confirmed the production owner was correct: it retained separate file and YouTube actions, `targetProjectID: nil`, selected locale injection, and added `targetFolderID: destinationFolderID` backed by All/Uncategorized → nil and user-folder → UUID mapping.

## Narrow contract correction

- Both affected tests now read `PatternLibraryCollectionView.swift`.
- Existing behavior remains required: separate file/YouTube add controls, importer reachability, `targetProjectID: nil`, and selected-locale injection.
- Folder behavior is now explicitly required: `targetFolderID: destinationFolderID`, `.all`/`.uncategorized` map to nil, and `.folder(folderID)` maps to that UUID.
- No production source, generated project, localization catalog, or unrelated contract changed.

## GREEN evidence

- Isolated `YouTubePatternLibraryContractTests`: **8 tests / 1 suite PASS**.
- Exact Task 7 focused selection:

```bash
swift test --disable-sandbox --filter 'PatternFolder|PatternLibrary|PatternInbox|YouTubePattern|KnitNoteBackup|LocalizationContract|RuntimeLocalization'
```

- Result: **382 tests / 22 suites PASS in 8.279 seconds**.
- `git diff --check`: PASS.
- No full Swift suite, XcodeGen, app/extension/watch build, archive, export, install, network, upload, submission, merge, push, or release action was run.

## Remaining Task 7 gates

- Deterministic XcodeGen confirmation and any resulting generated-project decision.
- One complete Swift suite and unsigned iOS, macOS, watchOS, and Share Extension builds.
- Static schema-12 → schema-13 data-preservation evidence and exact verification record.
- Physical iPhone, iPad, Mac, VoiceOver, Dynamic Type, live language-switch, orientation/window-resizing, and existing-data preservation acceptance on an exact binary.
