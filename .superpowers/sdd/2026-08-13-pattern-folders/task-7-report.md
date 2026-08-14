# Task 7 Report — Automated and Physical Acceptance Preparation

Status: **FINAL REVIEW FIX ROUND 1 IMPLEMENTATION COMPLETE / REVIEW-PENDING / PRIOR AUTOMATED EVIDENCE SUPERSEDED / PHYSICAL PENDING**

## Current state

- Final whole-branch review at `d00bb36c93368b517987f033f91ebaec08a7fc1c` found one Important persisted folder-name invariant gap and six Minor coverage/report/whitespace findings.
- The implementation closes those findings in the working candidate. The earlier 1523-test and unsigned-build evidence remains historical evidence for `ef6c0c2`, not acceptance of the new source.
- A fresh focused review is required before any replacement full suite/build run. All physical checklist items remain unchecked.

## Final whole-branch review Fix Round 1

Status: **implementation complete / review-pending / later gates remain blocked**

- Root cause: folder-name policy was enforced only by create/rename callers using a UI-supplied context. Schema-13 archive decoding and backup validation only checked identifiers and trimmed nonempty names, so persisted duplicate canonical names and translated reserved All/Uncategorized names bypassed the invariant.
- Design: `PatternLibrarySnapshot` is the single persistence validation boundary. A shipping `PatternFolderNameContext` resolves the two reserved-name keys from every exact supported `.lproj` in the compiled String Catalog bundle; no translated-name table is embedded in Swift and user names are never translated or rewritten.
- Current archive decode/migration validation, backup validation/staging/live-root validation, and public restore now pass the same context through that boundary. Folder-bearing snapshots fail closed if the context is unavailable. Pre-schema-13 migration still creates no folders, and orphan folder membership still normalizes to Uncategorized.
- Behavioral no-publication coverage preserves malformed archive bytes, published folders/patterns, data generation, and caller selection after rejected current-archive reload or public restore. Backup staging rejects malformed names before publishing a live root.
- Minor findings closed: whitespace-only create/rename publication checks; deletion of two matching patterns while retaining one unrelated pattern; `.createNew` duplicate import preserves the captured folder destination; Share and project imports explicitly retain nil destinations; final-report chronology is ordered; the canonical design file has no extra EOF blank line.
- RED: the first new boundary test did not compile before the `nameContext` validation API existed. With snapshot name validation deliberately disabled, the behavioral suite produced **7 intended issues** across current-archive reload, backup staging, and public restore; restoring the boundary removed all seven.
- GREEN: focused fix selection **13 tests / 4 suites PASS**; key no-publication selection **4 tests PASS**; data/backup/store/import selection **292 tests / 4 suites PASS in 3.604 seconds**; final exact Task 7 focused selection **387 tests / 22 suites PASS in 8.260 seconds**.
- Static release audit PASS, both reserved-name catalog queries report all 13 localizations, `git diff --check` PASS, and whole-branch `git diff 0c728eeb... --check` PASS.
- No complete 302-second suite, XcodeGen, build, archive, export, device action, upload, submission, merge, push, or release action ran in this round. Fresh independent review is required before resuming later gates.

## Historical chronology

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

## LaunchServices fix — Review Fix Round 2

Status: **implementation complete / review-pending**

- Starting candidate: `b9b7a1d18e02d49cc93f41223d998ba527de9db2`.
- Fix Round 1 re-review confirmed the actor and current coverage but found that exact-byte hazard spellings could be bypassed by valid Swift whitespace and by executable expressions inside string interpolation.
- The byte-pattern scanner was replaced rather than patched. The new minimal Swift token lexer ignores nested comments and inert string content, tokenizes executable interpolation expressions (including nested parentheses/strings and raw-string hash delimiters), normalizes whitespace naturally through token sequences, and derives gate/function brace ranges from tokens.
- Hazard detection now follows identifier/member tokens rather than exact source formatting. Spaced `NSPredicate`, `UTType`, selector/provider calls, and interpolation-executed UTType references cannot bypass the shared actor boundary; inert comments and plain string decoys remain ignored.

### RED and mutation evidence

