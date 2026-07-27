# KnitNote 1.2 Release Candidate Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the current local `main` checkout into a reviewable KnitNote 1.2 release-candidate source state without touching unrelated untracked files or performing any upload or submission.

**Architecture:** Treat the three string catalogs as one localization deliverable, compare their semantic keys and values rather than their formatting, and keep the generated Watch scheme at the committed repository version. Update release evidence so the newly completed signed-device Share Extension acceptance is distinguished from the still-unperformed broader manual matrix.

**Tech Stack:** Swift Package Manager, Swift Testing, Xcode string catalogs, jq, Bash release audit, Git.

## Global Constraints

- Work only in the existing local `main` checkout because the user explicitly authorized this cleanup.
- Preserve `.superpowers/brainstorm/`, `KnitNote 5.xcodeproj/`, and `KnitNote 6.xcodeproj/`.
- Do not upload, submit, release, push, or edit App Store Connect.
- Do not claim the broader iPhone, iPad, macOS, migration, backup, or VoiceOver manual matrix passed.
- Record only the physical Share Sheet evidence already captured in `AppStore/Verification/ShareExtensionActivationVerification.md`.

---

### Task 1: Audit and complete the localization catalogs

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Verify: `KnitNoteShare/Localizable.xcstrings`
- Verify: `KnitNoteWatch/Localizable.xcstrings`
- Test: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: the current uncommitted Xcode string-catalog edits.
- Produces: three valid catalogs with non-empty English and Traditional Chinese values for every variation leaf.

- [ ] **Step 1: Reproduce the incomplete-catalog failure**

Run:

```bash
swift test --disable-sandbox --filter ReleaseConfigurationContractTests.staticReleaseAuditExecutesWithoutRecursingIntoSwiftTests
```

Expected before the punctuation fix: FAIL because `", "` lacks both localizations.

- [ ] **Step 2: Apply the minimal catalog fix**

Keep the English value as `", "` and set the Traditional Chinese value to `"、"` in `KnitNote/Localization/Localizable.xcstrings`.

- [ ] **Step 3: Verify catalog structure and completeness**

Run:

```bash
jq -e '.strings | length > 0' KnitNote/Localization/Localizable.xcstrings KnitNoteShare/Localizable.xcstrings KnitNoteWatch/Localizable.xcstrings
bash AppStore/Verification/release_audit.sh --static-only
```

Expected: jq exits 0; the audit prints `METADATA CHECK: PASS` and `RELEASE AUDIT: PASS`.

- [ ] **Step 4: Review semantic additions and removals**

Export each committed catalog with `git show HEAD:<path>` and compare `.strings | keys` against the working copy. Confirm removed keys are not still referenced by Swift sources and inspect value changes separately from Xcode formatting changes.

### Task 2: Remove the unintended Watch scheme rewrite

**Files:**
- Modify: `KnitNote.xcodeproj/xcshareddata/xcschemes/KnitNoteWatch.xcscheme`

**Interfaces:**
- Consumes: the ten-line Xcode-generated scheme diff.
- Produces: a Watch scheme byte-for-byte identical to the committed `HEAD` version.

- [ ] **Step 1: Review the scheme diff**

Run:

```bash
git diff -- KnitNote.xcodeproj/xcshareddata/xcschemes/KnitNoteWatch.xcscheme
```

Expected: only Xcode scheme-version and empty/generated attribute changes.

- [ ] **Step 2: Restore only those generated lines**

Use a scoped patch so the scheme again matches `HEAD`; do not reset or check out any other path.

- [ ] **Step 3: Verify the scheme is no longer modified**

Run:

```bash
git diff --quiet -- KnitNote.xcodeproj/xcshareddata/xcschemes/KnitNoteWatch.xcscheme
```

Expected: exit 0.

### Task 3: Record the signed-device Share Extension acceptance

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`
- Modify: `AppStore/Verification/PatternLibraryVerification.md`
- Modify: `AppStore/AppStoreSubmission.md`
- Reference: `AppStore/Verification/ShareExtensionActivationVerification.md`

**Interfaces:**
- Consumes: the verified 2026-07-27 iPhone Share Sheet and duplicate-import evidence.
- Produces: release documentation that marks only the Share inbox device scenario as passed and retains all other manual gaps.

- [ ] **Step 1: Add a failing documentation contract**

Add a test requiring `PatternLibraryVerification.md` to reference `ShareExtensionActivationVerification.md`, identify the physical iPhone, and retain a statement that the remaining manual matrix is incomplete.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --disable-sandbox --filter ReleaseConfigurationContractTests.patternLibraryVerificationRecordsScopedPhysicalShareAcceptance
```

Expected: FAIL because the pattern-library report does not yet contain the scoped device evidence.

- [ ] **Step 3: Update both release documents**

Change the Share inbox matrix row to PASS with a link to `ShareExtensionActivationVerification.md`. Update the submission summary to say signed iPhone Share Sheet import and duplicate handling passed while the broader iPhone/iPad/manual matrix remains incomplete.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same focused command.

Expected: 1 test in 1 suite passes.

### Task 4: Verify and commit the cleanup

**Files:**
- Commit only:
  - `KnitNote/Localization/Localizable.xcstrings`
  - `KnitNoteShare/Localizable.xcstrings`
  - `KnitNoteWatch/Localizable.xcstrings`
  - `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`
  - `AppStore/Verification/PatternLibraryVerification.md`
  - `AppStore/AppStoreSubmission.md`
  - `docs/superpowers/plans/2026-07-27-release-candidate-cleanup.md`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: a verified local `main` commit; no remote side effects.

- [ ] **Step 1: Run full verification**

Run:

```bash
swift test --disable-sandbox --quiet
bash AppStore/Verification/release_audit.sh --static-only
git diff --check
```

Expected: 831 tests in 68 suites pass; metadata and release audits pass; diff check exits 0.

- [ ] **Step 2: Confirm exact commit scope**

Run:

```bash
git status --short
git diff --stat
```

Expected: the Watch scheme is absent; the three protected untracked paths remain untouched.

- [ ] **Step 3: Commit the approved cleanup**

Stage only the seven listed files and commit:

```bash
git commit -m "chore: finalize KnitNote 1.2 release candidate"
```

- [ ] **Step 4: Verify the resulting repository state**

Run:

```bash
git status --short
git log -1 --oneline
```

Expected: only the protected untracked paths remain; the new commit is at local `main`.
