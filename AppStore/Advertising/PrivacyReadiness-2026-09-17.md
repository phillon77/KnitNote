# Advertising privacy readiness — 2026-09-17

## Verified implementation

- GoogleMobileAds 13.9.0 and UMP 3.1.0, iOS arm64 privacy manifests inspected; raw snapshot in SDKPrivacyManifests-2026-09-17.json. This is an SDK artifact inspection, not a final archive privacy report.
- Before SDK start: publisherPrivacyPersonalizationState disabled, publisher first-party ID disabled, general content rating. No ATT request in this integration. Release ads remain disabled.
- Consent info updates once per app session; ad requests require UMP eligibility. Failed initial update prevents requests. A required privacy-options entry is exposed in Settings. Failed changes suppress ad reload and show a retryable error.
- Debug uses Google's sample App ID and Banner ID. It cannot validate this publisher's configured message: UMP selects messages by the App ID. A separate consent QA configuration with the real App ID and registered test device/forced test geography is needed before claiming the publisher message works.

## Disclosure review

| Data category | Google Ads manifest linked | Tracking flag | Purposes in SDK manifest |
| --- | --- | --- | --- |
| Coarse location | Yes | No | Third-party ads, developer ads, analytics |
| Device ID | Yes | Yes | Third-party ads, developer ads, analytics |
| Advertising data | Yes | No | Third-party ads, developer ads, analytics |
| Product interaction | Yes | No | Third-party ads, developer ads, analytics |
| Performance data | No | No | Third-party ads, developer ads, analytics |
| Crash data | No | No | Analytics |
| Other diagnostic data | No | No | Third-party ads, developer ads, analytics |

UMP additionally declares coarse location, performance data, and product interaction for app functionality, not linked and not tracking. These are SDK declarations; the final app's answers must reflect actual configured use. Do not infer no data collection from non-personalized ads, or infer that lack of ATT alone resolves every tracking disclosure. Confirm the Device ID tracking flag against the final integration and Apple's definitions before submitting privacy answers. Do not remove or modify vendor manifests to hide declared behavior.

Sources checked today:
- https://developers.google.com/admob/ios/privacy/data-disclosure
- https://developers.google.com/admob/ios/privacy
- https://developers.google.com/admob/ios/targeting

## Backend message preparation

For European regulations: use the Calculator app only, enable an equally accessible Do not consent choice and Manage options, and show only where applicable. Review supported languages, policy link, vendor list, and preview before publishing. Do not introduce an ATT explainer because the app does not request ATT. Inspect US-state privacy controls separately and preserve applicable opt-out access.

Current public policy describes the ad-free app. The advertising policy must explain the new version explicitly and preserve clarity about older ad-free versions. PrivacyPolicy.draft.md is unpublished. A working public policy URL is required before the publisher message is ready to publish; draft review is not a published configuration.

## Physical-device acceptance

- Normal launch: no ads unless test mode explicitly requested.
- Test banner: home only, no audio, no full-screen or expandable ad; navigate to Gauge and Adjustment and confirm calculations remain unobstructed.
- Change text size and rotate; check small widths and iPad split-screen.
- Offline launch and unavailable consent service: calculations and saved drafts still usable.
- Publisher consent QA (separate from sample banner): first launch in forced EEA test geography, refuse/consent/manage options, reopen privacy options, interrupt navigation and background/foreground transitions. No duplicate consent dialogs, no blocked calculator, correct eligibility on return.
- VoiceOver: no hidden banner focus and usable privacy controls.

Status: signed Debug device build succeeded (log /tmp/calculator-quiet-banner-device-build.log), and devicectl installed com.phillon.KnittingCalculator on the paired iPhone. devicectl confirmed launch with -calculatorTestAds. User visual/audio confirmation remains pending. No physical-device acceptance or completed privacy declaration is claimed.

