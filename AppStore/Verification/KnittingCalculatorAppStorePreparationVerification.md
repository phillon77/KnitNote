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

## App Store Connect App-level configuration

- Configured and read back: 2026-07-30 18:23–18:53 Asia/Taipei
- Signed-in App Store Connect account: `Phil Lon`
- App: `編織計算器`
- Apple ID: `6795877892`
- Bundle ID: `com.phillon.KnittingCalculator`
- iOS version status: `1.0 準備提交` (`Prepare for Submission`)

### App Information

The following values were saved and then confirmed again after a fresh page
reload:

| Field | Saved read-back |
| --- | --- |
| Traditional Chinese name | `編織計算器` |
| Traditional Chinese subtitle | `密度與加減針工具` |
| English (U.S.) name | `Knitting Calculator` |
| English (U.S.) subtitle | `Gauge, Increases & Decreases` |
| Primary category | `工具程式` (`Utilities`) |
| Secondary category | `生活風格` (`Lifestyle`) |

The age-rating questionnaire was answered from actual app behavior and content:
all listed controls, capabilities, mature content, medical/health content,
sexual content, violence, gambling, contests, and loot-box questions were
answered `No` or `None`. No rating override was selected. App Store Connect
calculated and saved `4+`; the fresh reload continued to show `4+`.

### App Privacy

Both localizations saved and retained this calculator-specific privacy URL
after reload:

```text
https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html
```

The data-collection response was saved as:

```text
不收集資料
開發者不會從這個 App 收集任何資料。
```

The final privacy publication confirmation stated that publishing affirms the
response's correctness and compliance with the App Store Review Guidelines and
applicable law. Work stopped at that action-time gate. After the user explicitly
authorized `發佈`, the final publish action was completed. Fresh reload read-back
showed:

```text
由Phil Lon於數秒鐘前發佈
不收集資料
開發者不會從這個 App 收集任何資料。
```

### Pricing, availability, and compatibility

The initial price wizard was completed with United States (USD) price
`$0.00`. Its worldwide equivalence review showed zero prices for all listed
currencies, and the saved current-price detail continued to show `$0.00`,
`₺0.00`, `¥0.00`, `kr 0.00`, and equivalent zero-price entries after reload.

The saved availability and compatibility read-back after reload was:

| Field | Saved read-back |
| --- | --- |
| Price | Free (`$0.00` and equivalent zero prices) |
| Public availability | `175 個供應中` |
| Distribution method | `公開 — 所有人都可以在 App Store 上找到 App (預設)` |
| Apple silicon Mac | `供應此 App`, checkbox value `0` |
| Apple Vision Pro | `在 Apple Vision Pro 上供應此 App`, checkbox value `0` |

### Preserved remote boundary

- No screenshots were uploaded.
- No version promotional text, description, keywords, support URL, copyright,
  review information, or release option was changed.
- No build was uploaded or attached.
- No App Review submission was created.
- `新增以供審查`, submission, App release, and public release controls were not
  used.

This Task 6 checkpoint records only the App-level configuration above. It does
not claim screenshot upload, build attachment, version-metadata completion,
review-information completion, submission, “Add for Review”, or public App
Store release.

## App Store Connect product pages and Build attachment

- Configured and read back: 2026-07-30 19:27–19:50 Asia/Taipei
- Signed-in App Store Connect account: `Phil Lon`
- App: `編織計算器`
- Apple ID: `6795877892`
- Bundle ID: `com.phillon.KnittingCalculator`
- iOS version status: `1.0 準備提交` (`Prepare for Submission`)

Immediately before the remote changes, the screenshot manifest validator was
rerun and reported `18 screenshots valid`. The generated screenshot folders
contained only the expected numbered PNG files. Each file was uploaded
individually by its exact path, and App Store Connect was read back after every
upload before continuing.

### Traditional Chinese product page

The following values were saved, the page was reloaded, and every value was
read back:

| Field | Saved read-back |
| --- | --- |
| Promotional text | `免費、離線的編織與鉤針密度、平均加減針工具；不需要帳號。` |
| Description | Matches `AppStore/KnittingCalculator/Metadata/zh-Hant.md`; remaining-character count `3,715` |
| Keywords | `棒針,鉤針,針數,排數,毛線,針目,樣本,尺寸,換算,間隔` |
| Support URL | `https://phillon77.github.io/KnitNote/knitting-calculator.html` |
| Marketing URL | blank (optional) |
| Version | `1.0` |
| Copyright | `© 2026 Chen Chung Lung` |

The final screenshot read-back was:

| Device | Count | App Store Connect order |
| --- | ---: | --- |
| iPhone 6.5-inch | 5 | `01-home.png`, `02-gauge.png`, `03-adjustment.png`, `04-privacy.png`, `05-knitnote.png` |
| iPad 13-inch | 4 | `01-home.png`, `02-gauge.png`, `03-adjustment.png`, `04-privacy-knitnote.png` |

### English (U.S.) product page

App Store Connect initially inherited the Traditional Chinese screenshots for
English (U.S.). The per-device `Edit` control was used to create custom English
screenshot sets before any English file was uploaded. The following values
were saved, the page was reloaded, English (U.S.) was selected again, and every
value was read back:

