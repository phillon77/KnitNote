# Task 1 report: Dutch runtime and shipping configuration

## Implementation commit

- `7c26a34 feat: register Dutch as a shipping language`

## Delivered scope

- Added `AppLanguage.dutch` (`nl`) and `LanguageSelection.dutch`.
- Mapped Dutch selection to `language.dutch` without changing the stored selection key format.
- Resolves both `nl-NL` and `nl-BE` to Dutch.
- Defined `SupportedLocalization.v150Identifiers` as the existing v1.4.1 identifiers followed by `nl`.
- Added `nl` as the thirteenth `CFBundleLocalizations` entry for the main app, Watch app, and Share extension in `project.yml` and the XcodeGen-generated Info plists.
- Updated the complete picker-key contract for the newly exhaustive selection case.

## TDD evidence

1. RED: `swift test --disable-sandbox --filter LanguageSettingsTests` and `swift test --disable-sandbox --filter StringCatalogLocalizationContractTests` failed because `v150Identifiers`, `AppLanguage.dutch`, and `LanguageSelection.dutch` did not exist.
2. GREEN: after the minimal runtime mappings, `LanguageSettingsTests` passed 11 tests and `StringCatalogLocalizationContractTests` passed 19 tests.
3. RED: the updated release identity test reported all three source/generated `CFBundleLocalizations` arrays and the generated PBX known regions missing `nl`.
4. GREEN: after the XcodeGen source configuration update, `ReleaseCandidateIdentityTests` passed 5 tests.
5. Regression check: the existing picker completeness contract first failed for the new case, then passed 2 tests after adding only `.dutch: "language.dutch"`.

## XcodeGen evidence

- XcodeGen version: `2.45.4`.
- Regenerated from checked-in `project.yml` twice.
- `KnitNote.xcodeproj/project.pbxproj` SHA-256 was stable after both generations:
  `2419d5f02fee31291e2e2342e92d1714b63e5e7c182e7642c214b9e31b6e98be`.
- `git diff --check` was clean.

## Sequencing revision and concerns

- XcodeGen 2.45.4 derives PBX `knownRegions` from actual localized resources. A probe confirmed that an `options.knownRegions` list is accepted but does not add `nl` to generated PBX known regions.
- Task 1 deliberately does not add fake `nl.lproj` resources or edit the generated PBX directly. The PBX therefore remains the twelve-catalog locale set plus `Base`; its exact transitional state is guarded by a fail-closed test and TODO in `ReleaseCandidateIdentityTests`.
- Task 2 must add the real Dutch catalogs, regenerate the project, and then require `nl` in PBX `knownRegions`. It must also update the release-audit twelve-locale gate only alongside complete Dutch catalog coverage.
- A full `swift test --disable-sandbox` was run. The focused Task 1 suites passed, but existing `ReleaseAuditLocalizationTests` fail because their audit fixture intentionally hard-codes the twelve-locale catalog release gate while Task 1 now declares thirteen bundle locales. This is the intentional Task 1 to Task 2 handoff, not a release-ready state.
- No catalog translations, project-title changes, version/archive/export/sign/upload/merge/push actions were performed.
- Preserved pre-existing untracked `.superpowers/brainstorm/` and `AppStore/Verification/CounterReminders150Verification.md`.
