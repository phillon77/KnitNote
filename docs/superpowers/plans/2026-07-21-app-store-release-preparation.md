# KnitNote App Store Release Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce and validate the complete bilingual KnitNote 1.0 App Store package for iPhone, iPad, Apple Watch, and macOS, stopping immediately before the final App Review submission action.

**Architecture:** The repository is the reviewable source of truth for metadata, privacy/support pages, screenshot recipes, release audit scripts, and verification evidence; App Store Connect receives exact copies of those approved artifacts. A release-only synthetic dataset makes screenshots deterministic without touching normal user data. Privacy and packaging are checked both statically and in the built archives before any listing is considered ready.

**Tech Stack:** Swift 6/SwiftUI, Swift Testing, Xcode/XcodeBuild, XcodeGen 2.45.4, property-list privacy manifests, dependency-free HTML/CSS GitHub Pages, Python 3 + Pillow for repeatable screenshot composition, App Store Connect web interface and Xcode Organizer.

## Global Constraints

- This plan begins only after `docs/superpowers/plans/2026-07-21-watch-counter-sync.md` is fully implemented and verified.
- Release version is `1.0`, initial build is `1`, Apple ID is `6793023054`, team is `9CFPAUL5N5`.
- Bundle IDs remain `com.phillon.KnitNote` and `com.phillon.KnitNote.watch`.
- Traditional Chinese is primary; English (United States) is the second localization.
- Paid download: US$2.99 and NT$90 at launch, available in all 175 regions, manual release, no subscription.
- Do not claim AI, cloud sync, automatic stitch recognition, social, marketplace, or shopping features.
- No account, advertising, analytics, tracking, developer server, remote fonts, third-party scripts, or cookies.
- Use synthetic data only; no family image, production-device photo, private filename, contact detail, or personal project data in screenshots.
- The public support email is `lzz.1999@icloud.com`.
- Do not submit iOS or macOS versions for App Review without a new explicit user instruction after final review.
- Schedule US$4.99 for the thirty-first day only after the actual public release date is known.

---

### Task 1: Establish an executable release audit

**Files:**
- Create: `AppStore/Verification/release_audit.sh`
- Create: `AppStore/Verification/metadata_check.py`
- Create: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`
- Modify: `AppStore/AppStoreSubmission.md`

**Interfaces:**
- Produces: `release_audit.sh [--archives DIR]` with nonzero exit for blocker findings.
- Produces: `metadata_check.py AppStore/Metadata` validating UTF-8, field limits, forbidden claims, and duplicate keywords.
- Submission checklist uses statuses `NOT STARTED`, `READY`, `VERIFIED`, `BLOCKED`; it may never infer success.

- [ ] **Step 1: Write failing release-configuration tests**

```swift
import Foundation
import Testing

@Suite struct ReleaseConfigurationContractTests {
    @Test func projectUsesProductionIdentifiersAndVersion() throws {
        let yaml = try sourceText("project.yml")
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote"))
        #expect(yaml.contains("PRODUCT_BUNDLE_IDENTIFIER: com.phillon.KnitNote.watch"))
        #expect(yaml.contains("MARKETING_VERSION: 1.0.0"))
        #expect(yaml.contains("DEVELOPMENT_TEAM: 9CFPAUL5N5"))
    }

