# Dutch Localization and Project Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Dutch as KnitNote’s thirteenth complete shipping language and ensure the large Projects heading follows the selected app language on every platform where it appears.

**Architecture:** Extend the existing `AppLanguage`/`LanguageSelection` runtime-locale architecture with `nl`, then require Dutch coverage in every Apple String Catalog and release contract. Resolve the Projects navigation title through `LocaleAwareText` at render time so it follows the in-app locale rather than process-language behavior, while leaving user-created names verbatim.

**Tech Stack:** Swift 6, SwiftUI, Apple String Catalogs, XcodeGen, Swift Testing, Python metadata validation, Bash release audit.

## Global Constraints

- Dutch locale identifiers are `nl` in runtime/catalog/project settings and `nl-NL` for App Store metadata.
- The shipping runtime set becomes exactly thirteen locales: `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`, `nb`, `sv`, `fi`, `da`, `ko`, `el`, `nl`.
- Main app, Watch, Share Extension, InfoPlist, accessibility, help, and prepared store metadata receive Dutch coverage.
- User-created/imported project names, counter names, reminder messages, pattern names/content, notes, yarn data, and YouTube data are never translated.
- Dutch terminology is human-reviewed and source-grounded; machine-shaped placeholders are rejected.
- The Projects large title and tab use the same semantic key but user project rows remain verbatim.
- Do not change marketing version/build, archive, sign, upload, edit live App Store state, submit, merge, or push in this plan.

---

### Task 1: Register Dutch in runtime configuration

**Files:**
- Modify: `Sources/KnitNoteCore/Localization/SupportedLocalization.swift`
- Modify: `Sources/KnitNoteCore/Localization/AppLanguage.swift`
- Modify: `Sources/KnitNoteCore/Localization/LanguageSettings.swift`
- Modify: `Tests/KnitNoteCoreTests/LanguageSettingsTests.swift`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseCandidateIdentityTests.swift`

**Interfaces:**
- Produces: `AppLanguage.dutch`, `LanguageSelection.dutch`, and `SupportedLocalization.v150Identifiers`.
- Consumes: existing `LanguageSelectionProjection` without changing stored-key format.

- [ ] **Step 1: Write failing runtime-language tests**

```swift
@Test func version150LocalizationContractAddsDutchLast() {
    #expect(SupportedLocalization.v150Identifiers == [
        "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
        "nb", "sv", "fi", "da", "ko", "el", "nl",
    ])
}

@Test func dutchSystemLanguagesResolveToDutch() {
    #expect(LanguageSettings().resolvedLanguage(systemLanguages: ["nl-NL"]) == .dutch)
    #expect(LanguageSettings().resolvedLanguage(systemLanguages: ["nl-BE"]) == .dutch)
}

@Test func explicitDutchSelectionUsesDutchLocale() {
    let settings = LanguageSettings(selection: .dutch)
    #expect(settings.resolvedLanguage(systemLanguages: ["de-DE"]) == .dutch)
    #expect(settings.resolvedLocale(regionLocale: Locale(identifier: "nl_NL")).language.languageCode?.identifier == "nl")
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter LanguageSettingsTests
swift test --disable-sandbox --filter StringCatalogLocalizationContractTests
```

Expected: FAIL because Dutch cases and `v150Identifiers` do not exist.

- [ ] **Step 3: Add the exact runtime cases and selection key**

```swift
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case german = "de"
    case french = "fr"
    case japanese = "ja"
    case norwegianBokmal = "nb"
    case swedish = "sv"
    case finnish = "fi"
    case danish = "da"
    case korean = "ko"
    case greek = "el"
    case dutch = "nl"
}

