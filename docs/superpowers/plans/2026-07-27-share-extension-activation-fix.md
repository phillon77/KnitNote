# KnitNote Share Extension Activation Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KnitNote appear in the iPhone Files PDF share sheet and preserve exact-one PDF, PNG, JPEG, or HEIC import behavior.

**Architecture:** First run one disposable `TRUEPREDICATE` device build to isolate activation-rule discovery from extension registration. If that build appears, replace the indexed activation rule with Apple’s nested `SUBQUERY` form, driven by a failing contract test; if it does not appear, stop and return to registration diagnostics instead of applying the planned permanent rule.

**Tech Stack:** Swift 6, Swift Testing, Foundation, UniformTypeIdentifiers, XcodeGen, UIKit Share Extension, iOS 26 physical-device verification.

## Global Constraints

- The disposable `TRUEPREDICATE` value must never be committed.
- Production accepts exactly one PDF, PNG, JPEG, or HEIC attachment; empty, URL-only, and multiple-attachment requests remain rejected.
- App Group remains exactly `group.com.phillon.KnitNote`.
- Main App bundle identifier remains `com.phillon.KnitNote`; Share Extension bundle identifier remains `com.phillon.KnitNote.share`.
- Do not change `ShareViewController`, data models, pattern storage, project links, localization, versions, build numbers, or backup formats.
- Preserve the main checkout’s existing uncommitted and untracked files.
- Do not merge, push, archive, or submit this branch automatically.
- Physical-device acceptance overrides simulator, contract-test, or build success.

---

### Task 1: Isolate Activation Rule from Extension Registration

**Files:**
- Temporarily modify and restore: `KnitNoteShare/Info.plist`
- Do not commit any file

**Interfaces:**
- Consumes: existing signed `KnitNote` iOS app and embedded `KnitNoteShare.appex`
- Produces: one binary diagnostic result: KnitNote appears or does not appear in the Files PDF share sheet

- [ ] **Step 1: Confirm the isolated worktree and clean starting state**

Run:

```bash
git rev-parse --show-toplevel
git branch --show-current
git status --short
```

Expected: the top level ends in `.worktrees/share-extension-activation-fix`, the branch is `codex/share-extension-activation-fix`, and only committed design/plan history exists.

- [ ] **Step 2: Save the production activation rule as evidence**

Run:

```bash
plutil -extract NSExtension.NSExtensionAttributes.NSExtensionActivationRule raw KnitNoteShare/Info.plist
```

Expected: output contains `extensionItems[0].attachments`.

- [ ] **Step 3: Apply the single-variable diagnostic rule**

Temporarily replace only the value of `NSExtensionActivationRule` in `KnitNoteShare/Info.plist` with:

```xml
<string>TRUEPREDICATE</string>
```

Do not change `project.yml` and do not stage the plist.

- [ ] **Step 4: Build the signed physical-device app**

Run:

```bash
xcodebuild -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -configuration Debug \
  -destination 'id=00008150-00042D6A3612401C' \
  -derivedDataPath /tmp/KnitNoteShareActivationDiagnostic \
  build
```

Expected: exit 0 and `/tmp/KnitNoteShareActivationDiagnostic/Build/Products/Debug-iphoneos/KnitNote.app/PlugIns/KnitNoteShare.appex` exists.

- [ ] **Step 5: Verify the built diagnostic payload**

Run:

```bash
plutil -extract NSExtension.NSExtensionAttributes.NSExtensionActivationRule raw \
  /tmp/KnitNoteShareActivationDiagnostic/Build/Products/Debug-iphoneos/KnitNote.app/PlugIns/KnitNoteShare.appex/Info.plist
codesign --verify --deep --strict \
  /tmp/KnitNoteShareActivationDiagnostic/Build/Products/Debug-iphoneos/KnitNote.app
```

Expected: the first command prints `TRUEPREDICATE`; signature verification exits 0.

- [ ] **Step 6: Install in place and perform the device diagnostic**

Run:

```bash
xcrun devicectl device install app \
  --device 00008150-00042D6A3612401C \
  /tmp/KnitNoteShareActivationDiagnostic/Build/Products/Debug-iphoneos/KnitNote.app
```