- Persistent token-audit test against the old scanner: **4 intended issues** because spaced NSPredicate, two UTType paths, spaced selector, and spaced provider hazards all produced zero detected counts while the inert decoys and valid gate remained present.
- Actual compiled temporary mutation added all four valid spaced forms plus `"\(UTType.png.identifier)"` outside the gate. The structural contract failed with one expectation listing exactly five hazards: one `NSPredicate`, two `UTType` paths, one attachment selector, and one provider selection.

### Restored-source GREEN evidence

- Current source audit, token-lexer regression, and 32-way actor exclusivity probe: **3 tests / 1 suite PASS in 0.097 seconds**.
- Five consecutive combined bounded runs: **18 tests / 3 suites PASS** each in `0.199`, `0.185`, `0.196`, `0.185`, and `0.192` seconds; every run had a 30-second timeout.
- Exact Task 7 focused selection: **382 tests / 22 suites PASS in 8.873 seconds**.
- The actor, current gate call sites, production source, project, and catalog are unchanged. No full-suite run, build, archive, export, install, upload, submission, merge, push, or release action was performed.
- The complete Swift suite and remaining Task 7 gates stay pending until fresh review clears this round.

## Reviewed LaunchServices fix and replacement full-suite result

Status: **BLOCKED / complete suite failed / later gates not started**