    @Test func submissionSourceHasEveryRequiredSection() throws {
        let text = try sourceText("AppStore/AppStoreSubmission.md")
        for heading in ["Commercial configuration", "Builds", "Localizations", "Privacy",
                        "Screenshots", "Review information", "Manual release", "Final approval boundary"] {
            #expect(text.contains(heading))
        }
    }
}
```

- [ ] **Step 2: Run and verify the expected contract failure**

Run: `swift test --filter ReleaseConfigurationContractTests`

Expected: FAIL until the submission file contains every required section.

- [ ] **Step 3: Implement the metadata checker**

The script parses Markdown fields of the form `- Name: value`, enforces name/subtitle ≤30 characters, keywords ≤100 bytes, promotional text ≤170 characters, requires non-empty description/release notes/support URL/privacy URL, rejects repeated comma-separated keywords, and rejects case-insensitive terms `AI`, `cloud sync`, `automatic stitch recognition`, `social network`, `marketplace`, `subscription`.

```python
LIMITS = {"Name": 30, "Subtitle": 30, "Promotional text": 170, "Keywords": 100}
FORBIDDEN = (" ai ", "cloud sync", "automatic stitch recognition", "social network", "marketplace", "subscription")
```

Report every error as `path: field: explanation`; exit 0 only when both localization files pass.

- [ ] **Step 4: Implement the shell audit**

Use `set -euo pipefail`. Run `swift test`, `xcodegen dump --type parsed-yaml`, localization checks, `plutil -lint` on manifests/plists, `metadata_check.py`, `git diff --check`, source searches for network/analytics SDKs, and—when `--archives` is supplied—verify bundle IDs, versions, Watch embedding, icons, manifests, and unexpected frameworks/endpoints. Print a final `RELEASE AUDIT: PASS` only when no blocker exists.

- [ ] **Step 5: Run and commit the audit foundation**

Run: `chmod +x AppStore/Verification/release_audit.sh AppStore/Verification/metadata_check.py && swift test --filter ReleaseConfigurationContractTests && AppStore/Verification/release_audit.sh`

Expected: scripts execute; metadata/manifest checks may report later-task blockers, but configuration tests pass.

```bash
git add AppStore/Verification AppStore/AppStoreSubmission.md Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "build: establish App Store release audit"
```

### Task 2: Audit privacy behavior and add valid manifests

**Files:**
- Create: `KnitNote/PrivacyInfo.xcprivacy`
- Create: `KnitNoteWatch/PrivacyInfo.xcprivacy`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Create: `AppStore/Verification/PrivacyAudit.md`
- Create: `Tests/KnitNoteCoreTests/PrivacyManifestContractTests.swift`

**Interfaces:**
- Both manifests declare `NSPrivacyTracking = false`, empty tracking domains/data collection.
- Main manifest declares UserDefaults `CA92.1` and FileTimestamp `C617.1` plus `3B52.1`; Watch declares UserDefaults `CA92.1` if its cache selection uses UserDefaults, otherwise omit that category.
- `PrivacyAudit.md` maps every declaration to exact source/API and observed behavior.

- [ ] **Step 1: Write failing manifest tests**

Decode each plist and assert exact root keys, no collected data, no tracking, no unexpected reason values, main manifest includes `NSPrivacyAccessedAPICategoryFileTimestamp` reasons `C617.1` and `3B52.1`, and app-local preferences use `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`.

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter PrivacyManifestContractTests`

Expected: FAIL because manifests are absent.

- [ ] **Step 3: Complete and document the source audit**

Run:

```bash
rg -n "UserDefaults|@AppStorage|stat\(|fstat\(|creationDate|modificationDate|contentModificationDate|volumeAvailableCapacity|systemUptime" KnitNote KnitNoteWatch Sources
rg -n "URLSession|NWConnection|Network\.|Firebase|Analytics|Telemetry|tracking|https?://" KnitNote KnitNoteWatch Sources Package.swift project.yml
```

Record that `@AppStorage("languageSelection")` is app-only (`CA92.1`); backup file metadata inside the app work/container uses `C617.1`; user-selected backup/package metadata uses `3B52.1`. If the audit finds any additional Apple required-reason category, stop this task, select the matching current Apple-approved reason, add an explicit contract assertion, and document the source line before building.

- [ ] **Step 4: Add the exact plist contents and resources**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>NSPrivacyTracking</key><false/>
<key>NSPrivacyTrackingDomains</key><array/>
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyAccessedAPITypes</key><array>
  <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key><array><string>C617.1</string><string>3B52.1</string></array></dict>
  <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryUserDefaults</string>
    <key>NSPrivacyAccessedAPITypeReasons</key><array><string>CA92.1</string></array></dict>