On the iPhone, open one PDF in Files, open the share sheet, choose “More” if needed, and look for KnitNote.

Expected branch:

- If KnitNote appears: activation-rule discovery is the isolated failing boundary; continue to Task 2.
- If KnitNote does not appear: stop this plan, restore the plist, and investigate extension registration/principal-class discovery under a new hypothesis.

- [ ] **Step 7: Restore the production plist before any commit**

Run:

```bash
git restore KnitNoteShare/Info.plist
git diff --exit-code -- KnitNoteShare/Info.plist
git status --short
```

Expected: no plist diff and no uncommitted `TRUEPREDICATE`.

---

### Task 2: Replace the Indexed Rule with a Nested SUBQUERY Contract

**Files:**
- Modify: `Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift`
- Modify: `project.yml`
- Regenerate: `KnitNoteShare/Info.plist`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `NSExtensionActivationRule` from `KnitNoteShare/Info.plist`
- Produces: one canonical nested predicate used identically by XcodeGen source and generated plist

- [ ] **Step 1: Write the failing structural contract**

In `activationRuleAcceptsExactlyOneSupportedFileAndNothingElse()`, add these expectations immediately after loading `rule`:

```swift
#expect(rule.contains("SUBQUERY(extensionItems, $extensionItem"))
#expect(rule.contains("SUBQUERY($extensionItem.attachments, $attachment"))
#expect(!rule.contains("extensionItems[0]"))
```

Retain all existing behavior assertions for PDF, PNG, JPEG, HEIC, empty, URL-only, multiple attachments, and a supported attachment that also advertises URL.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter ShareExtensionTargetContractTests
```

Expected: test failure because the current rule contains `extensionItems[0]` and lacks the outer nested `SUBQUERY`.

- [ ] **Step 3: Replace the source activation rule**

Set `project.yml`’s `NSExtensionActivationRule` to this one-line predicate:

```text
extensionItems.@count == 1 AND SUBQUERY(extensionItems, $extensionItem, $extensionItem.attachments.@count == 1 AND SUBQUERY($extensionItem.attachments, $attachment, ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "com.adobe.pdf" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.png" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.jpeg" OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO "public.heic").@count == 1).@count == 1
```

- [ ] **Step 4: Regenerate Xcode artifacts**

Run:

```bash
xcodegen generate
plutil -lint KnitNoteShare/Info.plist
```

Expected: XcodeGen exits 0 and `plutil` reports `OK`.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter ShareExtensionTargetContractTests
```

Expected: `ShareExtensionTargetContractTests` passes with zero failures.

- [ ] **Step 6: Prove the regression test detects the old rule**

Temporarily restore only the old indexed predicate in `KnitNoteShare/Info.plist`, run:

```bash
swift test --filter ShareExtensionTargetContractTests
```

Expected: the structural contract fails. Restore the generated canonical plist with `xcodegen generate`, rerun the focused test, and expect it to pass.

- [ ] **Step 7: Review the scoped diff**

Run:

```bash
git diff --check
git diff -- Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift project.yml KnitNoteShare/Info.plist KnitNote.xcodeproj/project.pbxproj
git status --short
```

Expected: only the test, activation-rule source, and generated Xcode artifacts are changed.

- [ ] **Step 8: Commit the tested permanent fix**

Run:

```bash
git add \
  Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift \
  project.yml \
  KnitNoteShare/Info.plist \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "fix: register share extension for pattern files"
```

Expected: one commit containing no `TRUEPREDICATE`.

---

### Task 3: Full Verification and Physical Acceptance

**Files:**
- Create: `AppStore/Verification/ShareExtensionActivationVerification.md`

**Interfaces:**
- Consumes: canonical nested activation rule and existing share-import pipeline
- Produces: fresh automated, build, packaging, and physical-device evidence

- [ ] **Step 1: Run plist and release configuration checks**

Run:

```bash
plutil -lint \
  KnitNoteShare/Info.plist \
  KnitNote/KnitNote-iOS.entitlements \
  KnitNoteShare/KnitNoteShare.entitlements \
  KnitNoteShare/PrivacyInfo.xcprivacy
bash AppStore/Verification/release_audit.sh
```

Expected: all plist files report `OK`; release audit exits 0.

