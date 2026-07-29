# Knitting Calculator App Store preparation verification

- Verified: 2026-07-30 06:29–06:31 Asia/Taipei
- Verified candidate Git SHA:
  `4b39ee87d460e5a53761a2d7af9beb0ea142519c`
- Branch: `codex/knitting-calculator-independent-project`
- Worktree:
  `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/knitting-calculator-independent-project`
- App Store Connect Apple ID: `6795877892`
- Bundle ID: `com.phillon.KnittingCalculator`
- Version/build: `1.0.0 (1)`

## Focused product and metadata contracts

All commands below were rerun from the verified candidate worktree:

| Command | Result |
| --- | --- |
| `swift test --filter KnittingCalculatorMetadataContractTests` | PASS — 4 tests |
| `swift test --filter KnittingCalculatorLocalizationContractTests` | PASS — 5 tests |
| `swift test --filter PrivacyManifestContractTests` | PASS — 5 tests |
| `swift test --filter KnittingCalculatorProjectContractTests` | PASS — 13 tests |
| `AppStore/Verification/knitting_calculator_release_audit.sh --static-only` | PASS — `STATIC PRODUCT SCOPE PASS`; final `KNITTING CALCULATOR RELEASE AUDIT: PASS` |
| `python3 AppStore/Verification/site_check_test.py` | PASS — 1 test |
| `python3 AppStore/Verification/site_check.py AppStore/SupportSite` | PASS — `SITE CHECK: PASS` |
| `python3 AppStore/Verification/metadata_check_test.py` | PASS — 1 test |
| `python3 AppStore/Verification/metadata_check.py AppStore/KnittingCalculator/Metadata` | PASS — `METADATA CHECK: PASS` |

## Privacy-source audit

The required source scan was rerun:

```bash
rg -n 'Analytics|Tracking|AdSupport|AppTrackingTransparency|URLSession|CloudKit|StoreKit|Firebase|Telemetry' \
  KnittingCalculator Packages/KnittingCalculatorCore
```

Every match was inspected:

- `KnittingCalculator/PrivacyInfo.xcprivacy` declares tracking `false`, no
  tracking domains, no collected data types, and only app-local
  `UserDefaults` required-reason API `CA92.1`.
- `KnittingCalculator/Model/RatingEligibility.swift` imports StoreKit only
  for `AppStore.requestReview(in:)`, the system rating prompt. It contains no
  product, transaction, purchase, subscription, or StoreKit commerce path.
- The remaining StoreKit matches are fixture strings in
  `Packages/KnittingCalculatorCore/Tests/.../DependencyBoundaryTests.swift`;
  they test the production dependency denylist.
- A production-only commerce search found no purchase or transaction API.
  `CalculatorProductLinks` is the name of the app-link constant, not a
  StoreKit product.

No analytics, tracking, advertising, account, server upload, URLSession,
CloudKit, Firebase, telemetry, or purchase path was found in the independent
app or linked production package.

## Public support and privacy URLs

The validated local support-site delta was deployed to public GitHub Pages by
the narrowly scoped main-branch commit:

- Deployment commit:
  `d460145795467ee92543f48c301c8431b29530dc`
- Commit subject: `docs: publish knitting calculator support pages`
- Parent:
  `f9a6c043758287a57d7eb583e0855c84d5a20073`
- Files: only
  `AppStore/SupportSite/index.html`,
  `AppStore/SupportSite/knitting-calculator.html`, and
  `AppStore/SupportSite/knitting-calculator-privacy.html`
- GitHub Pages workflow run: `30496309945`
- Workflow result: `completed / success`
- Workflow URL:
  `https://github.com/phillon77/KnitNote/actions/runs/30496309945`
- Run window: 2026-07-29 22:29:22Z–22:29:39Z

Fresh public checks ran from
`2026-07-30T06:29:56+08:00` through
`2026-07-30T06:29:59+08:00`:

| URL | HTTP/content result |
| --- | --- |
| `https://phillon77.github.io/KnitNote/knitting-calculator.html` | `200`, `text/html; charset=utf-8`, 3863 bytes |
| `https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html` | `200`, `text/html; charset=utf-8`, 3145 bytes |
| `https://phillon77.github.io/KnitNote/` | control page `200` |
| `https://phillon77.github.io/KnitNote/support.html` | control page `200` |
| `https://phillon77.github.io/KnitNote/privacy.html` | control page `200` |

Visible-content checks confirmed:

- the support page identifies `編織計算器支援／Knitting Calculator Support`,
  says the app is free and offline, requires no account, and describes Gauge
  plus Even increases and decreases;