The European message editor was configured with name Calculator European Privacy, selected Calculator app 6795877892, Do not consent enabled for all regions, Manage options retained, geography restricted to EEA/UK/Switzerland, English default plus 10 additional supported app languages (zh-CN, da, ja, el, fr, fi, no, nl, sv, de). The current picker does not offer Traditional Chinese or Korean. Save completed; list read-back shows Calculator European Privacy, English plus 10 languages, Calculator app, status Draft, Publish off. Publish is disabled because the selected app has no policy URL. Preview still contains generic precise-geolocation language and zero partners; account vendor/purpose settings were inspected: 198 common partners selected, automatic addition of ad sources off, fallback-message coverage on, legitimate-interest controls on/default on, consent mode off, special feature 2 off, zero publisher purposes. No account-wide values were changed. The generic editor preview is not evidence that this app collects precise location; inspect the rendered publisher form after policy URL configuration.

User initially reported no test banner, then confirmed seeing it after the test app was relaunched with --terminate-existing and console capture. Cause of the initial report is not established (loading delay or observation timing possible). Console showed UMP initialization; installed Info.plist verified Google's sample App ID. Temporary diagnostic logging was prepared but removed before any diagnostic rebuild was installed. Do not claim the separate publisher consent message was tested. Audio, absence on calculator pages, offline behavior, and other physical-device checks remain to be confirmed.

Approved policy publication completed: https://phillon77.github.io/knitting-calculator-ads-privacy.html . Calculator's AdMob policy URL was saved. European message remains unpublished draft; real-App-ID consent QA and remaining physical-device checks are still pending.

## Published-message test result (2026-09-17)

European message publication confirmed in live AdMob list (已發布). Signed device QA build succeeded and installed; launch initiated with explicit test-device environment plus EEA/reset flags. Simulator QA build succeeded, its installed Info.plist read back the real publisher App ID, and console confirmed EEA debug path was entered. UMP update returned consentStatus=2 (notRequired), canRequestAds=true, privacyOptionsRequirementStatus=2 (notRequired). Therefore no real publisher consent/refusal/withdrawal flow has been exercised yet. AdMob publication UI warns of up to one hour for propagation; propagation is a possible cause, not a confirmed diagnosis. Do not change geography targeting to all users to force a test.

App tests passed after QA-only changes (/tmp/calculator-consent-qa-tests.log). Release live-ad readiness remains NO. Debug-only QA code takes a UMP test identifier from launch environment; it is never embedded in source. Subsequent persistence tests must omit -calculatorResetConsent.

Next: after publication propagation, repeat one EEA test request and inspect UMP status; if still notRequired, investigate account/app readiness and delivered message configuration. Only after a required form appears can refusal, consent, change options, app restart persistence, and offline behavior be signed off. User input on physical-device UI remains pending.

Physical launch later returned a concrete Locked error: iPhone could not be unlocked, so the newly installed consent-QA process did not launch. User must unlock the device before retrying. This is separate from the simulator's successful request returning notRequired.

After user unlocked iPhone, devicectl launch succeeded. Physical console confirmed requesting EEA test consent, then consentStatus=2 (notRequired), eligible=true, privacyOptions=2 (notRequired), matching the simulator result. Log: /tmp/calculator-consent-qa-console-retry.log. Locking is no longer the blocker. Actual consent/refusal/options acceptance remains pending a delivered required form; message propagation is only a hypothesis. Keep live readiness NO.

## Identified account-level prerequisite — 2026-09-17

Live AdMob home read-back: payment information setup complete; account has not passed review; Google is verifying the account. UI says normally 24 hours, rarely up to two weeks. App verification also remains pending. Published European message is still listed as Published with Unpublish switch on.

Google Mobile Ads SDK Team's answer (2024-11-20) to the same notRequired/unavailable symptom explicitly states EU regulation messages are not served until the publisher account is verified: https://groups.google.com/g/google-admob-ads-sdk/c/WRn0QfZ4BHs . The live pending account status therefore establishes an unmet prerequisite. This is stronger evidence than the earlier propagation-only hypothesis, but does not prove that all remaining configuration or application behavior is correct.

Payment setup is complete; no request to re-enter financial information is needed. Wait for account verification, then rerun the real-App-ID EEA QA. Do not republish messages repeatedly, expand geography, weaken consent gating, or enable live ads to bypass this prerequisite. No automatic monitoring was created.
