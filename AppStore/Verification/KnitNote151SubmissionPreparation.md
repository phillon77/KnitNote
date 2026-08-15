# KnitNote 1.5.1 submission preparation

Date: 2026-08-15 (Asia/Taipei)

## Immutable inputs

- Repository metadata commit: `6a7d01a534bfd8c8cd737f71c18becd2c5f944b6`
- Candidate source commit: `e0199e307fe2f77df38f6f055c9bd7241549b1ca`
- Apple ID: `6793023054`
- Bundle ID: `com.phillon.KnitNote`
- Version/build: `1.5.1 (11)`

## App Store Connect preparation

Prepared and saved through the signed-in App Store Connect web UI:

- iOS version page: `1.5.1`, Build `11`, status `Ready to Submit` (`準備提交`).
- macOS version page: `1.5.1`, Build `11`, status `Ready to Submit` (`準備提交`).
- Before selection, the live TestFlight entries for both platform-specific Build 11 uploads displayed `Ready to Submit` and `90 days until expiration`; no processing or export-compliance blocker was displayed.
- Exact repository `What's New` copy was written and read back successfully for all 13 locales on both platforms: `da-DK`, `de-DE`, `el-GR`, `en-US`, `fi-FI`, `fr-FR`, `ja-JP`, `ko-KR`, `nb-NO`, `nl-NL`, `sv-SE`, `zh-Hans`, and `zh-Hant`.
- The version-specific review note was written and read back exactly on both platforms.
- Existing screenshots were retained: five iPhone screenshots and three Mac screenshots.
- Existing release configuration was retained on both platforms: automatic release after approval, immediate release to all users rather than phased release, and preserve existing ratings.

The aggregate SHA-256 of the approved 13-locale repository copy is `a2c07d21578a54ba9f25c4673243125d574df4533b1e1a0762428708d6fe3ffd`.

Each value below was read back from the saved platform page. The iOS and macOS columns hash the exact UTF-8 field value without a trailing newline.

| Locale | iOS readback SHA-256 | macOS readback SHA-256 |
| --- | --- | --- |
| `da-DK` | `5c3f9b6657f877e4c9a858fee17a64e08cfe4fad4ec6e696a6015a0d2a781230` | `5c3f9b6657f877e4c9a858fee17a64e08cfe4fad4ec6e696a6015a0d2a781230` |
| `de-DE` | `cc910b929b80d5e870e464aafcf914feca6265c57e4a31aae2339c60076ea064` | `cc910b929b80d5e870e464aafcf914feca6265c57e4a31aae2339c60076ea064` |
| `el-GR` | `e32f06b261b2e253841049f752942db3245b2a73f520d4173772904d3c52d71a` | `e32f06b261b2e253841049f752942db3245b2a73f520d4173772904d3c52d71a` |
| `en-US` | `a821a174e65f85e82f1a126221bb3716632b76a9436797bc228bd812ab6ab99b` | `a821a174e65f85e82f1a126221bb3716632b76a9436797bc228bd812ab6ab99b` |
| `fi-FI` | `716ecd22c285dce07d5c930aa5f14e9be3d8a81a5ebc018700e76092e9aa7670` | `716ecd22c285dce07d5c930aa5f14e9be3d8a81a5ebc018700e76092e9aa7670` |
| `fr-FR` | `add9a106edb532975e021e1d7325a60aad15b22285786bd7ece4d0909e14c773` | `add9a106edb532975e021e1d7325a60aad15b22285786bd7ece4d0909e14c773` |
| `ja-JP` | `d206fd029052971a08284718892132965aa97b014b05e9aa79ee7d470247a702` | `d206fd029052971a08284718892132965aa97b014b05e9aa79ee7d470247a702` |
| `ko-KR` | `9b4de1633739b9406ddeee41ccb2d4590e80d07171e4f723fee09077c619dccc` | `9b4de1633739b9406ddeee41ccb2d4590e80d07171e4f723fee09077c619dccc` |
| `nb-NO` | `f547c648b7424168819befa86b769a47bc3e0b122494b3c4455528a3abecc7f5` | `f547c648b7424168819befa86b769a47bc3e0b122494b3c4455528a3abecc7f5` |
| `nl-NL` | `342b924b12711904d57093a3b13267f2c0a72c37bae4a426d8c091098dd6b6c0` | `342b924b12711904d57093a3b13267f2c0a72c37bae4a426d8c091098dd6b6c0` |
| `sv-SE` | `8baaa889783b3059feb3ae2993157fac116f5656078f3085a5dcc35b4554b2ea` | `8baaa889783b3059feb3ae2993157fac116f5656078f3085a5dcc35b4554b2ea` |
| `zh-Hans` | `711216893518639c8cb1d74136ba3433646adcf8d5e7207edd9d885d4b0ecd76` | `711216893518639c8cb1d74136ba3433646adcf8d5e7207edd9d885d4b0ecd76` |
| `zh-Hant` | `98dc4dfab2957494c1774f46bb476c1d5ee96f9997ecb8c360fca3eaf825043c` | `98dc4dfab2957494c1774f46bb476c1d5ee96f9997ecb8c360fca3eaf825043c` |

The exact 406-character Traditional-Chinese review note was read back on each saved platform page. Its UTF-8 SHA-256 is `3592039630e27b85c70e446721bb98d9268b2059e922f4abca955f26a9fab494`. Its scope is limited to the three shipped 1.5.1 features (pattern folders, language-reactive Yarn Library title, and the foreground App Store update reminder), the reminder's non-push/non-background behavior, offline/no-tracking behavior, and the existing Lifetime Unlock purchase model.

## Read-only commercial and privacy checks

- Lifetime Unlock IAP `com.phillon.KnitNote.lifetimeUnlock`: approved, non-consumable.
- Availability: available in 175 countries or regions.
- App price: free in all 175 countries or regions (the current-price dialog showed `0.00` in every listed currency, including United States `$0.00` and Taiwan `$0.00`).
- Future price schedule: none displayed; the price schedule contained exactly the single `Current Price` row and no dated future adjustment row.
- Distribution: public App Store distribution.
- Privacy declaration: no data collected.
- Privacy policy URL: `https://phillon77.github.io/KnitNote/privacy.html`.

No pricing, availability, privacy, IAP, screenshot, release-mode, or rating-setting change was made outside the version-page preparation described above.

## Submission boundary

- `Add for Review` / `Submit for Review`: **NOT PERFORMED**.
- Review submission, scheduling, release, and publication remain **PENDING explicit authorization**.
- No source push, tag, merge, archive, export, or upload was performed as part of this metadata preparation.