- the privacy page states in both supported languages that Knitting
  Calculator does not collect, transmit, sell, or share personal data, has no
  advertising or analytics SDK, and does not track across apps or websites;
- the home page links to both calculator-specific pages;
- the calculator pages describe the independent calculator and do not present
  KnitNote as the same app.

The fetched calculator pages matched the approved local source byte-for-byte:

```text
7220397011f8155bdb7a564b015e1a8836c6c0a8fd1d6dda9cb297236051dcbc  knitting-calculator.html
d670aeceda08bd59db7cd699b6f9d8b73e47a5c9cbe80fd708d561c63acee657  knitting-calculator-privacy.html
27b398ba8d191c9e0cf64d7c280769263d2b88673826cdcb7316901f3138c336  index.html
```

## Screenshot package

Manifest:

```text
c3165c08b9e7de472e4fc08eaa5bab1c2c115a7c8ee069986a15611625f2bf04  AppStore/KnittingCalculator/Screenshots/manifest.json
```

Generated files:

```text
decc6a7413f8fe93b70d5ba09d432f679061089ceac908e9bc0d50184c427017  AppStore/KnittingCalculator/Screenshots/Generated/en/contact-sheet.png
2aacdb85539aa1fab3b275d0501dab1a9987374752ae0b1e0473daf97bf5e634  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/01-home.png
7b4547df04ade91a00d35855486e9ca5af4b0988c88b0c499919d4fdcff3dacb  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/02-gauge.png
4b842732e7dd6937e454be577fe9e402a1c55353c85f5b5a0e8752ff0bff3214  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/03-adjustment.png
70f274a7f68ab0c7517f5c2bf2f2b5c888cb3aedfd4ecc0f9966cab284bf6678  AppStore/KnittingCalculator/Screenshots/Generated/en/ipad/04-privacy-knitnote.png
b99f6001fb7cec132ce8b20a067714578221bbbc6cb3a05cebec1759c254901c  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/01-home.png
84e2999d751d041619b1564cc8f72941767fef648e67f538d8df910819435231  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/02-gauge.png
18529197ad3648f60c31eca3ca401a4c9aed6ef89d0fe92ef46e348abfdb4e36  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/03-adjustment.png
0f7f7de7791940db9dfdc0b90cc8ca7d23c34023bf146db34e78c8c7000e2299  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/04-privacy.png
694737a450b0c37844e3e314b3131d14c2e09d67e0b2e457afae0c6b00e7b23c  AppStore/KnittingCalculator/Screenshots/Generated/en/iphone/05-knitnote.png
ef5abf282348c4719b5d45c61cad85c5660a6f3568b32639381108e46ed8b7f9  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/contact-sheet.png
d201a79570caa070af221fe68a33ef2bbc4aa76577601ffec91e89127de54126  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/01-home.png
4f3246eb5a6d74290600a63f6daa9724e2e16e4bd5e08e2eee75936a6e796ee3  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/02-gauge.png
b30f9685a5415524105fbb1dd091661fb97cf1c5cc0404b64240d9514203df4f  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/03-adjustment.png
3ea29c766f650e17715eff65d03e2cf70576f807d41398d943cc6094286a67bd  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/ipad/04-privacy-knitnote.png
b3541e40103c0f3aa7ef6f1ffa820e21ee6eee2717d2d80e2a8989ad1aacd6e5  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/01-home.png
52db019d50545da86c74b3121e433e5f422c6fc52c38ec20d5c373daf9d82326  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/02-gauge.png
e47b23c0a2de7dacd8eeed924e7796d6f654b4d693495041fecbab3bebe52347  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/03-adjustment.png
a2cce59998536d2c43094c3d601b1d158bf19243ac55cd7b2a6b865ec4bfac7a  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/04-privacy.png
bb21fd1ba9a8e4a1bcc90e8fbf3ff0b469447366e9471b1e6f2ba2ae72aca3f5  AppStore/KnittingCalculator/Screenshots/Generated/zh-Hant/iphone/05-knitnote.png
```

The two contact sheets are local verification artifacts. The remaining 18
PNG files are the intended localized App Store screenshots: five iPhone and
four iPad images for each of `en` and `zh-Hant`.

## Remaining boundary

This document verifies local product/metadata/privacy contracts, the generated
screenshot package, and the public support/privacy URLs. It does not claim or
authorize App Store Connect submission.

At this checkpoint there has been no App Store Connect metadata mutation,
screenshot upload, build attachment, pricing or availability change, privacy
answer change, review-information change, submission, “Add for Review”
action, or public App Store release.
