# Task 9 report: localization and accessibility sweep

## Implemented

- Replaced the shallow catalog check with contracts that require non-empty `en` and `zh-Hant` values, matching format placeholders, all current free-app references, and a localized display name.
- Added semantic error labels with an accompanying warning symbol, explicit VoiceOver values for every segmented selection, 44 by 44 point copy/share controls, and a centered 680 point maximum content width for Gauge on wide iPad layouts.
- Added deterministic localization lookup for string-producing calculator models. Share text and row-interval presentation now honor the supplied locale instead of inheriting the test process language.
- Corrected stale calculator test expectations to use the deterministic lookup, match the shipped capitalization, and verify the current review-request context boundary.

## TDD evidence

- The new accessibility/layout contract was RED with six independent findings: Gauge width, two failure cards, field validation, selection state, and both result-action widths.
- The focused `KnittingCalculatorLocalizationContractTests` suite is GREEN after the production changes (4 tests, 0 failures).

## Verification

- `xcodegen generate` completed and added `CalculatorLocalization.swift` to the generated target.
- `xcodebuild build-for-testing` completed for both `-testLanguage en -testRegion US` and `-testLanguage zh-Hant -testRegion TW`; each produced a `KnittingCalculator.app` simulator product.
- Catalog JSON validation confirms all entries have non-empty English and Traditional Chinese values.
- `git diff --check` is clean.

## Environment limits and unrelated findings

- CoreSimulator became unavailable after the initial iPhone run, so post-fix simulator test execution and visual runtime inspection could not be rerun. The two localized resource bundles are present in each fresh build; the focused contract and en/zh-Hant build-for-testing checks remain the executable evidence.
- The earlier full `swift test` run completed its suite output and exposed four unrelated KnitNote 1.2 build-three release-metadata contract failures, then retained a SwiftPM lock. The exact stalled PID was terminated before focused Task 9 verification. No release metadata was changed.

## Review round 1 corrections

- Traditional Chinese locale candidates now normalize separators and include language-script-region, language-script, and Taiwan/Hong Kong/Macao `zh-Hant` fallback candidates. App-target coverage exercises both `zh-Hant-TW` and `zh_TW`.
- Result cards now keep the combined summary separate from their interactive complete-steps/details disclosure. VoiceOver order is summary, disclosure, then copy/share actions.
- Settings version display now uses `calculator.settings.version.format` with matching English and Traditional Chinese format tokens instead of raw parentheses concatenation.
- The review-focused package localization/accessibility contract is green (5 tests). Fresh en/US and zh-Hant/TW `build-for-testing` products were created. A runtime retry was attempted, but `simctl` still reports CoreSimulatorService connection refused.
