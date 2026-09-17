# Calculator 1.2.0 (5) advertising audit

The 1.1.0 ad-free auditor remains unchanged. The new audit is a separate advertising profile and does not reuse historical PASS results.

Run from the independent Calculator checkout:

```sh
bash AppStore/Verification/knitting_calculator_ads_release_audit.sh --prepare-only
python3 -m unittest discover -s AppStore/Verification -p '*ads_release_audit_test.py'
bash AppStore/Verification/knitting_calculator_ads_release_audit.sh --archive /absolute/path/Calculator.xcarchive --readiness /absolute/path/readiness.json
```

`--prepare-only` verifies source preparation and explicitly prints “not release readiness”. An optional archive is also inspected in preparation mode, but disabled ads are permitted. Default mode is the release gate: an archive, enabled source and archive flags, and all external acceptance evidence are mandatory. Missing files/tool errors fail closed. Requirements: Python 3, XcodeGen, macOS plutil; archive inspection additionally needs codesign and security.

Source checks cover exact GoogleMobileAds 13.9.0 / UMP 3.1.0 URLs and versions in XcodeGen, generated project and resolved pins; only local KnittingCalculatorCore and ShortRowKit; no additional local package dependencies, dynamic libraries, binary targets or vendored frameworks; expected target package links, version/build, production AdMob IDs and advertising policy link. Production Swift is scanned for prohibited ad formats, ATT, common direct-network/analytics/commerce APIs. The pre-existing locked StoreKit rating exception remains the sole exception. Comments and strings are stripped for API scanning; dangerous string-key ad switches are checked separately. Debug sample IDs remain permitted; production IDs must exactly match this account.

Archive inspection checks app identity/version/build, production IDs, delayed measurement configuration, absence of ATT permission text, expected SDK privacy manifest contents, app privacy manifest presence, signing integrity, expected Apple Distribution team, App Store provisioning profile, policy and App Store links embedded in executable. A changed SDK manifest requires investigation and a consciously reviewed baseline; do not edit a vendor manifest to satisfy this check.

## External acceptance evidence

The readiness JSON must also carry `source_revision` equal to the current full Git HEAD, `source_sha256` equal to the printed production-source digest, and `archive_sha256` equal to the printed app-bundle digest. These exact values bind acceptance to the candidate, not just its version. Preparation mode prints the same digests, including the archive digest when `--archive` is provided.

The readiness JSON has `version: "1.2.0"`, `build: "5"` and a `gates` object. Each of the following keys must contain `{"accepted": true, "evidence": "path or URL plus specific dated verification result"}`:

- `admob_account`
- `admob_app`
- `app_ads_txt`
- `banner_video_and_refresh_disabled`
- `publisher_consent_refuse_accept_withdraw`
- `iphone_acceptance`
- `ipad_acceptance`
- `privacy_policy_live`
- `app_store_privacy_review`
- `release_tests`

Supply genuine reviewed evidence for this candidate. Do not turn checklist placeholders into accepted records. Reference the archive path in the acceptance record. Any source/resource/archive change invalidates the matching digest. The tool validates presence and shape, not truth or freshness of statements. It does not operate AdMob or App Store Connect, publish privacy answers, or authorize submission.

## Current result and limits

2026-09-17: source preparation PASS; eight regression tests PASS (including real source-copy mutations for SDK drift, wrong version, and injected ShortRowKit dependency). Default release audit correctly FAILS for missing archive/evidence and `CALCULATOR_ADS_READY=NO`. No release archive has been certified by this audit.

Known substantive blockers remain AdMob account/app/app-ads verification, actual publisher consent refuse/accept/withdraw flow, full physical iPhone/iPad acceptance and final App Store privacy review. A published UMP message or test banner observation alone cannot satisfy these gates. Existing successful setup work can be recorded after its evidence is reviewed; absent JSON acceptance is not a claim that every external step is unfinished.

This is a bounded configuration/source audit, not a Swift semantic analyzer or proof of absence of all network/exfiltration paths. It does not prove consent/lifecycle behavior, production creative behavior, accessibility, metadata correctness, live policy availability or SDK runtime behavior. Run app/package tests, localization/metadata review and device acceptance separately, attach their evidence, and inspect the final archive privacy report. Archive branch validation requires a real signed archive; synthetic Info.plist tests cover identity failures only. No localization requirement is added to ShortRowKit beyond its approved en/zh-Hant with English fallback.

## Candidate digest contract

`archive_sha256` hashes the entire `Products/Applications/KnittingCalculator.app` tree in sorted relative-path order. Each entry contributes a length-prefixed JSON header (path, file/directory/link type, POSIX mode, payload length) and full file bytes or link target bytes. It includes resources, privacy manifests, signatures and provisioning profile; timestamps are excluded. Symlinks escaping the app are rejected. This is an app-tree content digest, not a hash of an archive ZIP or just the executable. Re-signing changes it.

`source_sha256` hashes sorted relative filenames and all file bytes under KnittingCalculator, Packages/KnittingCalculatorCore and Packages/ShortRowKit, plus the generated project and Package.resolved. It excludes .build, .git, .swiftpm and documentation. It deliberately includes uncommitted/untracked production files: a dirty checkout is accepted only if the acceptance evidence matches both its full HEAD and this exact source digest. The audit cannot independently prove that a supplied archive was built from those files; acceptance must attest the build provenance for the two printed digests. No evidence should be copied between a diagnostic build and the final candidate.

Archive validation currently requires an Apple Distribution-signed App Store-profile archive. A development-signed diagnostic archive is expected to fail this check; that failure does not indicate app compilation or functionality failure. This check is not an App Store IPA export or upload verification.