</array>
</dict></plist>
```

The Watch plist contains only categories actually used by the Watch files. Add manifests as target resources in `project.yml`, regenerate, and never hand-edit only the `.pbxproj`.

- [ ] **Step 5: Verify manifest placement and commit**

Run: `plutil -lint KnitNote/PrivacyInfo.xcprivacy KnitNoteWatch/PrivacyInfo.xcprivacy && xcodegen generate && swift test --filter PrivacyManifestContractTests`.

Build iOS, macOS, and Watch, then use `find` to confirm iOS/watch manifests at bundle root and macOS at `Contents/Resources/PrivacyInfo.xcprivacy`.

```bash
git add KnitNote/PrivacyInfo.xcprivacy KnitNoteWatch/PrivacyInfo.xcprivacy project.yml KnitNote.xcodeproj/project.pbxproj AppStore/Verification/PrivacyAudit.md Tests/KnitNoteCoreTests/PrivacyManifestContractTests.swift
git commit -m "privacy: declare KnitNote local data behavior"
```

### Task 3: Author the exact bilingual App Store metadata

**Files:**
- Create: `AppStore/Metadata/zh-Hant.md`
- Create: `AppStore/Metadata/en-US.md`
- Modify: `AppStore/AppStoreSubmission.md`
- Modify: `AppStore/KnitNotePricing.md`

**Interfaces:**
- Support URL: `https://phillon77.github.io/KnitNote/support.html`.
- Privacy URL: `https://phillon77.github.io/KnitNote/privacy.html`.
- Marketing URL: `https://phillon77.github.io/KnitNote/`.
- Metadata checker from Task 1 is the acceptance gate.

- [ ] **Step 1: Add Traditional Chinese copy**

Use these exact headline fields:

```markdown
- Name: KnitNote
- Subtitle: 編織計數、圖解與毛線管理
- Promotional text: 六組計數器、圖解高亮與手寫標記、編織日記、毛線庫和實用計算工具，陪你從第一針一路織到完成。
- Keywords: 編織,毛線,鉤針,棒針,計數器,圖解,密度,針數,毛線庫,編織日記
- Support URL: https://phillon77.github.io/KnitNote/support.html
- Marketing URL: https://phillon77.github.io/KnitNote/
- Privacy URL: https://phillon77.github.io/KnitNote/privacy.html
- What's New: KnitNote 1.0 正式推出：管理作品與毛線、使用六組自訂計數器、閱讀及標記圖解、記錄編織歷程，並可備份與還原資料。
```

The full description opens with `把注意力留給手上的毛線。KnitNote 把作品進度、六組計數器與圖解放在清楚、安靜的畫面裡。` Then list only the approved implemented features and close with `一次購買，沒有訂閱。資料留在你的裝置上；只有你主動匯出時才會建立備份。`

- [ ] **Step 2: Add English copy**

Use these exact headline fields:

```markdown
- Name: KnitNote
- Subtitle: Knitting counters & patterns
- Promotional text: Six named counters, focused pattern reading, project journals, yarn inventory, and practical calculators—from first stitch to finished project.
- Keywords: knitting,crochet,row counter,pattern,gauge,yarn,stitch counter,project journal
- Support URL: https://phillon77.github.io/KnitNote/support.html
- Marketing URL: https://phillon77.github.io/KnitNote/
- Privacy URL: https://phillon77.github.io/KnitNote/privacy.html
- What's New: KnitNote 1.0 brings project and yarn management, six named counters, focused pattern reading and markup, progress journals, calculators, backup, and restore.
```

The full description opens with `Keep your attention on the yarn in your hands. KnitNote puts project progress, six counters, and patterns in one calm, readable workspace.` Close with `One-time purchase. No subscription. Your working data stays on your device; a backup is created only when you explicitly export one.`