| Field | Saved read-back |
| --- | --- |
| Promotional text | `Free, offline gauge and stitch-adjustment tools for knitting and crochet. No account required.` |
| Description | Matches `AppStore/KnittingCalculator/Metadata/en-US.md`; remaining-character count `3,118` |
| Keywords | `crochet,stitch,rows,needle,yarn,pattern,swatch,math,craft` |
| Support URL | `https://phillon77.github.io/KnitNote/knitting-calculator.html` |
| Marketing URL | blank (optional) |
| Version | `1.0` |
| Copyright | `© 2026 Chen Chung Lung` |

The final custom English screenshot read-back was:

| Device | Count | App Store Connect order |
| --- | ---: | --- |
| iPhone 6.5-inch | 5 | `01-home.png`, `02-gauge.png`, `03-adjustment.png`, `04-privacy.png`, `05-knitnote.png` |
| iPad 13-inch | 4 | `01-home.png`, `02-gauge.png`, `03-adjustment.png`, `04-privacy-knitnote.png` |

No screenshot remained in a processing or error state when its count and
ordered filename list were accepted.

### Attached Build

The Add Build dialog contained one candidate only:

```text
Version 1.0.0
Build 1
```

That exact `1.0.0 (1)` candidate was selected and saved. A final page reload
continued to show Build `1`, Version `1.0.0`, and `提供輕巧 APP: 否`. The
calculator identity remained Apple ID `6795877892` and bundle ID
`com.phillon.KnittingCalculator`. No export-compliance question was changed;
the previously verified no-relevant-encryption answer was preserved.

### Preserved Task 8 boundary

- App Review sign-in remained `需要登入`, value `1`.
- Review username, password, contact information, and notes remained blank.
- Release remained `自動發佈此版本`, value `1`.
- `新增以供審查`, submission, and release actions were not used.

## Final App Store Connect submission-readiness checkpoint

- Fresh final-checklist verification window from controller-confirmed Chrome
  History: 2026-07-30 20:19:21 through 20:22:04 +08:00 (Asia/Taipei). This is
  the verification visit window, not a claim that every save or action occurred
  at either endpoint. This local evidence update did not operate App Store
  Connect.
- App: `編織計算器`; Apple ID: `6795877892`; bundle ID:
  `com.phillon.KnittingCalculator`.
- iOS version status: `1.0 準備提交` (`Prepare for Submission`); attached
  candidate: Version `1.0.0`, Build `1`; App Clip: `No`.

### Final remote checklist

| Required item | Fresh saved/reloaded read-back |
| --- | --- |
| Traditional Chinese screenshots | 5 iPhone / 4 iPad |
| English (U.S.) screenshots | 5 iPhone / 4 iPad |
| Price | Free; Task 6 same-candidate evidence records `$0.00`; no Task 8 price mutation |
| Availability | Current schedule: 175 countries/regions, 175 available; Public value `1` |
| App Privacy | Published, `Data Not Collected`, calculator privacy URL retained |
| Sign-in | Not required, value `0`; username/password absent or blank |
| App Review contact | Existing account-holder first name, last name, telephone, and email saved; private values intentionally redacted |
| Review Notes | `No sign-in, account, purchase, permission, or network connection is required. Both calculators work immediately. Drafts stay on device. Copy/share is available. The optional KnitNote link opens a separate app or App Store page.` |
| Review attachment | None |
| Game Center | Off, value `0` |
| Release control | `Manually release this version`, value `1`; automatic release value `0` |
| Apple silicon Mac availability | Off, value `0` |
| Apple Vision Pro availability | Off, value `0` |

### Exact stop state

The version page still displayed `新增以供審查` / Add for Review, but it was
not clicked. The App Review submissions page contained no new submission for
this app. The calculator has not been added for review, submitted, approved,
released, or made public. No merge or push is authorized or claimed by this
checkpoint.

### Final local verification and Plan B ruling

- Full `swift test` exited `1` after `166.385s`: 855 of 856 tests passed
  across 73 suites. The full suite did not pass.
- The sole failed test was
  `staticReleaseAuditExecutesWithoutRecursingIntoSwiftTests`. Its two
  expectations failed because the pre-existing KnitNote
  `AppStore/Verification/release_audit.sh --static-only` audit rejects keyword
  duplication: Traditional Chinese repeats `編織`, `毛線`, and `織圖`; English
  repeats `knitting` and `pattern`. `git blame` dates those keyword lines to
  2026-07-23, before the independent calculator plan.
- The human explicitly approved Plan B: retain that unrelated KnitNote failure
  as an accepted non-calculator concern for this Task 8 evidence commit, and do
  not modify KnitNote metadata or its keyword audit.
- The calculator-specific
  `AppStore/Verification/knitting_calculator_release_audit.sh --static-only`
  audit passed with `STATIC PRODUCT SCOPE PASS` and final
  `KNITTING CALCULATOR RELEASE AUDIT: PASS`.

### Tracked and untracked worktree boundary

After the Task 8 readiness commit, the tracked worktree was clean. The
remaining `git status --short` entries were only these pre-existing user/local
artifacts, which are excluded from the calculator candidate and both Task 8
evidence commits:

```text
?? .superpowers/brainstorm/
?? AppStore/KnittingCalculator/Screenshots/Raw/
?? AppStore/KnittingCalculator/Screenshots/__pycache__/
?? AppStore/Verification/__pycache__/
```

The controller explicitly ruled that the Raw screenshot sources and both
`__pycache__` directories pre-date Task 8, just as the local brainstorm does.
The user-data boundary requires preserving all four paths/categories rather
than deleting or committing them; this resolves the brief's stale expectation
that only `.superpowers/brainstorm/` would remain untracked. No user authority
to delete any of these artifacts exists.
