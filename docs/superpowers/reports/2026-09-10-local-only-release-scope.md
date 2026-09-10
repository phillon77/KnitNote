# 1.7.0 (13): local-only release assessment

User decision: after being offered deferral of cross-device iCloud sync to prioritize a releasable version, the user answered 好. This supersedes continued V4 integration for this release. Preserve existing sync source and plans; do not delete or activate them. Existing paired iPhone/Apple Watch functionality is not the deferred iCloud feature.

Inspected source: 006a7a7dc72b9006e92c2ace1d8cc2958aa081b0, docs/cross-device-sync-design. Five unrelated untracked files preserved. No source or test changes made during this assessment.

## Fresh findings

- KnitNoteApp's shipping composition still constructs JSONProjectStore.live through makeLocal and publishes the local session. Paired Watch starts after publication; this is not iCloud account-ready activation.
- Project settings remain 1.7.0 / 13.
- `python3 AppStore/Verification/metadata_check.py AppStore/Metadata`: PASS.
- `python3 AppStore/Verification/commercial_release_check.py --offline --configuration AppStore/CommercialConfiguration.json`: PASS (offline).
- `bash AppStore/Verification/release_audit.sh --static-only`: STATIC RELEASE AUDIT: PASS, exit 0. This does not run the full runtime test suite or archive validation.
- All 13 local metadata files still describe 1.5.1 in What's New. Structural metadata validation did not establish current release-copy accuracy. Rewrite against verified local-only changes before submission.
- The branch has substantial changes to JSONProjectStore, backup and App session/Watch code since local tag v1.6.0-build12. Inactive cloud startup does not establish absence of local regressions. The tag is not proof of the currently shipped binary.

## Remaining bounded release work

1. Identify the exact local-only feature delta and update all release-note locales without promising iCloud sync.
2. Fresh local feature/App session/backup/import/paired-Watch regression and unsigned iOS/macOS builds on the candidate; retain exact logs and SHA. Fix only release-blocking issues, with no new sync expansion.
3. Actual upgrade and physical-device smoke acceptance, then candidate signing/archive and live App Store Connect checks with exact candidate authorization. Verify build 13 availability rather than assuming it is unused.

No signed archive, push, upload, submission or live App Store Connect check occurred. Static PASS is not release-ready. The native V4 plan is paused, not complete; its unfinished tests are not release blockers if the verified candidate does not activate that feature.

## Subsequent explicit version/copy decision

The user changed this local-only candidate to **1.6.1 (13)** with What's New exactly **資料優化**. This supersedes the candidate version in the historical assessment above. Project/Xcode settings, release audit/candidate script, current-version test expectations and all 13 release-note locales were updated. Historical sync specifications and backup-version fixtures remain historical, not current release identity. The metadata validator now enforces the approved short localized notes instead of mandatory 1.5.1 feature prose; unrelated store fields and forbidden-claim checks remain covered. No feature source was modified for this version/copy change.

Fresh copy-change validation: the new current-note acceptance/rejection tests first failed against the old validator (2 test functions, 78 subtest failures). After updating the release-note contract, `python3 -m unittest AppStore.Verification.metadata_check_test` passed all 30 tests; `bash AppStore/Verification/release_audit.sh --static-only` returned STATIC RELEASE AUDIT: PASS, exit 0. Old release-note-specific tests were replaced by current exact-note and stale/modified-note rejection tests; unrelated store-field preservation and forbidden claims remain tested.

Additional diagnostic, not all-green: `python3 AppStore/Verification/commercial_release_check_test.py` ran 22 tests with 1 failure. Its integration fixture injects KNITNOTE_COMMERCIAL_CONFIGURATION and expects a paid-model error, but the existing production audit rejects environment overrides before that check. The audit's only change this turn is EXPECTED_VERSION. Do not weaken that rejection; the old test needs a separately scoped correction. An initial module-style invocation also failed import resolution; direct-file execution above is the actual suite result.

Version verification: bounded native Swift run, filter `ReleaseConfigurationContractTests|WatchPackagingContractTests|ReleaseCandidateIdentityTests`, passed 51 tests in 3 suites (114.996 seconds tests, 196.181 seconds command, exit 0). This includes parsed project settings and actual unsigned Xcode Release/Debug build-setting queries, not signed products. Compilation emitted a pre-existing deprecated String initializer warning in unchanged HighlightOverlayContractTests; no warning-free build claim. Full Core/App runtime and archive acceptance were not run.