- [ ] **Step 3: Validate content and pricing record**

Run: `python3 AppStore/Verification/metadata_check.py AppStore/Metadata`.

Expected: `METADATA CHECK: PASS`. Update pricing doc with US$2.99, NT$90, 175 regions, and the formula `public release date + 30 full days = final promotional day; next calendar day = US$4.99 effective date` without inventing a date.

- [ ] **Step 4: Commit metadata**

```bash
git add AppStore/Metadata AppStore/AppStoreSubmission.md AppStore/KnitNotePricing.md
git commit -m "docs: author bilingual App Store metadata"
```

### Task 4: Build and locally verify the bilingual privacy/support site

**Files:**
- Create: `AppStore/PrivacyPolicy.md`
- Create: `AppStore/SupportSite/index.html`
- Create: `AppStore/SupportSite/support.html`
- Create: `AppStore/SupportSite/privacy.html`
- Create: `AppStore/SupportSite/styles.css`
- Create: `AppStore/SupportSite/404.html`
- Create: `AppStore/SupportSite/.nojekyll`
- Create: `.github/workflows/pages.yml`
- Create: `AppStore/Verification/site_check.py`

**Interfaces:**
- Static files work without JavaScript and without external requests.
- Every page has `lang`, bilingual navigation, skip link, semantic headings, visible keyboard focus, and `mailto:lzz.1999@icloud.com`.
- GitHub Pages deploys exactly `AppStore/SupportSite` to `https://phillon77.github.io/KnitNote/`.

- [ ] **Step 1: Write the bilingual privacy source of truth**

Include effective date `2026-07-21`, app identity/contact, local storage, camera and user-selected file access, explicit backup export, no account/ads/analytics/tracking/developer server, Apple App Store/payment handling, retention/deletion by the user, children's privacy without collecting personal data, policy changes, and contact. Chinese and English must make the same claims.

- [ ] **Step 2: Implement the three dependency-free pages**

The overview page explains supported iPhone/iPad/Apple Watch/macOS workflow. Support covers: create/edit/complete/resume project, six counters, long-press decrement/reset, pattern import, camera denial recovery, backup export/restore package selection, Watch pending synchronization, and contact. Privacy renders the complete policy, not a summary.

Use CSS variables:

```css
:root { --cloud:#f7f7ff; --sky:#eaf2ff; --lavender:#ebe4ff; --berry:#a53b78; --ink:#29324a; --flower:#fff2b8; }
body { color:var(--ink); background:linear-gradient(145deg,var(--sky),var(--cloud) 52%,var(--lavender)); }
:focus-visible { outline:3px solid var(--berry); outline-offset:3px; }
@media (prefers-reduced-motion: reduce) { *,*::before,*::after { animation:none!important; transition:none!important; } }
```

Use local CSS shapes/SVG for cloud, flower, yarn, and Lemon accents; do not embed the family painting or fetch any asset/font.

- [ ] **Step 3: Implement and run the site checker**

Parse the HTML with Python standard library. Reject `script`, `iframe`, `http://`, remote `https://` assets, missing language/heading/mail link, missing privacy claims, absent reduced-motion/focus CSS, or broken relative links.

Run: `python3 AppStore/Verification/site_check.py AppStore/SupportSite`.

Expected: `SITE CHECK: PASS`.

- [ ] **Step 4: Review locally in browser before publication**

Run: `python3 -m http.server 8088 --directory AppStore/SupportSite`, inspect all pages at narrow phone and wide desktop sizes, keyboard through every link, disable JavaScript, and confirm no network request leaves localhost. Stop the server after review.

- [ ] **Step 5: Add Pages deployment and commit**

The workflow uses `actions/checkout`, `actions/configure-pages`, `actions/upload-pages-artifact` with `path: AppStore/SupportSite`, and `actions/deploy-pages`, restricted to `main` plus manual dispatch with `pages: write` and `id-token: write`.

