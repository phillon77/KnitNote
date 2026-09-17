# Calculator 1.2.0 preparation

User authorized on 2026-09-17: combine shoulder short rows and quiet home banner advertising in Calculator 1.2.0 and submit for App Review. No Git push or KnitNote release requested.

## Scope
- Existing Calculator worktree `feature/calculator-stitch-dictionary`, base 6b16af4f83b3e25a124085ea2809679564b8b522.
- Marketing version 1.2.0, build 5 (previous version 1.1.0 build4).
- Retain shared ShortRowKit, all existing quiet-banner code and its Debug-only consent QA. Keep ad readiness NO while actual consent/refusal acceptance is missing.
- Update app privacy link to already-published 1.2.0 scoped policy; refresh all 13 store descriptions/release notes; use marketing URL already saved in ASC1.2.0 draft.
- Preserve legacy ad-free audit; add ads-specific allowlist and explicit preparation-versus-release checks.

## Verification / gates
- [x] Version/project/plist and policy link agree.
- [x] App tests and both calculation package tests pass (46 + 47 + 9 = 102).
- [x] Ads preparation audit and its 8 regression tests pass; release mode fails on unresolved gates.
- [ ] Localized metadata validated and saved/read back in ASC draft.
- [ ] Source changes committed as a preparation snapshot, excluding unrelated screenshots/temporary data.
- [ ] Diagnostic archive checked, explicitly not final ad-enabled release candidate.
- [ ] AdMob account verified; actual required-form consent/refusal/privacy-options/reopen/offline QA completed.
- [ ] Resolve app verification/public marketing URL dependency; do not confuse pending Google verification with an Apple App Review rejection.
- [ ] Final App Store privacy disclosures and export compliance explicitly confirmed against actual archive.
- [ ] Final enabled candidate source, artifact and device evidence aligned; upload/process/select then submit within user's authorization.

## Observed live state
- AdMob home: payment setup complete, account verification pending, app verification required.
- ASC:1.2.0 Prepare for Submission, no build;1.1.0 Available for Release.1.2.0 manual release selected.
- Existing descriptions still claim no ads/analytics/tracking, so must not be reused for the advertising update.

The account status is not itself proof Apple cannot accept a binary. The current missing acceptance is the actual required consent flow on the publisher's setup. An ad-disabled archive does not fulfill the user's requested advertising release and must not be submitted as if it does.

## Latest preparation checkpoint
- English (US) and Traditional Chinese promotional text, description and What's New saved in ASC and verified after reload / locale re-selection. Shared App Review notes also saved. Other 11 locale files are prepared locally but not yet applied to ASC.
- ASC remains Prepare for Submission with no selected build. No archive upload or submission occurred.
- Test logs: `/tmp/calculator-120-tests.log`, `/tmp/calculator-120-core-tests.log`, `/tmp/calculator-120-shortrows-tests.log`.
- Source audit revision: `6b16af4f83b3e25a124085ea2809679564b8b522`; production source SHA256: `458302efb89a15f7c7e28f787541144ee7469d7d47b3f46757f135783f8d5b4b`. Source edits remain uncommitted; this is preparation evidence, not a final candidate.
- Remaining preparation includes other locale portal updates and screenshot accuracy checks, final archive, App Privacy disclosure changes (currently legacy no-collection), export declaration and device acceptance of the actual ad-enabled candidate.
- Safari native text entry required separate focus and input operations; all temporary incorrectly placed text was corrected before saving and exact English / Traditional Chinese descriptions were read back after reload.