public enum LanguageSelection: String, CaseIterable, Codable, Sendable {
    case system
    case traditionalChinese
    case simplifiedChinese
    case english
    case german
    case french
    case japanese
    case norwegianBokmal
    case swedish
    case finnish
    case danish
    case korean
    case greek
    case dutch
}
```

Map `.dutch` to `AppLanguage.dutch`, map its picker key to `language.dutch`, and map system language code `nl` to `.dutch`. Define:

```swift
public static let v150Identifiers = v141Identifiers + ["nl"]
```

- [ ] **Step 4: Keep the shipping contract at the current complete catalog set**

Do not add `nl` to main/Watch/Share `CFBundleLocalizations`, generated Info plists, or PBX `knownRegions` in this task. XcodeGen derives known regions from real localized resources; fake resources and direct generated-project edits are prohibited. Keep the current twelve-locale shipping contract fail-closed while Task 1 registers the runtime language.

The next implementation task combines the original Tasks 2 and 3 with the locale-count/release-audit transition. It must atomically add complete real Dutch main, InfoPlist, Watch, and Share catalogs; add `nl` to project/plist declarations; regenerate PBX known regions; and update release-audit contracts and fixtures. No intermediate red release-audit state is allowed.

Regenerate only from the checked-in specification:

```bash
xcodegen generate
git diff --check
```

Keep `ReleaseCandidateIdentityTests` exact for the current twelve shipping locales and catalog-derived known regions. Regenerate a second time and compare the generated project hash to prove no drift.

- [ ] **Step 5: Verify and commit**

```bash
swift test --disable-sandbox --filter LanguageSettingsTests
swift test --disable-sandbox --filter ReleaseCandidateIdentityTests
git add Sources/KnitNoteCore/Localization/SupportedLocalization.swift Sources/KnitNoteCore/Localization/AppLanguage.swift Sources/KnitNoteCore/Localization/LanguageSettings.swift Tests/KnitNoteCoreTests/LanguageSettingsTests.swift Tests/KnitNoteCoreTests/LanguagePickerContractTests.swift Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/ReleaseCandidateIdentityTests.swift
git commit -m "feat: register Dutch as a shipping language"
```

Expected: focused suites PASS and generated project is stable.

---

### Task 2: Dutch catalogs and atomic shipping transition

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNote/Localization/InfoPlist.xcstrings`
- Modify: `KnitNoteWatch/Localizable.xcstrings`
- Modify: `KnitNoteShare/Localizable.xcstrings`
- Modify: `project.yml`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`
- Modify: `AppStore/Verification/release_audit.sh`
- Modify: `AppStore/Localization/KnittingTerminology.csv`
- Modify: `AppStore/Localization/README.md`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/KnittingTerminologyContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ShareExtensionLocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseAuditLocalizationTests.swift`
- Modify: `Tests/KnitNoteCoreTests/ReleaseCandidateIdentityTests.swift`

**Interfaces:**
- Consumes: Task 1 `SupportedLocalization.v150Identifiers` and `language.dutch`.
- Produces: reviewed Dutch values for every shipping catalog plus one atomic thirteen-locale project, PBX, and release-audit transition.

**Atomic transition:** This task absorbs the original Task 3 and the locale-count/release-audit transition formerly assigned to Task 6. Do not declare `nl` in any shipping plist or audit contract until every main, InfoPlist, Watch, and Share Dutch catalog is complete. Then update all source/generated product declarations, PBX known regions, audit contracts, and fixtures in the same change.

- [ ] **Step 0: Complete and verify the atomic transition in one task**

First complete the original Task 2 main/InfoPlist catalog and terminology work and the original Task 3 Watch/Share catalog work. Before committing, add `nl` to all three `CFBundleLocalizations` declarations in `project.yml`, regenerate the Info plists and PBX project, and update `release_audit.sh`, `ReleaseAuditLocalizationTests`, and `ReleaseCandidateIdentityTests` to the exact thirteen-locale contract. Run the release-audit suite and the full Swift suite green in the same task; do not commit a source, catalog, configuration, generated-project, or audit-only intermediate state.

- [ ] **Step 1: Change catalog contracts to require Dutch and witness RED**

For the production main and InfoPlist catalog assertions, replace the v1.4.1 set with `SupportedLocalization.v150Identifiers`. Add an explicit semantic-key test:

```swift
@Test func DutchLanguagePickerAndProjectNavigationHaveReviewedCopy() throws {
    let expected = [
        "language.dutch": "Nederlands",
        "nav.projects": "Projecten",
    ]
    try assertExactTranslations(
        catalog: "KnitNote/Localization/Localizable.xcstrings",
        language: "nl",
        expected: expected
    )
}
```

Run:

```bash
swift test --disable-sandbox --filter StringCatalogLocalizationContractTests
```

Expected: FAIL for missing `nl` values.

- [ ] **Step 2: Extend the terminology glossary contract**

Add a `nl` column to `KnittingTerminology.csv`; require it after Greek in the header and require a non-empty reviewed value or approved inflection set for every glossary row. The following core terms are fixed unless native review documents a better domain term:

```text
project = project
pattern = patroon
yarn = garen
counter = toerenteller
row = toer
stitch = steek
needle = breinaald
crochet hook = haaknaald
```

Run:

```bash
swift test --disable-sandbox --filter KnittingTerminologyContractTests
```

Expected before CSV update: FAIL for missing Dutch column/values.

- [ ] **Step 3: Add complete Dutch catalog values**

Add a non-empty, non-stale `nl` `stringUnit` or variation for every source key in `Localizable.xcstrings` and `InfoPlist.xcstrings`. Preserve numbered format argument types and plural categories. Translate UI/system copy only; keep examples that represent user-authored content explicitly marked as examples rather than runtime rewriting.

For reminder copy from the counter-reminder plan, use reviewed equivalents based on these meanings:

```text
Reached row %lld = Toer %lld bereikt
Complete this reminder = Deze herinnering voltooien
Stop reminder = Herinnering stoppen
%lld reminders crossed = %lld herinneringen gepasseerd
```

- [ ] **Step 4: Run behavior and terminology checks**

```bash
swift test --disable-sandbox --filter StringCatalogLocalizationContractTests
swift test --disable-sandbox --filter KnittingTerminologyContractTests
swift test --disable-sandbox --filter RuntimeLocalizationBehaviorTests
```

Expected: all focused suites PASS; format/plural tokens match English source intent.

- [ ] **Step 5: Commit**

```bash
git add KnitNote/Localization/Localizable.xcstrings KnitNote/Localization/InfoPlist.xcstrings AppStore/Localization/KnittingTerminology.csv AppStore/Localization/README.md Tests/KnitNoteCoreTests/LocalizationContractTests.swift Tests/KnitNoteCoreTests/KnittingTerminologyContractTests.swift Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift
git commit -m "feat: add reviewed Dutch app localization"
```

---

### Task 3: Superseded by Task 2 atomic transition

Do not execute this task independently. Its catalog work and verification are part of Task 2 so the release-audit contract never has an intentionally red intermediate state.

**Files:**
- Modify: `KnitNoteWatch/Localizable.xcstrings`
- Modify: `KnitNoteShare/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/ShareExtensionLocalizationContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift`

**Interfaces:**
- Consumes: Task 1 locale set and Task 2 terminology.
- Produces: complete Dutch Watch and Share catalogs.

- [ ] **Step 1: Write failing completeness and exact-copy tests**

```swift
@Test func watchAndShareCatalogsAreCompleteForVersion150Languages() throws {
    for path in ["KnitNoteWatch/Localizable.xcstrings", "KnitNoteShare/Localizable.xcstrings"] {
        try assertCompleteCatalog(
            at: patternLibraryRepositoryURL(path),
            requiredLanguages: SupportedLocalization.v150Identifiers
        )
    }
}

@Test func DutchWatchAndShareCoreActionsUseReviewedCopy() throws {
    try assertExactTranslations(
        catalog: "KnitNoteWatch/Localizable.xcstrings",
        language: "nl",
        expected: [
            "watch.counter.decrement": "Verminder met één",
            "watch.counter.reset": "Zet op nul",
            "watch.counter.cancel": "Annuleer",
        ]
    )
    try assertExactTranslations(
        catalog: "KnitNoteShare/Localizable.xcstrings",
        language: "nl",
        expected: [
            "share.title": "Voeg toe aan KnitNote",
            "share.cancel": "Annuleer",
            "share.close": "Sluit",
        ]
    )
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter ShareExtensionLocalizationContractTests
swift test --disable-sandbox --filter WatchPackagingContractTests
```

- [ ] **Step 3: Add all Dutch Watch and Share values**

Translate every key and variation using compact Watch wording and file-import semantics for Share. Preserve custom project/counter/reminder text as verbatim data. Keep all Watch accessibility labels short but unambiguous.

- [ ] **Step 4: Verify and commit**

```bash
swift test --disable-sandbox --filter ShareExtensionLocalizationContractTests
swift test --disable-sandbox --filter WatchPackagingContractTests
swift test --disable-sandbox --filter WatchCounterViewContractTests
git add KnitNoteWatch/Localizable.xcstrings KnitNoteShare/Localizable.xcstrings Tests/KnitNoteCoreTests/ShareExtensionLocalizationContractTests.swift Tests/KnitNoteCoreTests/WatchPackagingContractTests.swift Tests/KnitNoteCoreTests/WatchCounterViewContractTests.swift
git commit -m "feat: localize Watch and Share in Dutch"
```

