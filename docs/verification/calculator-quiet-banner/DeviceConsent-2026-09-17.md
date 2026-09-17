# iPhone consent QA — 2026-09-17

Diagnostic Debug 1.2.0 (5), real publisher app ID, Google sample banner unit, EEA test geography. Installed from `/tmp/calculator-consent-qa-device/Build/Products/Debug-iphoneos/KnittingCalculator.app`. This is not final Release candidate acceptance.

Initial launch log `/tmp/calculator-120-device-consent-refuse.log`: consent required, ads ineligible before selection, privacy options required.

After being instructed to choose Do not consent and try shoulder short-row sample calculation, user reported: normal return to Home, calculation results visible, banner visible without sound and no full-screen ad.

Result: user-observed refusal/navigation/calculation/noninterruptive sample-banner checks passed. A visible sample ad after refusal does not establish production ad eligibility or personalized consent.

User subsequently confirmed that Settings privacy options reopened, Consent returned normally to the app, and options could be reopened again to change the choice.

User then confirmed the instructed sequence of choosing Do not consent, terminating the app through the iPhone app switcher, and reopening: no automatic repeat form and calculation remained functional. These are user-reported physical-device results; no new console trace was collected for these steps.

Passed for this diagnostic build: privacy-options reopening, accept/change-choice navigation, refusal persistence across full relaunch, and calculation availability after relaunch.

User confirmed the instructed offline check: airplane mode enabled, Wi-Fi disabled, app reopened, shoulder short-row sample calculation displayed results without hanging. This is user-reported evidence; network state was not independently instrumented.

Passed for this diagnostic build: offline relaunch and shoulder calculation availability.

Pending: iPad acceptance and matching final signed Release candidate verification.