```bash
git add AppStore/PrivacyPolicy.md AppStore/SupportSite AppStore/Verification/site_check.py .github/workflows/pages.yml
git commit -m "docs: add bilingual KnitNote support site"
```

### Task 5: Add deterministic synthetic screenshot mode

**Files:**
- Create: `Sources/KnitNoteCore/Demo/StoreScreenshotFixtures.swift`
- Create: `KnitNote/App/StoreScreenshotMode.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Create: `Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift`

**Interfaces:**
- Launch arguments: `-storeScreenshotMode YES`, `-storeScreenshotScene <scene>`, `-storeScreenshotLanguage zh-Hant|en`.
- Scene enum: `projects`, `counters`, `patternHighlight`, `patternMarkup`, `patternNotes`, `journal`, `yarn`, `calculators`.
- Data resides in a temporary/in-memory screenshot root, never live Application Support.

- [ ] **Step 1: Write failing fixture determinism/privacy tests**

Assert two generated archives encode identically with a fixed clock/UUID source, contain exactly the intended synthetic projects/six counters/yarns/journal entries, and contain none of `lzz.1999`, `/Users/`, `IMG_`, `截圖`, EXIF GPS keys, or family asset names.

- [ ] **Step 2: Run and confirm failure**

Run: `swift test --filter StoreScreenshotFixturesTests`

Expected: FAIL because fixture APIs are missing.

- [ ] **Step 3: Implement isolated fixtures and scene routing**

Create knitted-swatch sample imagery programmatically, not from user photos. Use stable names such as `雲朵披肩`/`Cloud Shawl`, counters `排數/Rows`, `花樣重複/Pattern Repeat`, `袖窿/Armhole`, `領口/Neckline`, `左袖/Left Sleeve`, `右袖/Right Sleeve`, and representative nonzero values. Include a generated two-page pattern PDF with harmless chart symbols for reader scenes.

Only activate this store when both `DEBUG` or a dedicated `StoreScreenshots` build configuration and the launch flag are present. Production Release without that configuration always calls `JSONProjectStore.live()`.

- [ ] **Step 4: Run tests and smoke-launch scenes**

Run: `swift test --filter StoreScreenshotFixturesTests`, build iOS Simulator/macOS, launch every scene argument once, and confirm live data directory timestamps are unchanged.

- [ ] **Step 5: Commit screenshot mode**

```bash
git add Sources/KnitNoteCore/Demo KnitNote/App/StoreScreenshotMode.swift KnitNote/App/KnitNoteApp.swift Tests/KnitNoteCoreTests/StoreScreenshotFixturesTests.swift
git commit -m "feat: add isolated App Store screenshot fixtures"
```

### Task 6: Create the repeatable watercolor screenshot pipeline

**Files:**
- Create: `AppStore/Screenshots/README.md`
- Create: `AppStore/Screenshots/manifest.json`
- Create: `AppStore/Screenshots/capture.sh`
- Create: `AppStore/Screenshots/compose.py`
- Create: `AppStore/Screenshots/validate.py`
- Create: `AppStore/Screenshots/requirements.txt`
- Create generated outputs under: `AppStore/Screenshots/Generated/<locale>/<platform>/`

**Interfaces:**
- Manifest defines locale, platform, scene, device, exact output size, headline, and output filename.
- `capture.sh` saves raw simulator/window screenshots only under `Raw/`.
- `compose.py` creates opaque PNG/JPEG deliverables; `validate.py` enforces dimensions, language, count, alpha absence, and private-data denylist.

- [ ] **Step 1: Define the 28-frame manifest**

Use 14 frames per locale: iPhone 5, iPad 4, Mac 3, Watch 2. Exact Traditional Chinese headlines:

```text
把每件作品，織到完成
六組計數器，輕點就記
圖解與進度，同一個畫面
留住每一步成果
毛線與計算，井然有序
讓圖解成為主角
橫向或交叉高亮
手寫標記重要細節
頁面筆記與六組計數
在大螢幕整理所有作品
集中管理每份圖解
看清家中的毛線庫
抬腕就能繼續計數
離線也能使用六組計數器
```

Exact English counterparts:

```text
Knit every project to completion
Six counters, one simple tap
Patterns and progress together
Keep every step of the journey
Yarn and calculations, organized
Let the pattern take center stage
Highlight rows or chart positions
Mark important details by hand
Page notes beside all six counters
Manage every project on a larger screen
Keep every pattern together
See your yarn inventory clearly
Raise your wrist and keep counting
All six counters work offline
```

- [ ] **Step 2: Implement capture automation**

Use iPhone 17 Pro Max, iPad Pro 13-inch, Apple Watch simulator at an accepted native size, and a 16:10 Mac capture. Boot/erase only dedicated screenshot simulators, set locale before launch, apply a deterministic status bar, launch scene arguments, wait for the accessibility-ready marker, assign the selected identifier to `DEVICE_UDID`, and call `xcrun simctl io "$DEVICE_UDID" screenshot`.

- [ ] **Step 3: Implement watercolor composition**

Pin Pillow in `requirements.txt`. Preserve real UI as at least 78% of frame area. Add only pale blue/lavender cloud wash, small flowers, berry headline, and occasional tiny Lemon/yarn accent in safe margins. Never cover system bars, controls, pattern content, or counter values. Export without alpha.

Accepted masters:

- iPhone portrait `1320x2868`.
- iPad portrait `2064x2752`.
- Mac `2880x1800`.
- Watch native accepted size matching the selected simulator (prefer `416x496`).

- [ ] **Step 4: Generate and validate both localizations**

Run:

```bash
python3 -m venv /tmp/knitnote-screenshots-venv
/tmp/knitnote-screenshots-venv/bin/pip install -r AppStore/Screenshots/requirements.txt
AppStore/Screenshots/capture.sh zh-Hant
AppStore/Screenshots/capture.sh en
/tmp/knitnote-screenshots-venv/bin/python AppStore/Screenshots/compose.py AppStore/Screenshots/manifest.json
/tmp/knitnote-screenshots-venv/bin/python AppStore/Screenshots/validate.py AppStore/Screenshots/manifest.json
```

Expected: `28 screenshots valid`; no alpha, size, language, safe-area, or denylist failures.

- [ ] **Step 5: Visually inspect every frame and commit sources**

Create a contact sheet, inspect at 100%, and record approval in the submission checklist. Commit scripts/manifest/README and final generated files only after visual approval; do not commit raw captures containing simulator paths or transient status.

```bash
git add AppStore/Screenshots AppStore/AppStoreSubmission.md
git commit -m "assets: prepare bilingual App Store screenshots"
```

### Task 7: Publish and verify the support/privacy URLs

**Files:**
- Modify: `AppStore/AppStoreSubmission.md`
- Modify: `AppStore/Metadata/zh-Hant.md`
- Modify: `AppStore/Metadata/en-US.md`
- Create: `AppStore/Verification/PublicSiteVerification.md`

**Interfaces:**
- Public repository is `phillon77/KnitNote`; Pages URLs match Task 3.
- External publication occurs only while authenticated to the user-approved GitHub account.

- [ ] **Step 1: Verify GitHub identity and repository destination**

Run `gh auth status` and `gh api user --jq .login`. Expected login: `phillon77`. If it differs, stop; do not publish to another account. Create or connect public repository `phillon77/KnitNote` without overwriting any unrelated remote history.

- [ ] **Step 2: Push the reviewed site workflow**

Push the current release branch/main only through the repository's normal integration flow. Enable GitHub Pages with GitHub Actions if not already enabled. Do not expose secrets or upload local backup/screenshot raw-data folders.

- [ ] **Step 3: Verify public HTTPS behavior**

Check all three URLs return 200 over HTTPS, render Chinese and English content, contain the mail link, load no third-party resource/cookie, and remain usable with JavaScript disabled. Record timestamp, commit SHA, response status, and checked URLs.

- [ ] **Step 4: Re-run metadata/site checks and commit evidence**

Run: `python3 AppStore/Verification/site_check.py AppStore/SupportSite && python3 AppStore/Verification/metadata_check.py AppStore/Metadata`.

Expected: both checks print `PASS`; the verification file records three HTTP 200 responses from `phillon77.github.io`.

```bash
git add AppStore/Verification/PublicSiteVerification.md AppStore/AppStoreSubmission.md AppStore/Metadata
git commit -m "docs: verify public KnitNote support URLs"
```

### Task 8: Create, inspect, and validate Release archives

**Files:**
- Create: `AppStore/ExportOptions-iOS.plist`
- Create: `AppStore/ExportOptions-macOS.plist`
- Create: `AppStore/Verification/ArchiveVerification.md`
- Modify: `AppStore/AppStoreSubmission.md`

**Interfaces:**
- iOS archive must embed/associate Watch and expose Watch screenshot information in App Store Connect.
- macOS archive must use the same version/build and contain no Watch embed.
- Archive artifacts live outside git under `/tmp/KnitNoteRelease/`.

- [ ] **Step 1: Run the complete clean release matrix**

Run package tests plus clean Release builds for iOS Simulator, generic iOS, macOS, Watch Simulator, and generic Watch. Any warning affecting signing, packaging, privacy, localization, icon, or resources is a blocker.

- [ ] **Step 2: Archive iOS/Watch and macOS**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/KnitNoteRelease/KnitNote-iOS.xcarchive clean archive
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Release -destination 'generic/platform=macOS' -archivePath /tmp/KnitNoteRelease/KnitNote-macOS.xcarchive clean archive
```