- [ ] **Step 2: Run the complete Swift suite**

Run:

```bash
swift test --disable-sandbox
```

Expected: exit 0 with zero failed tests.

- [ ] **Step 3: Build iOS and macOS from clean DerivedData**

Run:

```bash
xcodebuild -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/KnitNoteShareActivationFinal/iOS \
  clean build
xcodebuild -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/KnitNoteShareActivationFinal/macOS \
  clean build
```

Expected: both commands exit 0.

- [ ] **Step 4: Verify the final embedded extension**

Run:

```bash
test -d /tmp/KnitNoteShareActivationFinal/iOS/Build/Products/Debug-iphoneos/KnitNote.app/PlugIns/KnitNoteShare.appex
plutil -extract NSExtension.NSExtensionAttributes.NSExtensionActivationRule raw \
  /tmp/KnitNoteShareActivationFinal/iOS/Build/Products/Debug-iphoneos/KnitNote.app/PlugIns/KnitNoteShare.appex/Info.plist
codesign --verify --deep --strict \
  /tmp/KnitNoteShareActivationFinal/iOS/Build/Products/Debug-iphoneos/KnitNote.app
```

Expected: the extension exists, the rule contains both nested `SUBQUERY` clauses and no `TRUEPREDICATE`, and signature verification exits 0.

- [ ] **Step 5: Build and install the physical-device version in place**

Run:

```bash
xcodebuild -quiet \
  -project KnitNote.xcodeproj \
  -scheme KnitNote \
  -configuration Debug \
  -destination 'id=00008150-00042D6A3612401C' \
  -derivedDataPath /tmp/KnitNoteShareActivationFinal/Device \
  build
xcrun devicectl device install app \
  --device 00008150-00042D6A3612401C \
  /tmp/KnitNoteShareActivationFinal/Device/Build/Products/Debug-iphoneos/KnitNote.app
```

Expected: build and install both exit 0 without uninstalling the existing App.

- [ ] **Step 6: Perform the physical acceptance sequence**

On iPhone:

1. Open `/tmp/KnitNotePhysicalVerification/KnitNote-Share-Test.pdf` after AirDrop or another single PDF in Files.
2. Open Share, then “More” if needed.
3. Confirm KnitNote appears.
4. Tap KnitNote and finish the import.
5. Open KnitNote’s 織圖 library and confirm the PDF exists with nonzero size.
6. Share the same PDF again and confirm the existing duplicate-result behavior, with no empty or corrupt file.

Expected: all six observations pass. If any physical observation fails, record the exact failing step and do not claim the bug fixed.

- [ ] **Step 7: Record fresh verification evidence**

Create `AppStore/Verification/ShareExtensionActivationVerification.md` containing:

```markdown
# Share Extension Activation Verification

- Device: iPhone 17 Pro Max, iOS 26.5.2
- Root-cause diagnostic: TRUEPREDICATE made KnitNote appear / did not make KnitNote appear
- Focused contract test: command, date, result
- Full Swift suite: test count, suite count, failures
- iOS build: command and exit result
- macOS build: command and exit result
- Embedded extension rule: canonical nested SUBQUERY, no TRUEPREDICATE
- Physical PDF share sheet: KnitNote visible or not visible
- Physical import: imported file visible with nonzero size
- Duplicate import: observed result
```

Replace every slash-separated alternative with the single observed result and include no unverified claim.

- [ ] **Step 8: Final clean-state and safety audit**

Run:

```bash
rg -n "TRUEPREDICATE" project.yml KnitNoteShare KnitNote.xcodeproj Tests AppStore/Verification
git diff --check
git status --short
```

Expected: `rg` returns no matches; only the uncommitted verification report is present.

- [ ] **Step 9: Commit the verification report**

Run:

```bash
git add AppStore/Verification/ShareExtensionActivationVerification.md
git commit -m "docs: verify share extension activation fix"
```

Expected: the branch contains the design, implementation plan, permanent fix, and evidence commits, with a clean worktree.

- [ ] **Step 10: Stop for integration decision**

Report the exact commits, tests, builds, and physical results. Offer merge, push/PR, keep branch, or discard; do not select or execute an integration option without the user’s explicit choice.
