# Calculator 1.2.0 (5) feature inclusion check

Verified 2026-09-17 against the dirty Calculator worktree on `feature/calculator-stitch-dictionary`, base HEAD `6b16af4f83b3e25a124085ea2809679564b8b522`.
Source preparation digest: `458302efb89a15f7c7e28f787541144ee7469d7d47b3f46757f135783f8d5b4b`.

## Included functionality

- Home retains gauge, adjustment and stitch dictionary navigation, and includes `ShortRowCalculatorView`.
- ShortRowKit is a linked local package in both project.yml and the generated Xcode project.
- Shoulder planning includes gauge/height/stitch inputs, sample inputs, starting-face selection, per-row instructions and staircase diagram. English and Traditional Chinese resources are present; other locales fall back to English.
- Local 1.2.0 store descriptions and release notes include shoulder short rows and banner advertising.

## Fresh verification

- App integration: 46 passed, zero failures/skips, verified from xcresult summary.
- KnittingCalculatorCore: 47 passed.
- ShortRowKit: 9 passed, including localization and stitch-level height-distribution checks.
- Source preparation audit passed; this is explicitly not release readiness.
- Release device archive completed at `/tmp/calculator-120-feature-check.xcarchive`, with signing disabled. Info.plist confirms com.phillon.KnittingCalculator, 1.2.0 (5).
- Archived executable strings contain ShortRowCalculator, ShortRowCalculatorView, ShortRowDiagram and calculator.shortRows. Archived ShortRowKit resource bundle contains en and zh-Hant strings. Release symbols are stripped, so `nm` was not used as absence evidence.
- Package tests initially failed because workspace build products carried prohibited file attributes during codesigning. Rebuilding with separate `/tmp/calculator-120-feature-shortrows` and `/tmp/calculator-120-feature-core` scratch paths passed without production-source changes.
- Logs: `/tmp/calculator-120-feature-check-{app,core,shortrows,audit,archive}.log`.

## Release boundary

This archive is unsigned and has CalculatorAdsReady=NO. It is an inclusion check, not the requested final advertising candidate; it must not be uploaded as such.
User wants advertising included in 1.2.0. AdMob account approval is confirmed, but app/app-ads verification remains pending the public marketing URL. The current audit requires those gates before release, which creates an ordering dependency: do not falsify acceptance evidence. Reconcile the pre-upload and post-publication gates explicitly before final candidate preparation.
Consent form delivery and simulated Do not consent dismissal have been observed; full accept/refuse/withdraw/persistence and physical device acceptance remain incomplete. Final privacy disclosures, production ad enablement, signed candidate and upload/submission are still pending. No source commit, push, upload or review submission performed by this check.