Expected: both archives succeed with distribution signing for team `9CFPAUL5N5`.

- [ ] **Step 3: Inspect archives and generate privacy reports**

Verify bundle IDs/version/build, embedded Watch product, Info strings, icons, privacy manifests at correct platform locations, backup UTI, no unexpected entitlement/framework, and no unapproved URL/domain strings. In Organizer generate privacy reports for both archives and compare to Task 2: no collected data/tracking, only audited required-reason APIs.

- [ ] **Step 4: Validate and upload builds without submitting review**

Use Organizer Validate App, then Distribute App → App Store Connect → Upload for iOS (with Watch) and macOS. Uploading is allowed here; do not attach/submit versions for review yet. Record Apple processing completion, build numbers, validation messages, and Watch association.

- [ ] **Step 5: Run release audit against archives and commit evidence**

Run: `AppStore/Verification/release_audit.sh --archives /tmp/KnitNoteRelease`.

Expected: `RELEASE AUDIT: PASS`.

```bash
git add AppStore/ExportOptions-iOS.plist AppStore/ExportOptions-macOS.plist AppStore/Verification/ArchiveVerification.md AppStore/AppStoreSubmission.md
git commit -m "build: verify KnitNote 1.0 release archives"
```

### Task 9: Populate App Store Connect and stop at the approval boundary

