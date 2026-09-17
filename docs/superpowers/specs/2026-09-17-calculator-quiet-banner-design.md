# Knitting Calculator quiet banner

Approved in conversation on 2026-09-17: introduce a small AdMob banner on the home screen as a revenue experiment. One-time ad removal is a later phase, with pricing and StoreKit work outside this first change.

## Experience

- Home screen only, below the tool content and separate from navigation controls. Use a bottom safe-area inset so the banner never covers content.
- Standard 320 × 50 banner, centered, with a localized Advertisement label and breathing room. Hide the placement if the available width is too small. No large adaptive, collapsible, picture-in-picture, app-open, interstitial, rewarded, or full-screen ad formats.
- Never gate calculations, results, sharing, or navigation on consent or ad success. No loading spinner or error alert for failed ads.
- Disable video in the production AdMob banner unit; standard Google banner video starts muted. The global mute API is reserved for an app with user mute controls, so it is not used here; do not assume this is enforceable by the client alone. Rich-media animation remains possible.
- No automatic tracking authorization prompt. Request non-personalized ads, disable publisher first-party ID, and use UMP for required consent and privacy choices. Non-personalized does not mean no data collection.
- Use Google test IDs for explicitly enabled Debug testing. Default launch, screenshot mode, tests, and unconfigured Release builds must not explicitly start the SDK or make advertising requests. The linked SDK still validates a nonempty App ID at load time, so the official sample App ID is retained only as a development placeholder until real account setup; release enablement rejects it.
- Keep the SDK out of screenshot flows. Provide a local DEBUG-only placement preview for visual QA without networking.
- Production enablement requires actual IDs and explicit configuration readiness. Do not ship a test banner as revenue-generating inventory.

## Components

- `Model/CalculatorAdConfiguration.swift`: build/configuration policy; default disabled; validate identifiers; no SDK dependencies.
- `Home/CalculatorBannerView.swift`: SwiftUI placement and UIKit banner host; only load when attached to the correct scene; dispose banner on leaving home/backgrounding; collapse failed placements without retries in a tight loop.
- `Model/CalculatorAdConsent.swift`: session consent state, one SDK initialization after eligibility, settings entry for required privacy options. Consent errors leave calculator usable.
- `Settings/CalculatorSettingsView.swift`: required privacy options and an inappropriate-ad reporting link when advertising is configured.
- `KnittingCalculator/project.yml` and generated project: Google Mobile Ads and UMP packages; explicit debug test settings; release disabled until configured.

## Existing boundaries

The existing Calculator worktree is `feature/calculator-stitch-dictionary`. Do not change KnitNote's ad-free policy or historical release evidence. This approval supersedes the older Calculator ad-free product decision for this new version only.

The old Calculator release auditor rejects advertising dependencies. Preserve it as the ad-free release profile; the new advertising profile must allow only the named Google SDKs and retain checks against unrelated analytics, StoreKit purchases, and data exfiltration.

## Verification

Configuration tests: absent/invalid IDs disabled; Debug selects Google test ID even if production IDs exist; Release rejects sample IDs; screenshot and unit-test launch modes disabled; readiness flag required.

Lifecycle tests: no SDK initialization before consent eligibility; repeated callbacks do not initialize twice; leaving home destroys the banner; returning after privacy changes uses current eligibility; failed consent/ad request never changes calculator drafts.

UI acceptance: iPhone and iPad, narrow split view, portrait/landscape, large text, VoiceOver, background/reopen, offline, and failed ad load. Verify no content overlay, unexpected sound, or expanded ads. Live production creative behavior needs device observation after account configuration; test creatives alone do not prove production behavior.

## Release dependencies

AdMob owner must register the iOS app, create a Banner unit, turn off Video, disable automatic refresh for the initial experiment, configure Privacy & messaging, and complete account/app verification. Obtain App ID and banner unit ID; never request passwords or financial account details in chat.

Prepare new bilingual privacy copy reflecting Google SDK collection, update App Store privacy answers based on the actual SDK/configuration, and publish the policy with the advertising release. Do not publish future behavior while the released app is still ad-free. Revenue activation, store submission, and public-site publishing remain separate actions.

## References checked 2026-09-17

- https://developers.google.com/admob/ios/banner
- https://developers.google.com/admob/ios/privacy
- https://developers.google.com/admob/ios/global-settings
- https://support.google.com/admob/answer/7311346?hl=en
- https://developers.google.com/admob/ios/banner/collapsible
