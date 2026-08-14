# Knitting Calculator 1.0.1 Multilingual Design

## Goal

Release Knitting Calculator 1.0.1 as the same free, standalone calculator while expanding its in-app and App Store localization coverage from English and Traditional Chinese to the same 13 languages supported by the current KnitNote release.

## Release Identity

- Marketing version: `1.0.1`
- Build number: `3`
- Bundle identifier remains `com.phillon.KnittingCalculator`.
- The app remains free, offline, account-free, ad-free, analytics-free, tracking-free, and without in-app purchases.
- The release does not change calculator formulas, persistence formats, navigation, privacy behavior, or the KnitNote promotion destination.

## Supported Languages

The supported locale identifiers are exactly:

1. `en` — English
2. `zh-Hant` — Traditional Chinese
3. `zh-Hans` — Simplified Chinese
4. `de` — German
5. `fr` — French
6. `ja` — Japanese
7. `ko` — Korean
8. `nl` — Dutch
9. `nb` — Norwegian Bokmål
10. `sv` — Swedish
11. `fi` — Finnish
12. `da` — Danish
13. `el` — Greek

The app follows the language selected for it by iOS or iPadOS. Version 1.0.1 does not add an in-app language picker or an app-specific locale override.

## In-App Localization

The existing String Catalog architecture remains authoritative. `KnittingCalculator/Localization/Localizable.xcstrings` keeps its current keys and gains complete localizations for all 13 supported locales. `KnittingCalculator/Localization/InfoPlist.xcstrings` receives the same locale coverage for the localized app display name and any user-visible bundle text.

Translations must be natural, task-specific writing rather than mechanical copies from KnitNote. KnitNote's reviewed knitting terminology is the glossary source for gauge, stitches, rows, increases, decreases, edge stitches, pattern repeats, knitting, and crochet. The `KnitNote` product name remains unchanged in every language.

Localization covers all visible and spoken product text, including:

- home, settings, gauge, and adjustment screens;
- field labels, units, segmented controls, buttons, results, explanations, and help;
- validation and error messages;
- copy and share output;
- privacy and KnitNote promotion text;
- VoiceOver labels, values, hints, and result summaries;
- the localized app display name.

User-entered calculator drafts remain unchanged when the system language changes. Saved numeric values and unit preferences continue to use the existing locale-neutral persistence model.

## Numbers and Units

`LocalizedNumberCodec` remains the single input and output boundary for decimal values. The 1.0.1 localization work must preserve support for both locale-native decimal separators and the alternate separator already accepted by the app. It must not change rounding, recommendation, interval, edge-stitch, or remainder calculations.

Units use the natural abbreviation or written form for each language without changing their underlying centimeter or inch meaning. Share text uses the active system App language and locale formatting.

## App Store Localization

`AppStore/KnittingCalculator/Metadata/` will contain one complete metadata file for each of the 13 supported App Store locales. Each localization includes:

- app name;
- subtitle;
- promotional text;
- description;
- keywords appropriate to that storefront language;
- support URL;
- marketing URL when present in the existing listing;
- version `1.0.1` release notes.

The English and Traditional Chinese listings remain the semantic source. The other 11 listings are naturally localized while preserving these claims:

- the app is free and works offline;
- it includes gauge and even increase/decrease tools;
- it requires no account and contains no ads, analytics, tracking, or in-app purchases;
- KnitNote is a separate app for project, counter, yarn, pattern, and journal management.

The existing approved iPhone and iPad screenshots remain in use. New localized product pages reuse the existing screenshot set; version 1.0.1 does not create 11 additional localized screenshot sets.

## Architecture and File Boundaries

- `KnittingCalculator/Localization/Localizable.xcstrings` owns all in-app and accessibility strings.
- `KnittingCalculator/Localization/InfoPlist.xcstrings` owns localized bundle-facing text.
- `AppStore/KnittingCalculator/Metadata/*.md` owns the App Store listing for each locale.
- `KnittingCalculator.xcodeproj/project.pbxproj` and any generated project source of truth own version/build settings and known regions.
- Localization contract tests own the exact locale set, completeness rules, placeholder consistency, and forbidden fallback detection.
- The release audit owns archive resource coverage and the `1.0.1 (3)` identity check.

No new runtime localization service, dependency, persistence field, or language-selection UI is introduced.

## Validation and Failure Handling

Automated validation must fail the release when any supported locale:

- is missing from either String Catalog;
- contains an empty, stale, or unfinished translation;
- changes a format placeholder or interpolation contract;
- falls back to English for a required calculator key;
- is missing its App Store metadata file or a required metadata field;
- is absent from the built app's localized resources;
- changes calculator output compared with the existing English and Traditional Chinese behavior.

The full calculator test suite and release audit must pass. Debug and Release builds must succeed for both an iPhone and an iPad destination supported by the project. The archive must identify itself as version `1.0.1`, build `3`, and contain `Localizable.strings` and `InfoPlist.strings` resources for all 13 locales.

## Manual Acceptance

All 13 languages receive automated completeness and packaging checks. Physical-device sampling covers English, Traditional Chinese, Simplified Chinese, German, and Japanese on both iPhone and iPad.

For each sampled language, acceptance verifies:

1. full-screen launch without the historical half-screen layout defect;
2. home and settings text without truncation or overlap;
3. gauge calculation and result explanation;
4. single-row and across-row increase/decrease flows;
5. validation and error messages;
6. copy and share text;
7. the KnitNote link;
8. rotation, background/foreground, and reopen persistence.

German represents long Latin text, Japanese and Chinese represent non-Latin and compact scripts, and English remains the source-language baseline. Any clipping, untranslated key, incorrect terminology, broken placeholder, or changed calculation is a release blocker.

## Out of Scope

- An in-app language selector.
- New calculators, navigation, visual redesign, or icon changes.
- New screenshots for each of the 11 added languages.
- Localization of user-entered drafts or copied content supplied by the user.
- Changes to KnitNote itself.
- App Store submission, review, or release before the 1.0.1 candidate passes the stated automated and physical gates.