**Files:**
- Modify: `AppStore/AppStoreSubmission.md`
- Create: `AppStore/Verification/AppStoreConnectVerification.md`

**Interfaces:**
- App record: KnitNote, Apple ID `6793023054`.
- iOS listing includes iPhone/iPad/Watch screenshots; macOS listing includes Mac screenshots.
- Final state is fully populated but not submitted for App Review.

- [ ] **Step 1: Populate commercial/platform configuration**

Confirm paid agreement active; US$2.99, Taiwan NT$90, all 175 regions; Lifestyle primary and Productivity secondary when offered; manual release; iPhone/iPad/Watch/macOS availability; no IAP/subscription.

- [ ] **Step 2: Populate both localizations from repository files**

Copy exact Traditional Chinese and English name/subtitle/promotional text/description/keywords/URLs/release notes. Upload the matching screenshot sets and select the processed iOS/Watch and macOS builds. Do not edit copy only in App Store Connect; any correction first updates the repository source and passes metadata checks.

- [ ] **Step 3: Complete privacy, age rating, export compliance, and review information**

Declare no developer data collection and no tracking only after the archive privacy report matches. Answer encryption/export questions from the actual archive (Apple system encryption only unless audit says otherwise). Use `lzz.1999@icloud.com` as contact email and provide concise review notes describing local data, pattern import, backup package, and Watch sync. Supply a phone number only in App Store Connect, never commit it.

