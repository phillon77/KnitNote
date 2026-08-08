# KnitNote 1.4.1 Two-Stage Distribution Export Plan

**Goal:** Produce and fail-closed audit exact-commit Apple Distribution-signed iOS/Watch/Share and macOS upload artifacts without uploading them.

**Architecture:** Automatic Archive followed by local automatic App Store export; audit the exported IPA/pkg contents and bind them to provenance.

## Global constraints

- No App source/data/localization/version/build changes.
- No signing asset/profile mutation, network provisioning, upload, submission, pricing, selected-build, or App Store Connect action.
- Never use `destination=upload` or `-allowProvisioningUpdates`.
- Complete source/static/archive audits remain mandatory.

### Task 1: Implement the local two-stage candidate creator

**Files:**
- Create: `AppStore/Verification/ExportOptions-AppStore.plist`
- Modify: `AppStore/Verification/create_release_candidate.sh`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseCandidateIdentityTests.swift`

- [ ] Add RED contracts for automatic Development Archive settings, local-only export options, two export commands, ordering, and forbidden upload/provisioning-update flags.
- [ ] Implement the minimal two-stage creator and regenerate the project.
- [ ] Verify resolved settings, focused tests, Bash/plist syntax, XcodeGen drift, and static audit.
- [ ] Commit and independently review.

### Task 2: Audit and inventory the exported Distribution products

**Files:**
- Modify: `AppStore/Verification/release_audit.sh`
- Modify: `AppStore/Verification/release_archive_manifest.py`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`

- [ ] Add RED fixtures proving the audit requires and inspects the exported IPA/pkg product roots rather than development-signed archive roots.
- [ ] Add provenance RED coverage for any mutation to IPA/pkg/distribution summary/export options.
- [ ] Implement deterministic extraction, cleanup, distribution-product audit, and expanded provenance.
- [ ] Run focused and full release-audit tests, Python/Bash syntax, static audit, and commit.
- [ ] Independently review.

### Task 3: Build and verify the immutable candidate

- [ ] Run focused screenshot tests, the complete Swift suite, and static audit.
- [ ] Run the supported creator outside the tool sandbox so Xcode can read the local keychain/profiles, without provisioning updates.
- [ ] Verify provenance and all four exported products' Distribution authority/team/profile/version/build/source/locales/privacy/entitlements.
- [ ] Re-run the formal archive audit and require `RELEASE AUDIT: PASS`.
- [ ] Stop before distribution and report remaining physical/App Store gates.

### Task 4: Harden candidate publication and retained artifacts

**Files:**
- Modify: `AppStore/Verification/create_release_candidate.sh`
- Modify: `AppStore/Verification/release_audit.sh`
- Modify: `AppStore/Verification/release_archive_manifest.py`
- Modify: `AppStore/Screenshots/python_runtime.sh`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`
- Modify: `docs/superpowers/specs/2026-08-08-two-stage-distribution-export-design.md`
- Modify: release verification reports/runbook as needed

- [x] Add RED coverage for raw Packaging.log exclusion, private candidate permissions, complete retained-artifact provenance, Mac pkg container signature, exclusive publication races, and wrong Pillow versions.
- [x] Remove raw packaging logs before provenance; reject retained logs; inventory every retained candidate artifact except the canonical provenance file itself.
- [x] Require a trusted Apple-issued Mac installer package signature for team `9CFPAUL5N5`, while retaining exported app bundle checks.
- [x] Publish with same-filesystem atomic exclusive rename and fail closed if the destination appeared during the long build.
- [x] Enforce the checked-in Pillow pin and document the truthful boundary: local export does not upload the app or use provisioning updates, but macOS export may contact authorized Apple developer services for managed package signing.
- [x] Verify focused/full tests, static/formal audits, independent review, and leave the quarantined credential-bearing candidate untouched pending explicit authorization.
