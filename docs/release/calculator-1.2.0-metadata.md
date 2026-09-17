# Knitting Calculator 1.2.0 metadata preparation

Prepared 2026-09-17. Local copy preparation only; this document does not establish App Store publication, completed privacy disclosures, device acceptance, or review readiness.

## Scope

Updated all 13 files under `AppStore/KnittingCalculator/Metadata`: da-DK, de-DE, el-GR, en-US, fi-FI, fr-FR, ja-JP, ko-KR, nb-NO, nl-NL, sv-SE, zh-Hans and zh-Hant. Existing field structure, names, subtitles, keywords, support URLs, copyright and Apple ID are retained.

Descriptions, promotional text and 1.2.0 release notes now include shoulder short-row planning. Descriptions and release notes explicitly identify English and Traditional Chinese support for the new tool, with English fallback in other app languages. Existing localized gauge and increase/decrease descriptions are retained. Obsolete ad-free and blanket no-analytics/no-tracking claims have been removed. Review notes and internal territory positioning use English consistently across locales.

Review notes describe the 320 x 50 Home-only non-personalized banner, no interstitial/rewarded/app-open ads, no ATT prompt, applicable Google UMP choices, offline calculations, no account or in-app purchase, and calculation availability when ads or consent fail. Internal verification and consent-QA blockers remain in this report rather than the reviewer-facing copy. Review notes retain the optional KnitNote link locations and explain that external video tutorials require internet access. Descriptions group shoulder short rows with the other calculation features, before local draft storage and the KnitNote promotion.

All metadata Privacy URL fields now point to the approved published advertising policy: https://phillon77.github.io/knitting-calculator-ads-privacy.html . `AppStore/KnittingCalculator/PrivacyPolicy.md` contains the approved bilingual policy paragraphs from `AppStore/Advertising/PrivacyPolicy.draft.md`, excluding draft/publication instructions, and links the published policy. Scope distinguishes 1.2.0 advertising behavior from 1.1.0.

The marketing URL to retain in all App Store Connect localizations is https://phillon77.github.io/KnitNote/knitting-calculator.html . AccountSetup-2026-09-17.md records that it was saved previously. No live portal read-back or changes were performed in this metadata subtask.

## Validation

`python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata` reports 26 failures: two stale 1.0.1 copy-contract failures for each locale (old release-note string and old approved-copy digest). Filtering only those two obsolete contract categories leaves zero validation errors: locale completeness, required fields, field lengths, keywords, IDs and URL format pass. This is a limited field validation, not a passing full release checker. The checker and Swift metadata contracts require an advertising/1.2.0 update by the release integration owner.

`git diff --check` passed for these metadata, policy and summary files after removing one extra blank line at EOF.

## Remaining release alignment

AdMob account review, app verification and actual consent QA remain pending according to the account setup record. Final candidate behavior, archived SDK disclosures, store privacy answers, in-app policy URL and review notes must be aligned before submission. These local edits do not enable live advertising or establish that a consent test passed. The old public 1.1.0 policy is not modified by this subtask.