- [ ] **Step 4: Compare every field and capture evidence**

Side-by-side compare App Store Connect against metadata, pricing, screenshots, public URLs, build IDs, manual release, privacy answers, categories, and review information. Record completion timestamp and outstanding blockers. Never record private account/banking/tax details.

- [ ] **Step 5: Stop before submission and commit the handoff**

Do not click `Add for Review`, `Submit for Review`, or equivalent final controls. Run `AppStore/Verification/release_audit.sh --archives /tmp/KnitNoteRelease`, then:

```bash
git add AppStore/AppStoreSubmission.md AppStore/Verification/AppStoreConnectVerification.md
git commit -m "docs: prepare KnitNote listing for final approval"
```

Present the public URLs, selected build numbers, validation evidence, exact remaining button/action, and every outstanding field to the account holder for a separate explicit authorization.

Expected: both version pages are complete and validation-clean, their release setting is manual, and neither version has entered `Waiting for Review` or `In Review`.

### Task 10: Record the post-release price transition

**Files:**
- Modify after public launch: `AppStore/KnitNotePricing.md`
- Modify after public launch: `AppStore/AppStoreSubmission.md`

**Interfaces:**
- Consumes the actual App Store public release date, not approval date or upload date.
- Produces an App Store Connect scheduled base-price change to US$4.99 on calendar day 31.

- [ ] **Step 1: Record the actual public release date**

After manual release is live, record the App Store storefront date/time and Taiwan timezone date with a public product-page link.

- [ ] **Step 2: Calculate and independently verify the effective date**

Count the release date as promotional day 1. The release date plus 29 calendar days is promotional day 30; the following date is the US$4.99 effective date. Have a second calendar calculation confirm it before scheduling.

- [ ] **Step 3: Schedule and record the change**

In App Store Connect Pricing and Availability, add US$4.99 as the base-price schedule starting on the verified day-31 date; preserve availability in all 175 regions. Record the scheduled date and screenshot/reference in the pricing document.

- [ ] **Step 4: Verify storefront transition and commit**

On the effective date, verify the US storefront shows US$4.99 and record regional equivalents without assuming they remain unchanged.

Expected: the US public product page shows US$4.99 on the scheduled date and the pricing record contains the observed timestamp.

```bash
git add AppStore/KnitNotePricing.md AppStore/AppStoreSubmission.md
git commit -m "docs: record KnitNote standard price transition"
```

## Spec Coverage Checklist

- Commercial configuration, languages, platforms, manual release, and approval boundary: Tasks 1, 3, 9, 10.
- Accurate implemented-feature metadata and prohibited claims: Tasks 1 and 3.
- Privacy position, required-reason audit, manifest placement, and App Privacy answers: Tasks 2, 8, 9.
- Bilingual dependency-free support/privacy site and public HTTPS verification: Tasks 4 and 7.
- Synthetic data and watercolor story screenshot counts/content/safety: Tasks 5 and 6.
- Watch dependency, screenshots, packaging, archive validation: prerequisite Watch plan plus Tasks 6, 8, 9.
- All-platform release builds, smoke validation, signing, icons, localization, UTI, entitlements, frameworks: Tasks 1 and 8.
- Repository/App Store Connect parity and final evidence handoff: Task 9.
- Thirty-first-day US$4.99 transition: Task 10.
