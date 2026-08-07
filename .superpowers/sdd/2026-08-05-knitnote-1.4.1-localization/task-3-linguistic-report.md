# Task 3 Linguistic Remediation Report

## Status

The six 1.4.1 language catalogs were re-reviewed end to end and the objective defects from the third review were remediated. This report, the catalog corrections, and the regression tests are included in one focused follow-up commit.

## Review scope and method

- Reviewed every concrete `nb`, `sv`, `fi`, `da`, `ko`, and `el` string unit in the main app, Info.plist, Watch, and Share Extension catalogs against its English source and UI role.
- The complete pass covered 3,327 concrete localized units: 1,662 Finnish/Greek/Korean units and 1,665 Norwegian Bokmål/Swedish/Danish units.
- Used independent audit passes for the Finnish/Greek/Korean and Nordic groups, then reconciled every objective finding against the catalogs and existing product glossary.
- No external translation service was used. No user-created/imported content, persistence code, runtime fallback, data format, or Watch snapshot interface was changed.

## Corrections

The remediation changes 547 catalog values and no catalog topology or metadata:

- Main app: 540 values (`da` 107, `el` 67, `fi` 80, `ko` 80, `nb` 103, `sv` 103).
- Info.plist: 1 Finnish permission value.
- Watch: 1 Finnish entitlement action.
- Share Extension: 5 values across Danish, Greek, Korean, and Swedish.

Every concrete third-review blocker is corrected, including:

- Finnish destructive confirmation grammar, empty-yarn guidance, numeric validation, and knitting-calculator phrasing.
- Greek journal/accessibility terminology and agreement plus the manual-add action.
- Korean command/status register, empty-project and yarn guidance, and paired edge-stitch instruction.
- Norwegian knitting instructions and mathematical even-number validation.
- Swedish stitch/row terminology and every-N-row interval wording.
- Danish journal terminology and range endpoint wording.

The catalog-wide pass also corrected related literal or wrong-domain wording in backup/restore, calculators and gauge, journal, pattern reader/import/markup, project actions, settings and lifetime access, yarn inventory/tools/OCR, accessibility, and extension copy. Natural but merely stylistic alternatives were not churned where the audit found no objective meaning or grammar defect.

## TDD evidence

- RED: the new main and Watch/Share exact-copy regression tests failed against the `119bcd0` catalog values. A later independent Nordic re-review added four more exact-copy assertions; their isolated RED run failed with exactly 4 issues before the catalog corrections.
- GREEN: `swift test --filter 'LocalizationContractTests|ShareExtensionLocalizationContractTests|LanguageSettingsTests'` passed 72 tests in 4 suites with zero issues after the final edits.
- The regression coverage pins representative destructive actions, journal accessibility, commands and empty states, calculator/knitting semantics, range labels, yarn inventory/tool terminology, and Watch/Share copy.

## Structural and token verification

- A semantic comparison against `119bcd0` confirms every catalog change is a localized `value` under one of the six target language branches; no key, localization branch, state, comment, plural topology, or other metadata changed.
- Format-token multisets are identical before and after every changed value.
- All four String Catalogs parse as JSON.
- `KnitNote.xcodeproj/project.pbxproj` passes `plutil -lint`.
- `git diff --check` passes.

## Builds and packaged resources

Fresh unsigned Debug builds passed for all four requested schemes:

- iOS `KnitNote`
- macOS `KnitNote`
- watchOS `KnitNoteWatch`
- iOS `KnitNoteShare`

Each built product contains exactly these 12 localization resource directories:

`da`, `de`, `el`, `en`, `fi`, `fr`, `ja`, `ko`, `nb`, `sv`, `zh-Hans`, `zh-Hant`.

## Full-suite boundary

Fresh `swift test --quiet` ran 1,317 tests in 122 suites and reported 14 issues. All 14 are the already-deferred Task 5 release-audit cascade caused by the audit's obsolete six-locale `knownRegions` expectation:

`found [da,de,el,en,fi,fr,ja,ko,nb,sv,zh-Hans,zh-Hant], expected [de,en,fr,ja,zh-Hans,zh-Hant]`

No unrelated issue was observed. This suite is not reported as passing; Task 5 must update the release-audit locale/version contract.

## Remaining release gates

- Independent native-speaker acceptance is still mandatory for all six new languages. This pass establishes a complete, internally reviewed remediation, not native-speaker certification.
- Exact-device or representative-size UI acceptance is still mandatory across iPhone, iPad, Mac, Watch, and Share Extension, especially Korean wrapping and longer Finnish/Greek accessibility copy.
- The 14 Task 5 release-audit issues remain intentionally unresolved in this task.

## Fourth-review remediation

The fourth review identified eight objective same-family inconsistencies. The follow-up corrects exactly those eight main-catalog values:

- Finnish now uses `laskin` for the calculator hint and the knitting verb `Kavenna` in both singular and plural decrease summaries.
- Korean now binds the counter-name placeholder to its controls, keeps `%lld` only as the current value, and uses command-form `줄이세요` in both decrease-result summaries.
- Norwegian Bokmål now uses the knitting term `Fell` in both singular and plural decrease summaries.
- Swedish now expresses the page-note relationship grammatically as `Anteckning för sida %d`.
- Danish now labels arithmetic division as `Dividere`, not partitioning with `opdele`.

Independent read-only scans covered all direct siblings in the relevant Finnish, Korean, Norwegian, Swedish, and Danish key families. They confirmed the eight cited defects and found no additional objective analogue. No external translation service was used.

### Fourth-review TDD and verification

- RED: `version141FourthReviewSiblingFamiliesKeepDomainAndCommandMeaning` failed with exactly 8 issues against `102a766`; after the three Korean corrections it failed with the expected 5 remaining Nordic issues.
- GREEN: the isolated test passed after the five Nordic corrections, and the full focused command passed 72 tests in 4 suites with zero issues.
- Semantic comparison against `102a766` shows exactly eight changed localized values (`da` 1, `fi` 2, `ko` 3, `nb` 1, `sv` 1), with no key, state, branch, plural-path, metadata, or format-token change.
- Fresh full suite: 1,317 tests in 122 suites, with only the same 14 deferred Task 5 release-audit issues and no unrelated failure.
- Fresh unsigned Debug builds passed for iOS, macOS, Watch, and Share. Every fresh product contains the exact twelve required `.lproj` directories.
