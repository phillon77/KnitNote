# Task 1 report: Dutch runtime and shipping configuration

## Implementation commit

- `7c26a34 feat: register Dutch as a shipping language`
- `2ba3ee3 fix: defer Dutch shipping locale transition`

## Delivered scope

- Added `AppLanguage.dutch` (`nl`) and `LanguageSelection.dutch`.
- Mapped Dutch selection to `language.dutch` without changing the stored selection key format.
- Resolves both `nl-NL` and `nl-BE` to Dutch.
- Defined `SupportedLocalization.v150Identifiers` as the existing v1.4.1 identifiers followed by `nl`.
- Updated the complete picker-key contract for the newly exhaustive selection case.
- Intentionally preserves the current twelve-locale shipping declaration, generated Info plists, and catalog-derived PBX known regions until the complete Dutch catalogs and release-audit contract can transition together.

## TDD evidence

1. RED: `swift test --disable-sandbox --filter LanguageSettingsTests` and `swift test --disable-sandbox --filter StringCatalogLocalizationContractTests` failed because `v150Identifiers`, `AppLanguage.dutch`, and `LanguageSelection.dutch` did not exist.
2. GREEN: after the minimal runtime mappings, `LanguageSettingsTests` passed 11 tests and `StringCatalogLocalizationContractTests` passed 19 tests.
3. Round 1 RED: the corrected current-shipping identity contract failed only because the three source/generated `CFBundleLocalizations` arrays prematurely declared `nl`; the known-regions contract remained green.
4. Round 1 GREEN: after reverting those declarations through `project.yml` and XcodeGen, `ReleaseCandidateIdentityTests` passed 5 tests.
5. Regression check: the existing picker completeness contract first failed for the new case, then passed 2 tests after adding only `.dutch: "language.dutch"`.

## XcodeGen evidence

- XcodeGen version: `2.45.4`.
- Regenerated from checked-in `project.yml` twice.
- `KnitNote.xcodeproj/project.pbxproj` SHA-256 was stable after both generations:
  `2419d5f02fee31291e2e2342e92d1714b63e5e7c182e7642c214b9e31b6e98be`.
- `git diff --check` was clean.

## Round 1 reconciliation and sequencing

- XcodeGen 2.45.4 derives PBX `knownRegions` from actual localized resources. A probe confirmed that an `options.knownRegions` list is accepted but does not add `nl` to generated PBX known regions.
- Task 1 deliberately does not add fake `nl.lproj` resources, direct PBX edits, or early shipping declarations. The PBX remains the twelve-catalog locale set plus `Base`; its exact state is guarded by a fail-closed test and TODO in `ReleaseCandidateIdentityTests`.
- The review reproduced `ReleaseAuditLocalizationTests` as 54 tests with 92 issues when source/generated plists declared `nl` before the audit and real catalogs changed. The first `Main source CFBundleLocalizations do not match the twelve release locales` gate masked unrelated negative and positive assertions.
- The next implementation task combines the original Tasks 2 and 3 with the locale-count/release-audit transition. It must atomically add complete real Dutch main, InfoPlist, Watch, and Share catalogs; add `nl` to project.yml/generated plists; regenerate PBX known regions; and update release-audit contracts and fixtures. It must not leave a red intermediate release-audit suite. Task 6 is final validation, not the first shipping transition.
- Round 1 does **not** claim fresh `ReleaseAuditLocalizationTests` or full-suite GREEN: shared-worktree SwiftPM dispatcher contention repeatedly held the `.build` lock while those final runs were queued. An independent reviewer/parent must run both suites after the queue drains; this remains the explicit post-commit verification gate.
- No catalog translations, project-title changes, version/archive/export/sign/upload/merge/push actions were performed.
- Preserved pre-existing untracked `.superpowers/brainstorm/` and `AppStore/Verification/CounterReminders150Verification.md`.
