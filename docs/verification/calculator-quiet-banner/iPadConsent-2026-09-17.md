# iPad diagnostic acceptance — 2026-09-17

Installed the same Debug 1.2.0 (5) artifact used for iPhone QA from `/tmp/calculator-consent-qa-device/Build/Products/Debug-iphoneos/KnittingCalculator.app` onto the user's physical iPad Air 5. Uses real publisher app ID and Google test banner; EEA consent geography enabled only for this test device.

Launch log `/tmp/calculator-120-ipad-consent.log` confirms required consent, ads ineligible before selection, and privacy options required.

User reported all instructed checks normal:
- Do not consent returns to Home.
- Shoulder short-row sample results readable in portrait and landscape.
- Home banner does not obstruct controls, has no sound or full-screen presentation, and disappears upon entering the calculator.

User subsequently confirmed that Settings privacy options could reopen and change, a full app termination/relaunch did not repeat the consent form, and shoulder short-row calculation worked after enabling airplane mode and disabling Wi-Fi.

These are user-reported results for the diagnostic build, not acceptance of a final signed Release archive. The instructed iPad privacy-options, persistence, offline, layout and sample-banner checks are complete. Network state and consent storage were not independently instrumented.
