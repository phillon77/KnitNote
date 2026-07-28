# Task 11 Report: Knitting Calculator App Store Metadata, Support, and Privacy

## Scope

Implemented only the free Knitting Calculator product-page, support, and privacy material. No App Store Connect record, submission, upload, or other external state was created or changed.

## Deliverables

- Complete English and Traditional Chinese App Store metadata, including the exact localized name, subtitle, keywords, promotional text, descriptions, support and privacy URLs, review notes, and territory positioning.
- Bilingual public support and privacy pages at the development URLs:
  - `https://phillon77.github.io/KnitNote/knitting-calculator.html`
  - `https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html`
- A KnitNote home-page link to the separate free calculator and its privacy page, without changing KnitNote product claims.
- A bilingual privacy policy aligned with the calculator’s shipped `PrivacyInfo.xcprivacy`: no tracking, no tracking domains, no collected data types, and app-local `UserDefaults` only with required-reason `CA92.1`.
- A Swift Testing metadata contract covering field presence and limits, exact URLs, localized required keywords, no upgrade/full-version positioning, support/privacy links, manifest alignment, and scans for network SDK or permission declarations in the free-app target.

KnitNote is mentioned only as a separate optional project-management app from the same team, after the calculator’s own feature description. The calculator is positioned as free in every territory, without ads, in-app purchases, account, tracking, or feature differences by territory.

## Apple-reference check

Checked 2026-07-28 against Apple’s current documentation:

- [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/) — name and subtitle are each limited to 30 characters; a privacy-policy URL is required.
- [App Store search](https://developer.apple.com/app-store/search/) — keywords are limited to 100 characters/bytes, comma-separated, and should not duplicate terms.
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/) — App Store privacy answers and policy must accurately cover the app and integrated third-party code.
- [Required-reason API reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) — `CA92.1` permits app-local UserDefaults read/write use.

## TDD evidence

The new `KnittingCalculatorMetadataContractTests` was added before any Task 11 metadata, privacy, or support artifact. Its first run compiled and failed only because the expected `AppStore/KnittingCalculator/Metadata/*.md` and `PrivacyPolicy.md` files did not exist. After the minimum artifacts were added, the contract exposed six real copy/link gaps: explicit English no-ads/no-analytics wording, explicit Traditional-Chinese no-tracking wording, direct delete wording, and the public privacy URL on the support page. The corrected GREEN run passed all three tests.

## Fresh verification

- `CLANG_MODULE_CACHE_PATH=/tmp/knitting-calculator-clang-module-cache swift test --filter KnittingCalculatorMetadataContractTests` — 3 tests passed.
- `python3 AppStore/Verification/site_check.py AppStore/SupportSite` — `SITE CHECK: PASS`.
- `python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata` — `METADATA CHECK: PASS`.
- `git diff --check` — passed.
- `xcodebuild -project KnitNote.xcodeproj -scheme KnittingCalculator -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/KnittingCalculatorTask11 CODE_SIGNING_ALLOWED=NO build` — `BUILD SUCCEEDED`.

The build reports the existing target warning that a launch configuration, launch storyboard, or xib should be provided unless the app requires full screen. This Task does not change application launch configuration.

## Files

- `AppStore/KnittingCalculator/Metadata/en-US.md`
- `AppStore/KnittingCalculator/Metadata/zh-Hant.md`
- `AppStore/KnittingCalculator/PrivacyPolicy.md`
- `AppStore/SupportSite/knitting-calculator.html`
- `AppStore/SupportSite/knitting-calculator-privacy.html`
- `AppStore/SupportSite/index.html`
- `Tests/KnitNoteCoreTests/KnittingCalculatorMetadataContractTests.swift`
- `task-11-report.md`