## Approved About story implementation

The user's subsequent `ok` approved `docs/releases/1.6.1-about-story-review.md`. Settings on iOS/iPadOS and macOS now link to the story, with separate usage recommendations. Nine keys across 13 locales match the approved text exactly; Lemon's year is 2025. No data access, sync activation, or release-note expansion was introduced.

Fresh verification on the story changes:

- TDD: the new localization test first failed on the missing catalog key, then passed after implementation. Final `RuntimeLocalizationBehaviorTests|SettingsAboutVersionContractTests|WatchPackagingContractTests`: 24 tests / 3 suites PASS, exit 0 (1.331 seconds command).
- Initial Mac build exposed missing legacy-import source registration in the existing generated project. Regenerated with XcodeGen. Initial iOS build then exposed the preparation coordinator's AppVersionInfo dependency, intentionally unavailable on Watch. Excluded that unused-on-Watch coordinator in project.yml and regenerated again; no feature implementation changed.
- Unsigned macOS Debug build PASS, exit 0 (22.931 seconds). Unsigned generic iOS Debug build including Watch PASS after the exclusion, exit 0 (34.523 seconds).
- Read back compiled macOS and iOS Localizable.strings: all 117 story/usage values in each product exactly match the source catalog. The first inspection script could not parse Xcode's XML encoding directly with plistlib; the successful check used plutil JSON conversion.
- Final static release audit PASS; metadata and offline commercial configuration checks PASS. This does not supersede the previously documented commercial integration-test failure.
- Independent read-only review found no actionable story/project issues: no prior source memberships removed, unchanged target set/configurations/dependencies/resources, and no sync activation. Regeneration adds four legacy-import sources to the app, three to Watch, and the existing PhoneWatchNativeSessionLifecycleTests to app tests.

Limits: no live App launch, screenshot/physical layout acceptance, full upgrade regression, signed archive, push, upload, or App Store submission. The scoped story implementation is complete; release readiness is not established by these checks.

## Physical upgrade preflight after user backup confirmation

The user confirmed an exported backup. On 2026-09-10, read-only device queries verified the paired iPhone 17 Pro Max on iOS 26.6.1 still has KnitNote 1.6.0 (12). Candidate source remains 532aca4d42fe3db610655fdd22b2da8ef38d99f2 with no tracked code changes.

A development-signed Debug build using existing signing settings and that embedded source revision failed before installation (exit 65, 5.351 seconds). The app's iOS entitlements require CloudKit/container and push capabilities, but the current development profile contains neither. The relevant profile is unexpired (2027-07-26) and includes the test iPhone; this is a capability mismatch, not an expired profile or missing device. The available store profiles also lack those capabilities. No raw profiles or signing material were saved.

No install, uninstall, launch, device data modification, signing-portal update, upload or submission occurred. The next decision is whether to align the local-only release entitlements with deferred iCloud functionality, or authorize updating Apple signing capabilities/profiles. Do not silently strip permissions for a test-only build or enable cloud services to bypass this gate.

The user subsequently approved aligning this release with local-only capabilities. Removed CloudKit/container and APS permissions from both main-app entitlement files and removed remote-notification background mode from the project specification and generated Info.plist. App Group, Mac sandbox, user-selected read/write and network-client permissions remain unchanged. Watch/Share configuration and shipping composition were not modified; dormant cloud implementation/container configuration remains for future work, without granting cloud capability.

Updated exact source and signed-product audit allowlists to reject cloud permissions for this candidate rather than bypassing audit. Adapted fixtures to a no-cloud baseline and unexpected-permission rejection cases. The entitlement tests first failed with six issues against the old configuration; after the change, 14 entitlement/Watch packaging tests passed. Five source background-mode audit cases and the production static audit passed. These scoped checks are not full regression, device acceptance or distribution-signing proof.

Signed-artifact audit fixtures: 3 test functions PASS, including 22 unexpected cloud-permission/identifier-alias cases across iOS, macOS, Watch and Share, a preserved Mac-security rejection, and the canonical no-cloud archive acceptance case (155.708 seconds). These are controlled fixture tests, not actual signed archives.
