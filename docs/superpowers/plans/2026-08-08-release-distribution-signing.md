# KnitNote 1.4.1 Distribution Signing Remediation Plan

**Goal:** Make the supported exact-commit candidate workflow create Apple Distribution-signed iOS/Watch/Share and macOS archives for team `9CFPAUL5N5`.

**Architecture:** Declare per-configuration signing identities in `project.yml`, regenerate the Xcode project, and make the candidate creator preflight and explicitly pass the same Release signing contract.

## Global constraints

- No App behavior, data schema, localization, version `1.4.1`, or build `8` changes.
- No network, certificate/profile creation or download, upload, submission, pricing, build selection, or App Store Connect mutation.
- Keep the complete release audit fail-closed.

### Task 1: Lock the distribution-signing contract

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `AppStore/Verification/create_release_candidate.sh`

- [ ] Add a failing test that requires Debug `Apple Development`, Release `Apple Distribution`, the expected team, a local-identity preflight, and explicit Distribution overrides on both archive commands.
- [ ] Run the focused test and record RED.
- [ ] Implement the minimal settings/script changes and regenerate the project.
- [ ] Run the focused test, Xcode project generation drift check, Bash syntax, and static release audit.
- [ ] Commit the remediation.

### Task 2: Rebuild and verify the immutable candidate

- [ ] Re-run focused screenshot tests and the complete Swift/static audit.
- [ ] Create a new candidate path using the remediation commit SHA.
- [ ] Verify all four bundled products use Apple Distribution, retain exact version/build/source/locales/privacy/entitlements, and pass the formal archive audit.
- [ ] Stop before distribution and report remaining physical/App Store gates.
