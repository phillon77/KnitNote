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

## Task 7 automated gate attempt — fail-closed blocker

Status at `2026-08-14 11:31:25 CST`: **BLOCKED / no full-suite result / remaining gates not started**

- Exact candidate: `c5b226672ff5d4c512859b84ecacaa42c974783a`.
- Fix Round 1 was independently review-clean before this attempt: SPEC PASS / QUALITY PASS, no findings; exact focused gate **382 tests / 22 suites PASS**.
- XcodeGen was executed twice at this candidate. The project hash before, between, and after generation was identical: `c3b2be0d83aef5a900f01c53cc02f6b7a0f631deab97eeb5dce6fff7645b560f`. `KnitNote.xcodeproj/project.pbxproj` has no diff, and `git diff --check` passed.
- Exactly one complete-suite command was started, with temporary module-cache variables only to keep SwiftPM writes inside `/tmp`:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/KnitNoteTask7ModuleCache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/KnitNoteTask7ModuleCache \
swift test --disable-sandbox
```

- The build completed and the Swift Testing run began, but no final test count, issue count, duration, or exit code was produced.
- Retained process evidence at the 26-minute checkpoint:
  - `swift-test` PID `87753`: elapsed `26:04`, CPU `0:00.46`, state `Ss`.
  - `swiftpm-testing-helper` PID `87807`: elapsed `26:02`, CPU `0:11.26`, state `S`.
- A non-destructive one-second sample at about 15 minutes identified active stacks in:
  - `ShareExtensionTargetContractTests.activationRuleAcceptsExactlyOneSupportedFileAndNothingElse()`
  - `PatternShareImportPresentationTests.selectorAcceptsExactlyOneSupportedFileProvider(typeIdentifier:)`
  - related parameterized `PatternShareImportPresentationTests` provider-selection cases.
- Those stacks were inside Foundation `NSPredicate` / UTType conformance evaluation and LaunchServices `_LSContextInit`, waiting on `_os_unfair_lock_lock_slow` / `__ulock_wait2`. At 26 minutes the helper CPU total was unchanged at `11.26` seconds and the session still had no new output.
- The retained full-suite process was **not killed, interrupted, duplicated, or restarted**.
- Fail-closed consequence: there is no fresh complete-suite PASS. The four unsigned target builds, schema-12 migration probe, built identity inspection, `PatternFoldersNextVersionVerification.md`, acceptance commit, connected-device inspection, and every physical checklist item were deliberately not started.
- No archive, export, install, launch, data erase, upload, App Store Connect action, submission, push, merge, or release action occurred. Preserved untracked paths and the existing stash were not changed.

## Pre-gate contract Fix Round 1

- Independent review of candidate `a4b4cfcfaa1bc0b6f631849deba13db7d6489ceb` was **BLOCKED** by two Important test-only findings. Production remained correct.
- I-1: file-wide destination case tokens did not prove the `destinationFolderID` result bodies and could be satisfied by `scopeTitle` decoys.
- I-2: file-wide locale presence did not bind the reactive locale to `AddYouTubePatternView` because the Move sheet contained the same modifier. The generic menu assertion was also tightened so the sort menu cannot satisfy the add-menu contract.
- The corrected contract uses fail-closed source slices around the exact add-action menu, file import method, destination property, and AddYouTube sheet. It preserves all file/YouTube action, project-nil, folder-destination, and reactive-locale requirements.

### Mutation RED evidence

- All/Uncategorized returning `UUID()` instead of nil: **1 intended issue**.
- User-folder branch returning nil instead of `folderID`: **1 intended issue**.
- Entire destination switch removed while `scopeTitle` case-label decoys remained: **2 intended issues**.
- YouTube locale modifier removed while the Move sheet retained its locale modifier: **1 intended issue**.
- YouTube sheet given a fixed English locale: **1 intended issue**.
- Add menu changed to `Group` while the sort `Menu` remained: fail-closed start-marker **1 intended issue**.

### Restored-source GREEN

- Production source restored with no diff.
- Isolated `YouTubePatternLibraryContractTests`: **8 tests / 1 suite PASS**.
- Exact Task 7 focused selection: **382 tests / 22 suites PASS in 8.770 seconds**.
- No full suite, XcodeGen, build, production/project/catalog, archive, export, install, network, upload, submission, merge, push, or release action ran or changed.
- Fix Round 1 is **implementation complete / review-pending**. Do not resume remaining Task 7 gates until fresh review clears this candidate.

## Full-suite LaunchServices deadlock fix

Status: **implementation complete / review-pending**

- Starting candidate: `c5b226672ff5d4c512859b84ecacaa42c974783a`.
- After the retained 27-minute full-suite process was terminated with authorization, the saved sample showed one test synchronously waiting for a LaunchServices XPC reply in `_LSCopyServerStore`, while concurrent parameterized UTType checks waited on the `_LSContextInit` unfair lock. Swift Testing runs suites and parameterized cases concurrently, so `.serialized` on either suite would not create a cross-suite boundary.
- Deterministic RED 1: `LaunchServicesTestSerializationTests.launchServicesCallersShareOneSerializationBoundary` failed with exactly two issues because the Share target contract and Pattern Share presentation tests had zero calls to a shared gate.
- Deterministic RED 2: the concurrent gate behavior test failed to compile with `cannot find 'LaunchServicesTestGate' in scope` before the test-only mechanism existed.
- A first synchronous `NSLock` gate passed its isolated 32-way critical-section probe, but a combined affected-suite run still did not finish in about 55 seconds, and the isolated Pattern Share presentation suite still did not finish in about 45 seconds. Both were interrupted; no indefinite test was left running. This disproved the blocking-lock implementation: cooperative test tasks waiting synchronously on the lock can occupy executor threads needed by the lock holder's LaunchServices path.
- An independent one-shot process evaluating `UTType("public.png")!.conforms(to: .png)` returned `true` in 1.9 seconds, excluding a generally unavailable LaunchServices service.
- The minimal correction is test-only: one actor-backed `LaunchServicesTestGate` suspends waiters instead of blocking cooperative executor threads. The four Pattern Share selector/provider test entry points and the Share activation-predicate test use that same process-wide gate. Production behavior and source are unchanged.

### GREEN evidence

- Gate contract and 32-way concurrent critical-section probe: **2 tests / 1 suite PASS in 0.096 seconds**.
- Previously hanging isolated `PatternShareImportPresentationTests`: **12 tests / 1 suite PASS in 0.102 seconds**.
- Combined affected suites plus gate tests, five consecutive bounded runs: **17 tests / 3 suites PASS** each in `0.198`, `0.199`, `0.196`, `0.198`, and `0.184` seconds; repeated runs had a 30-second process timeout.
- Exact Task 7 focused selection: **382 tests / 22 suites PASS in 8.915 seconds**.
- No production source, project, catalog, full-suite rerun, build, archive, export, install, upload, submission, merge, push, or release action was performed by this fix.
- The complete Swift suite and all later Task 7 gates remain pending until independent review clears this test-only fix.

## LaunchServices fix — Review Fix Round 1

Status: **implementation complete / review-pending**

- Starting candidate: `52213c47407ea418b22411dab741cb0959665c2f`.
- Review confirmed the actor gate and current coverage, but blocked the token-count source contract because wrapper removal plus comment decoys, or a new ungated UTType path, could preserve its expected counts.
- The actor gate now exposes the explicit test-only boundary `await LaunchServicesTestGate.shared.withLock { ... }`; its suspension and non-reentrant synchronous-operation behavior are unchanged.
- The replacement structural audit removes comments and string contents before parsing, finds only real shared-gate closure ranges, and requires every relevant `NSPredicate`, predicate evaluation, `UTType`, activation-context call, direct `NSItemProvider`, Pattern Share selector, and provider-selection call to fall within a gate. The existing `activationContext` helper is allowed only because every call to that helper is gated.

### Mutation RED evidence

- Removing a real Pattern Share wrapper and adding a comment containing the complete gate token: **1 intended issue**, `ungated attachment selector`.
- Adding a new direct ungated `UTType.png.conforms(to:)` test while retaining every existing wrapper: **1 intended issue**, `ungated UTType`.
- Replacing the Share activation wrapper with a compiling `do` block and adding the complete gate token only in a comment: **1 failed expectation** listing the missing shared gate and every activation predicate/UTType/context path as ungated.

### Restored-source GREEN evidence

- Structural contract plus 32-way actor exclusivity probe: **2 tests / 1 suite PASS in 0.096 seconds**.
- Five consecutive combined bounded runs: **17 tests / 3 suites PASS** each in `0.209`, `0.191`, `0.185`, `0.200`, and `0.196` seconds; every run had a 30-second timeout.
- Exact Task 7 focused selection: **382 tests / 22 suites PASS in 9.078 seconds**.
- No production source, project, catalog, full-suite run, build, archive, export, install, upload, submission, merge, push, or release action was performed.
- The complete Swift suite and remaining Task 7 gates stay pending until fresh review clears this round.