- Exact reviewed candidate: `485c14bae8f41ade72b126846616161a5f1a7b0d`.
- Independent review of the LaunchServices token-audit fix: **SPEC PASS / QUALITY PASS**, no findings, full-suite resume clearance YES.
- The previous hung PIDs were absent before starting this run.
- Focused current gate supplied at this exact HEAD: **382 tests / 22 suites PASS**.
- Exactly one replacement complete-suite run was started, with output retained at `/tmp/KnitNotePatternFolders-full-485c14b.log`:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/KnitNoteTask7ModuleCache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/KnitNoteTask7ModuleCache \
swift test --disable-sandbox
```

- It completed normally without the prior LaunchServices hang. Authoritative Swift Testing summary: **1523 tests / 128 suites FAILED after 302.510 seconds with 3 issues**.
- The surrounding `tee` pipeline exited `0`; this is not treated as a test PASS because the retained Swift Testing summary explicitly says FAILED.
- Three failing contracts:
  1. `PatternReaderCounterContractTests.everyPatternManagedFileWriteRoutesThroughTheStoreCoordinator`, line 401, still reads `PatternLibraryView.swift` and therefore misses `store.importPatternFromLibrary(` after Task 5 moved the import owner to `PatternLibraryCollectionView.swift`.
  2. `WatercolorThemePolicyTests.otherPrimaryScreensKeepTheGenericWatercolorBackground`, line 42, still requires `WatercolorBackground()` in the old root; the collection screen owns the background after the adaptive split.
  3. `BackupSettingsViewContractTests.createdLibraryImportShowsOneLocalOnlyReminderAndDismissalPersistsIt`, line 114, still reads the old root and therefore misses `backupReminderPresenter.accept(outcome)` in the collection owner.
- Direct source inspection confirms all three intended product behaviors remain in `PatternLibraryCollectionView.swift`. This evidence identifies stale source-owner contracts; it does not establish a production defect.
- Fail-closed consequence: the four unsigned builds, schema-12 migration probe, built identity inspection, verification record/commit, device availability inspection, and all physical acceptance items were not started.
- No archive, export, install, launch, uninstall, erase, upload, App Store Connect action, submission, merge, push, or release action occurred.

## Stale-owner fix review and final automated preparation

Status: **AUTOMATED PASS / PHYSICAL PENDING**

- Exact source candidate: `ef6c0c2cf1e69c4f38eaecfe2005888e31d72726`.
- Stale-owner test-only fix independent review: **SPEC PASS / QUALITY PASS**, no findings, full-suite rerun clearance YES.
- Exact focused selection at this candidate: **382 tests / 22 suites PASS**.
- Fresh retained complete-suite run: **1523 tests / 128 suites PASS in 302.308 seconds**, true pipefail exit `0`; log SHA-256 `06de93db46cd435e410bf0b961af135ca3ac4dc634c98aaf750fd971ae0e6d9f`.
- Two consecutive XcodeGen runs were byte-stable at SHA-256 `c3b2be0d83aef5a900f01c53cc02f6b7a0f631deab97eeb5dce6fff7645b560f`; generated project unchanged.
- Exact unsigned builds:
  - iOS Simulator: PASS, `** BUILD SUCCEEDED **`.
  - macOS: PASS, `** BUILD SUCCEEDED **`.
  - watchOS Simulator: PASS, `** BUILD SUCCEEDED **`.
  - Share Extension: PASS, `** BUILD SUCCEEDED **`; used existing `KnitNoteShare` scheme because current Xcode rejects the plan's `-target` plus `-derivedDataPath` combination before compilation.
- The first sandboxed iOS attempt failed during Watch asset compilation because sandboxing disconnected CoreSimulatorService; the exact command rerun outside the sandbox passed. This diagnostic attempt is not counted as a product build PASS.
- Schema-12 migration preservation probe: **1 test PASS in 0.031 seconds**.
- Built iOS, macOS, Watch, and Share products all report marketing version `1.5.0`, build `10`; bundle identifiers match their intended products.
- Main app build graph compiled `ProjectArchiveSchema.swift`, `PatternFolder.swift`, and `PatternFolderPresentation.swift`. Share compiled the schema-13 inbox payload owner `PatternInboxItem.swift` for both simulator architectures.
- Read-only availability: Mac available; iPad Air 5, iPhone 17 Pro Max, and Apple Watch Ultra 2 unavailable pending device unlock/discoverability. No install or launch attempted.
- `AppStore/Verification/PatternFoldersNextVersionVerification.md` binds the exact source candidate and retains all physical items unchecked/PENDING.
- Acceptance-preparation commit: `d00bb36c93368b517987f033f91ebaec08a7fc1c` with message `test: prepare pattern folder acceptance`; it contains only the verification record because XcodeGen produced no project diff.
- No archive, export, install, launch, uninstall, erase, upload, App Store Connect action, submission, merge, push, or release occurred.

## Replacement full-suite stale Task 5 contract correction

Status: **implementation complete / review-pending / later gates remain blocked**

- Exact source candidate that exposed the issue: `485c14bae8f41ade72b126846616161a5f1a7b0d`.
- Retained full-suite log: `/tmp/KnitNotePatternFolders-full-485c14b.log`.
- All three complete-suite failures independently reproduced as **1 RED issue** before test changes:
  1. Pattern Reader coordinated file-write contract read the obsolete root instead of the collection owner.
  2. Watercolor policy required the generic background in the obsolete root instead of the list presentation.
  3. Backup reminder contract read the obsolete root instead of the collection import outcome handler.
- Production inspection confirmed the behavior was correct; no production change was required.
- Corrected contracts bind to exact source regions:
  - `importPattern` must call `store.importPatternFromLibrary` and pass `folderID: destinationFolderID`;
  - the list block between `.listStyle(.plain)` and `.navigationTitle(scopeTitle)` must apply `.background(WatercolorBackground())`;
  - `importPattern` must route through `acceptImportOutcome(outcome)`, whose bounded block must call `backupReminderPresenter.accept(outcome)`.

### Decoy mutation evidence

- Actual library store call changed while an out-of-block `store.importPatternFromLibrary` comment remained: **1 intended RED issue**.
- Actual list background changed to clear while the empty-state `WatercolorBackground()` remained: **1 intended RED issue**.
- Actual outcome presenter call changed while an out-of-block `backupReminderPresenter.accept(outcome)` comment remained: **1 intended RED issue**.

### Restored-source GREEN

- Pattern Reader contracts: **28 tests / 1 suite PASS**.
- Watercolor policy selection: **6 tests PASS**.
- Backup Settings contracts: **11 tests / 1 suite PASS**.
- Exact Task 7 focused selection: **382 tests / 22 suites PASS in 8.469 seconds**.
- Production source restored with no diff; `git diff --check` PASS.
- No replacement full suite, XcodeGen, build, archive, export, install, network, upload, submission, merge, push, or release action ran.
- Await fresh review and explicit resume clearance before starting another full-suite run or any later Task 7 gate.
