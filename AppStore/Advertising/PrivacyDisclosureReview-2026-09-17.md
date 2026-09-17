# 1.2.0 App Privacy review worksheet

Preparation only; not submitted App Store answers. Existing no-data-collection wording must not be reused for the advertising release.

Sources checked 2026-09-17:
- https://developers.google.com/admob/ios/privacy/data-disclosure
- https://developers.google.com/admob/ios/targeting
- https://developers.google.com/admob/ios/privacy/ad-serving-modes
- SDKPrivacyManifests-2026-09-17.json (GoogleMobileAds 13.9.0, UMP 3.1.0).

| Data type | SDK manifest linked to user | Tracking declaration | Purposes to review |
| --- | --- | --- | --- |
| Coarse location | Yes for ads; no for UMP | No | Third-party advertising, analytics; UMP app functionality |
| Device ID | Yes | Yes in SDK manifest | Third-party advertising, analytics |
| Advertising data | Yes | No | Third-party advertising, analytics |
| Product interaction | Yes for ads; no for UMP | No | Third-party advertising, analytics; UMP app functionality |
| Performance data | No | No | Third-party advertising, analytics; UMP app functionality |
| Crash data | No | No | Analytics |
| Other diagnostic data | No | No | Third-party advertising, analytics |

Google's manifest also lists developer advertising for several types. Do not automatically copy every SDK capability as an enabled app purpose; reconcile against the actual app configuration and current Apple definitions. Conversely, lack of ATT does not prove that all SDK collection is absent. Google disclosure guidance describes user-associated performance data, while the installed manifest marks performance data unlinked; investigate this difference before finalizing the answer.

Current code turns off publisher personalization and publisher first-party ID before SDK initialization and contains no ATT prompt. Non-personalized ads can still use identifiers for frequency capping/reporting. Refusing consent can permit limited ads; `canRequestAds=true` after refusal is not proof that personalization consent was granted. No location permission or precise-location payload is intentionally requested by the app.

The delivered test consent form includes generic personalized-ad and precise-location wording and 210 partners. This is observed publisher-message content, not evidence that the app supplies precise location. Review the configured partner/purpose scope against the intended non-personalized implementation before release.

Remaining: actual final-archive privacy report, Apple's current linking/tracking definitions, publisher-message scope, final purpose/linking/tracking answers, portal draft/readback and publication authorization as applicable. Do not mark this worksheet accepted or publish incomplete answers.