---

### Task 4: Fix the large Projects title under runtime language switching

**Files:**
- Modify: `KnitNote/Projects/ProjectsView.swift`
- Modify: `Tests/KnitNoteCoreTests/RuntimeLocalizationSourceContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift`
- Modify: `Tests/KnitNoteCoreTests/StoreScreenshotModeContractTests.swift`

**Interfaces:**
- Consumes: existing `LocaleAwareText.string(_:locale:)` and `nav.projects`.
- Produces: a runtime-locale-resolved navigation title while project row names stay unchanged.

- [ ] **Step 1: Write a failing source and behavior contract**

```swift
@Test func projectsLargeTitleUsesTheRuntimeLocaleBoundary() throws {
    let source = try repositorySource("KnitNote/Projects/ProjectsView.swift")
    #expect(source.contains("@Environment(\\.locale) private var locale"))
    #expect(source.contains("LocaleAwareText.string(\"nav.projects\", locale: locale)"))
    #expect(!source.contains(".navigationTitle(\"nav.projects\")"))
}

@Test func GermanProjectsTitleResolvesWithoutChangingProjectNames() {
    let title = LocaleAwareText.string("nav.projects", locale: Locale(identifier: "de"))
    #expect(title == "Projekte")
    let userName = "作品 test 42"
    #expect(userName == "作品 test 42")
}
```

- [ ] **Step 2: Run RED**

```bash
swift test --disable-sandbox --filter RuntimeLocalizationSourceContractTests
swift test --disable-sandbox --filter RuntimeLocalizationBehaviorTests
```

Expected: FAIL because `ProjectsView` currently passes the semantic key directly to `navigationTitle`.

- [ ] **Step 3: Resolve the title from the active SwiftUI locale**

```swift
@Environment(\.locale) private var locale

// existing navigation stack
.navigationTitle(LocaleAwareText.string("nav.projects", locale: locale))
```

Do not apply localization to `Text(project.name)`, accessibility labels containing `project.name`, or store records.

- [ ] **Step 4: Verify all supported locales and commit**

Add a table-driven test that switches through `SupportedLocalization.v150Identifiers`, asserts the title is not the semantic key, and asserts the German/Dutch/Traditional-Chinese exact values. Then:

```bash
swift test --disable-sandbox --filter RuntimeLocalizationSourceContractTests
swift test --disable-sandbox --filter RuntimeLocalizationBehaviorTests
swift test --disable-sandbox --filter StoreScreenshotModeContractTests
git add KnitNote/Projects/ProjectsView.swift Tests/KnitNoteCoreTests/RuntimeLocalizationSourceContractTests.swift Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift Tests/KnitNoteCoreTests/StoreScreenshotModeContractTests.swift
git commit -m "fix: localize the Projects large title"
```

---

### Task 5: Dutch App Store metadata and forbidden-claim validation

**Files:**
- Create: `AppStore/Metadata/nl-NL.md`
- Modify: `AppStore/Verification/metadata_check.py`
- Modify: `AppStore/Verification/metadata_check_test.py`
- Modify: `AppStore/Localization/README.md`

**Interfaces:**
- Produces: validated repository-owned Dutch metadata source.
- Consumes: existing metadata field limits and release-claim policy.

- [ ] **Step 1: Add failing locale-set and policy tests**

```python
def test_expected_locales_include_dutch_last():
    assert EXPECTED_LOCALES[-1] == "nl-NL.md"
    assert len(EXPECTED_LOCALES) == 13

def test_dutch_forbidden_claims_are_rejected(tmp_path):
    metadata = valid_metadata().replace(
        "Promotional text: Houd je breiprojecten overzichtelijk.",
        "Promotional text: Gratis proefperiode met cloud synchronisatie",
    )
    assert_metadata_rejected(metadata, concepts={"trial/free", "cloud sync"})
```

Add Dutch patterns for at least AI translation, cloud sync/remote service, automatic stitch recognition, subscription, trial/free, price, purchase, deleted-project recovery, social network, marketplace, and Share system-only language claims.

Bind the Dutch concepts to these reviewed regex term families, using the same word-boundary and bounded-distance structure as the existing languages:

```text
AI translation: ai-vertaling | vertaling met kunstmatige intelligentie
cloud sync: cloudsynchronisatie | synchronisatie met de cloud
remote service: externe dienst | service op afstand
automatic stitch recognition: automatische steekherkenning
subscription: abonnement | abonnementsdienst
trial/free: gratis | gratis proefperiode | proefversie
price: prijs | kosten
purchase: aankoop | kopen
deleted-project recovery: verwijderd project + herstellen/terugzetten
social network: sociaal netwerk | sociale netwerksite
marketplace: marktplaats
Share system-only language: deel-extensie/deelscherm + systeemtaal
```

- [ ] **Step 2: Run RED**

```bash
python3 -m unittest AppStore/Verification/metadata_check_test.py
```

- [ ] **Step 3: Create complete Dutch metadata**

Use the same required fields and verified URLs as the other locale files. Keep the Name at most 30 characters, Subtitle at most 30, Promotional text at most 170, Keywords at most 100, Description and What’s New at most 4,000, and each keyword longer than two characters.

The What’s New section may describe only implemented and accepted 1.5 behavior. It must mention improved counter use, reminders, Watch coordination, Dutch support, and the Projects-title fix only after the corresponding source tasks pass. It must not claim background notifications, cloud sync, translation of user content, subscriptions, a free trial, or publication.

- [ ] **Step 4: Run metadata verification and commit**

```bash
python3 AppStore/Verification/metadata_check.py
python3 -m unittest AppStore/Verification/metadata_check_test.py
git add AppStore/Metadata/nl-NL.md AppStore/Verification/metadata_check.py AppStore/Verification/metadata_check_test.py AppStore/Localization/README.md
git commit -m "docs: prepare Dutch App Store metadata"
```

Expected: checker and tests PASS. This commit prepares source metadata only; it does not edit App Store Connect.

---

### Task 6: Final thirteen-locale validation, builds, and linguistic acceptance

**Files:**
- Create: `AppStore/Verification/Localization150Verification.md`

**Interfaces:**
- Consumes: Tasks 1–5 and the counter-reminder plan’s final catalog key domain.
- Produces: final verification evidence for the atomic thirteen-locale source/build audit completed in Task 2.

**Sequencing:** The release-locale transition and its RED/GREEN audit fixtures moved to Task 2. Task 6 verifies that completed transition; it does not introduce the first thirteen-locale shipping declaration.

The old release-contract mutation steps are superseded by Task 2. Retain the final build, packaging, linguistic, and physical acceptance work only after Task 2 has already made every automated locale contract green.

- [ ] **Step 1: Verify Task 2's already-green thirteen-locale contracts**

Do not modify audit fixtures or locale declarations here. Confirm Task 2 already covers exact known regions, source/generated/built `CFBundleLocalizations`, and packaged `.lproj` sets for all thirteen locales.

- [ ] **Step 2: Run the existing audit GREEN**

```bash
swift test --disable-sandbox --filter ReleaseAuditLocalizationTests
```

Expected: PASS; a failure is a blocker to final validation, not permission to split the release transition.

- [ ] **Step 4: Run focused and full verification**

```bash
swift test --disable-sandbox --filter ReleaseAuditLocalizationTests
swift test --disable-sandbox --filter ReleaseCandidateIdentityTests
swift test --disable-sandbox
AppStore/Verification/release_audit.sh --static-only
```

Expected: every command exits zero; record exact test/suite counts.

- [ ] **Step 5: Build all shipping products and inspect locale packaging**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNoteWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -target KnitNoteShare -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Inspect each built product for exactly thirteen declared locales and a Dutch `.lproj`; record paths and commands. Do not infer linguistic quality from packaging.

- [ ] **Step 6: Obtain linguistic and physical UI acceptance**

Record native or qualified Dutch review for knitting terminology, reminder copy, compact Watch copy, permission strings, and metadata. On iPhone, iPad, Watch, and Mac select Dutch and verify navigation, reminder formatting/plurals, Share UI, VoiceOver, Dynamic Type, and no translation of user-created names. Also switch to German and confirm the large heading is `Projekte`, then to Dutch and confirm `Projecten`.

- [ ] **Step 7: Commit the evidence record**

```bash
git add AppStore/Verification/Localization150Verification.md
git commit -m "test: verify Dutch localization across products"
```

Leave any unperformed linguistic or physical assertion explicitly pending. Do not archive, upload, submit, merge, or push.
