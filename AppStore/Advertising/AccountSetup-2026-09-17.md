# AdMob account setup — 2026-09-17

Live UI read-back in the user's signed-in Safari session:

- iOS App Store ID: `6795877892`, developer `Chen Chung Lung`, displayed name `编织计算器`.
- AdMob App ID: `ca-app-pub-2353011769485623~3090056510`.
- Banner name: `Calculator Home Banner`.
- Banner unit ID: `ca-app-pub-2353011769485623/1883207041`.
- Reopened saved unit settings: text/image/rich media checked, **Video unchecked**, **automatic refresh disabled**.
- Mediation groups and campaigns: zero active entries in unit list.
- Account status: review pending. App verification: still unverified after publishing app-ads.txt and requesting a fresh check.

App and banner were created in this session, not merely drafted. No paid campaign was created.

## Local configuration

Release now contains the real IDs but `CALCULATOR_ADS_READY` stays **NO**. Debug explicitly retains Google's sample app and unit IDs. No live ad requests are enabled by this change.

`RootVerification/app-ads.txt` contains the exact publisher line displayed by AdMob. Target public URL is `https://phillon77.github.io/app-ads.txt`. The current KnitNote Pages deployment serves `https://phillon77.github.io/KnitNote/`; putting this file only under `/KnitNote/` would not meet the root URL requirement.

User approved public repository creation and verification-file publication. Created `phillon77/phillon77.github.io`, published `app-ads.txt` and `.nojekyll`, and verified legacy Pages serves `main` at `/`. Deployed commit: `99413f4527fde1a108c22c3a58656fafd423dee7`; Pages build status `built`. Public URL returned HTTP 200 and matched the exact publisher line including its trailing newline. Existing KnitNote workflow-based Pages configuration was read back unchanged.

AdMob Verify app and Check for updates still returned “我們無法驗證” with a generic details-mismatch message. This is not a successful app verification. Apple's Taiwan lookup for app 6795877892 has no sellerUrl; the public store HTML includes the privacy URL and support URL but no Developer Website link. Google requires the Apple marketing URL to expose that link: https://support.google.com/admob/answer/9363762 . Next release preparation must add `https://phillon77.github.io/KnitNote/knitting-calculator.html` as the marketing URL and verify its public appearance. No App Store metadata was changed in this publication step. Google also documents up to 24 hours for file crawl/status propagation; that delay does not resolve a missing marketing URL.

Privacy messaging, updated policy publication, store privacy disclosures, physical-device acceptance, and final advertising release remain pending. No store submission or Git push occurred.

AdMob unit settings: https://admob.google.com/v2/apps/3090056510/adunits/1883207041/edit

## App Store marketing URL draft — 2026-09-17

User requested the next step after verification-file publication. Live App Store Connect for app 6795877892 showed 1.1.0 (build 4) as 已可發佈, with its marketing URL empty and disabled. Created iOS 1.2.0 as 準備提交 (Prepare for Submission), with manual release selected and no build attached.

Saved `https://phillon77.github.io/KnitNote/knitting-calculator.html` as the marketing URL for all 13 existing localizations: en-US, da, ja, el, fr-FR, fi, no, nl-NL, sv, de-DE, zh-Hant, ko, zh-Hans. Reloaded the page and read back every localization. Norwegian initially failed read-back, was corrected, saved, and verified again after switching away and back. Final UI left on Traditional Chinese.

Draft URL: https://appstoreconnect.apple.com/apps/6795877892/distribution/ios/version/inflight

This changes draft metadata only. The public listing has not been updated by this step and app-ads.txt verification is not yet complete. No upload, App Review submission, release, or privacy declaration publication occurred. Local project remains version 1.1.0 and `CALCULATOR_ADS_READY=NO`; align local version/build with the reviewed candidate during release preparation.

Remaining draft content still inherits the prior ad-free descriptions and review notes. Before any advertising release, update all localized descriptions and notes, finalize and publish the advertising privacy policy, configure UMP messaging, validate store data disclosures against the actual SDK/archive, and finish physical-device QA. The former ad-free archive audit also needs an advertising-specific revision. Account/app readiness still must be checked before enabling live requests.

## Privacy message and device preparation

Created and saved European message `Calculator European Privacy`; live list confirms Draft, Publish off, Calculator selected, English plus 10 languages. Do not consent enabled across regions; targeting EEA/UK/Switzerland only. Privacy policy URL missing, so publishing remains unavailable. See PrivacyReadiness-2026-09-17.md for settings and remaining disclosure checks.

Signed Debug device build succeeded and installed on the paired iPhone. devicectl confirmed launch with `-calculatorTestAds`. User acceptance requested; no audio/layout/consent pass is claimed. This test uses Google's sample App ID, so it does not validate the publisher's saved European message. No privacy policy or App Store privacy declaration was published.

## Approved privacy policy publication — 2026-09-17

User explicitly approved publishing the reviewed bilingual advertising policy. Published as https://phillon77.github.io/knitting-calculator-ads-privacy.html in phillon77/phillon77.github.io at commit 3d2be46a589e563757645740fbeb7b4a6d810436. Pages build returned built; HTTP fetch succeeded and byte comparison matched the local HTML. Browser read-back confirmed both languages and version 1.2.0 scope. Internal draft/release-review instructions were excluded from the public page; approved policy paragraphs were preserved.

Saved this URL as Calculator's AdMob privacy-policy URL and saved the European message draft. Message list remains Draft, Publish off. This step did not publish the consent message, change App Store privacy disclosures, replace the old public policy, or enable live ads. The app's in-app policy link and the store policy URL still need alignment during advertising-release preparation.

## European consent QA — publication

User approved next step for actual consent/refusal testing. Published Calculator European Privacy and read back 已發布. This publishes the consent message only, not an app binary or live ad readiness. Built and installed a signed Debug consent-QA variant with real App ID, Google sample Banner ID, and readiness NO. Launched with forced EEA test geography and explicit UMP test device environment value; physical-device observations remain pending. App tests rerun successfully in /tmp/calculator-consent-qa-tests.log. Simulator cross-check in progress.

## Account verification blocker confirmed

Live AdMob home: 付款資料設定完成; 您的帳戶尚未通過審核; 我們正在驗證您的帳戶. Google SDK support identifies publisher-account verification as required for European message delivery. Consent QA is blocked pending account verification, not merely presumed message propagation. App verification remains a separate unresolved release prerequisite.
