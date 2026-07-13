# Knitting App Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver complete Traditional Chinese and English localization for the knitting app, including UI, onboarding, help, terminology, notifications, accessibility text, and AI-facing prompts.

**Architecture:** A single language-settings service selects the active locale and falls back to English. UI copy lives in Apple String Catalogs, long-form content and knitting terminology live in versioned JSON resources, and AI requests are assembled from typed localized templates without translating user-owned data.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest/Swift Testing, String Catalog (`.xcstrings`), JSON resources, SwiftData-compatible settings, Xcode multi-platform targets for iPhone, iPad, Mac, and Apple Watch.

## Global Constraints

- v1 locales are `zh-Hant` and `en`; English is the fallback language.
- Device language is the default; users may select system, Traditional Chinese, or English in-app.
- User-created project names, notes, and imported patterns are never automatically translated.
- UI text must not be hard-coded in views or business logic.
- AI output must preserve stitch counts, row counts, dimensions, units, and original abbreviations.
- AI output is labeled as a suggestion and asks users to verify counts, dimensions, and materials.
- New languages must be addable without changing core feature logic.
- Run each test command from the repository root.

---

## Planned File Map

- `KnitNote/App/KnitNoteApp.swift` — injects the active locale and localization services.
- `KnitNote/Localization/AppLanguage.swift` — supported language identifiers and fallback policy.
- `KnitNote/Localization/LanguageSettings.swift` — persists and resolves the selected language.
- `KnitNote/Localization/Localizable.xcstrings` — short UI, notification, and accessibility copy.
- `KnitNote/Localization/LocalizedContentStore.swift` — loads versioned onboarding/help JSON.
- `KnitNote/Localization/Content/en.json` and `zh-Hant.json` — long-form localized content.
- `KnitNote/Terminology/KnittingTerm.swift` — typed terminology records.
- `KnitNote/Terminology/TerminologyStore.swift` — locale-aware lookup and search.
- `KnitNote/Terminology/Terms/en.json` and `zh-Hant.json` — approved bilingual terms.
- `KnitNote/AI/AIPromptBuilder.swift` — typed, locale-aware AI prompt construction.
- `KnitNote/AI/Prompts/en.json` and `zh-Hant.json` — versioned AI templates.
- `KnitNote/Settings/LanguageSettingsView.swift` — user-facing language picker.
- `KnitNoteTests/Localization/*` — unit and completeness tests.
- `KnitNoteUITests/LocalizationFlowTests.swift` — language-switching and layout smoke tests.

### Task 1: Supported Languages and Resolution

**Files:**
- Create: `KnitNote/Localization/AppLanguage.swift`
- Create: `KnitNote/Localization/LanguageSettings.swift`
- Test: `KnitNoteTests/Localization/LanguageSettingsTests.swift`

**Interfaces:**
- Produces: `AppLanguage`, `LanguageSelection`, and `LanguageSettings.resolvedLanguage(systemLanguages:)`.

- [ ] **Step 1: Write failing resolution tests**

```swift
import Testing
@testable import KnitNote

@Suite struct LanguageSettingsTests {
    @Test func followsSupportedSystemLanguage() {
        let settings = LanguageSettings(selection: .system)
        #expect(settings.resolvedLanguage(systemLanguages: ["zh-Hant-TW"]) == .traditionalChinese)
    }

    @Test func unsupportedSystemLanguageFallsBackToEnglish() {
        let settings = LanguageSettings(selection: .system)
        #expect(settings.resolvedLanguage(systemLanguages: ["fr-FR"]) == .english)
    }

    @Test func explicitChoiceOverridesSystem() {
        let settings = LanguageSettings(selection: .traditionalChinese)
        #expect(settings.resolvedLanguage(systemLanguages: ["en-US"]) == .traditionalChinese)
    }
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteTests/LanguageSettingsTests`
Expected: FAIL because `LanguageSettings` is undefined.

- [ ] **Step 3: Implement the language types and resolver**

```swift
import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
}

enum LanguageSelection: String, CaseIterable, Codable, Sendable {
    case system, english, traditionalChinese
}

@Observable final class LanguageSettings {
    var selection: LanguageSelection

    init(selection: LanguageSelection = .system) { self.selection = selection }

    func resolvedLanguage(systemLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch selection {
        case .english: return .english
        case .traditionalChinese: return .traditionalChinese
        case .system:
            let first = systemLanguages.first ?? "en"
            return first.lowercased().hasPrefix("zh-hant") ? .traditionalChinese : .english
        }
    }
}
```

- [ ] **Step 4: Run the test and confirm PASS**

Run the command from Step 2. Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add KnitNote/Localization KnitNoteTests/Localization/LanguageSettingsTests.swift
git commit -m "feat: add app language resolution"
```

### Task 2: String Catalog and App-Wide Locale Injection

**Files:**
- Create: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `KnitNote/Settings/LanguageSettingsView.swift`
- Test: `KnitNoteTests/Localization/StringCatalogCompletenessTests.swift`

**Interfaces:**
- Consumes: `LanguageSettings.resolvedLanguage(systemLanguages:)`.
- Produces: localized UI keys and an environment locale used by all SwiftUI targets.

- [ ] **Step 1: Add a failing catalog completeness test**

```swift
import Foundation
import Testing

@Test func everyCatalogEntryHasEnglishAndTraditionalChinese() throws {
    let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings")!
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let strings = object["strings"] as! [String: Any]
    for (key, value) in strings {
        let entry = value as! [String: Any]
        let localizations = entry["localizations"] as! [String: Any]
        #expect(localizations["en"] != nil, "Missing en for \(key)")
        #expect(localizations["zh-Hant"] != nil, "Missing zh-Hant for \(key)")
    }
}
```

- [ ] **Step 2: Run and confirm the missing-resource failure**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteTests/StringCatalogCompletenessTests`
Expected: FAIL because the catalog is absent.

- [ ] **Step 3: Create the catalog and migrate all visible copy**

Create catalog keys grouped by feature, including `nav.projects`, `project.completeRow`, `project.undo`, `pattern.open`, `settings.language`, notification copy, errors, empty states, and accessibility labels. Add both `en` and `zh-Hant` values, including plural variations for row and stitch counts. Replace every literal visible string in SwiftUI views with `Text("key")`, `String(localized: "key")`, or typed format keys.

- [ ] **Step 4: Inject the selected locale and add the picker**

```swift
@main struct KnitNoteApp: App {
    @State private var languageSettings = LanguageSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(languageSettings)
                .environment(\.locale, Locale(identifier: languageSettings.resolvedLanguage().rawValue))
        }
    }
}
```

Use a picker bound to `languageSettings.selection`, with labels localized through the catalog. Persist the raw selection in the existing settings store; if none exists, use `.system`.

- [ ] **Step 5: Run completeness and app tests**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS'`
Expected: all tests pass and the completeness test reports no missing locale.

- [ ] **Step 6: Commit**

```bash
git add KnitNote KnitNoteTests/Localization
git commit -m "feat: localize app interface in English and Traditional Chinese"
```

### Task 3: Versioned Onboarding and Help Content

**Files:**
- Create: `KnitNote/Localization/LocalizedContentStore.swift`
- Create: `KnitNote/Localization/Content/en.json`
- Create: `KnitNote/Localization/Content/zh-Hant.json`
- Test: `KnitNoteTests/Localization/LocalizedContentStoreTests.swift`

**Interfaces:**
- Consumes: `AppLanguage`.
- Produces: `LocalizedContentStore.content(id:language:) throws -> LocalizedContent`.

- [ ] **Step 1: Write failing loading and fallback tests**

```swift
@Test func loadsLocalizedOnboarding() throws {
    let store = try LocalizedContentStore(bundle: .module)
    let item = try store.content(id: "onboarding.quickCounter", language: .traditionalChinese)
    #expect(item.title == "三秒記錄一排")
}

@Test func fallsBackToEnglishWhenLocalizedItemIsMissing() throws {
    let store = try LocalizedContentStore(bundle: .module)
    let item = try store.content(id: "help.aiVerification", language: .traditionalChinese)
    #expect(item.language == .english)
}
```

- [ ] **Step 2: Run and confirm undefined-type failure**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteTests/LocalizedContentStoreTests`
Expected: FAIL because the store is undefined.

- [ ] **Step 3: Implement decoding, version checks, and fallback**

Define `LocalizedContent` with `id`, `language`, `minimumAppVersion`, `title`, and `body`. Load language JSON once, reject duplicate IDs, return the requested language when present, otherwise return English, and throw `ContentError.missingID` only if English is also absent.

- [ ] **Step 4: Populate both resource files and connect onboarding/help views**

Include all onboarding screens, feature tips, empty-state help, troubleshooting, privacy, and AI verification content. Set `minimumAppVersion` to `1.0.0` for v1 entries.

- [ ] **Step 5: Run all tests and commit**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS'`
Expected: all tests pass.

```bash
git add KnitNote/Localization KnitNoteTests/Localization
git commit -m "feat: add localized onboarding and help content"
```

### Task 4: Bilingual Knitting Terminology

**Files:**
- Create: `KnitNote/Terminology/KnittingTerm.swift`
- Create: `KnitNote/Terminology/TerminologyStore.swift`
- Create: `KnitNote/Terminology/Terms/en.json`
- Create: `KnitNote/Terminology/Terms/zh-Hant.json`
- Test: `KnitNoteTests/Terminology/TerminologyStoreTests.swift`

**Interfaces:**
- Produces: `TerminologyStore.term(id:language:)`, `search(_:language:)`, and `counterpart(id:language:)`.

- [ ] **Step 1: Write tests for lookup, aliases, and regional variants**

Test that `k2tog` resolves to `兩針併一針下針`, that searching `併針` returns `k2tog`, and that US `single crochet` maps to UK `double crochet` without changing the stable term ID.

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteTests/TerminologyStoreTests`
Expected: FAIL because terminology types are undefined.

- [ ] **Step 3: Implement typed terminology records and normalized search**

Define fields for stable ID, craft, localized name, abbreviations, aliases, explanation, instructions, region, and counterpart IDs. Normalize search with case/diacritic folding while always displaying approved source text.

- [ ] **Step 4: Add the initial reviewed term set**

Cover cast-on/bind-off, knit/purl, common increases/decreases, gauge, yarn weight/material, chart directions, and the common US/UK crochet differences. Every stable ID must exist in both resource files.

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS'`
Expected: all tests pass.

```bash
git add KnitNote/Terminology KnitNoteTests/Terminology
git commit -m "feat: add bilingual knitting terminology"
```

### Task 5: Localized AI Prompt Assembly

**Files:**
- Create: `KnitNote/AI/AIPromptBuilder.swift`
- Create: `KnitNote/AI/Prompts/en.json`
- Create: `KnitNote/AI/Prompts/zh-Hant.json`
- Test: `KnitNoteTests/AI/AIPromptBuilderTests.swift`

**Interfaces:**
- Consumes: `AppLanguage` and approved `KnittingTerm` records.
- Produces: `AIPromptBuilder.build(request:) throws -> AIPrompt`.

- [ ] **Step 1: Write invariant-preservation tests**

Build a Traditional Chinese explanation request containing `K2tog, 48 sts, 10 cm`; assert the prompt requests Traditional Chinese, includes the approved bilingual term, preserves all three source tokens, and contains the localized verification notice.

- [ ] **Step 2: Run and confirm failure**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS' -only-testing:KnitNoteTests/AIPromptBuilderTests`
Expected: FAIL because `AIPromptBuilder` is undefined.

- [ ] **Step 3: Implement typed request and template assembly**

Define `AIRequest` with feature, response language, source text, regional terminology preference, immutable tokens, and relevant term IDs. Define `AIPrompt` with system, user, and localized disclosure strings. Reject templates with missing placeholders or missing English fallback.

- [ ] **Step 4: Connect AI screens to the builder**

Remove embedded prompt prose from views and networking code. Display the returned disclosure beside every generated result; never overwrite user notes or imported patterns with generated text.

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS'`
Expected: all tests pass.

```bash
git add KnitNote/AI KnitNoteTests/AI
git commit -m "feat: localize AI knitting prompts"
```

### Task 6: Cross-Platform Localization QA Gate

**Files:**
- Create: `KnitNoteUITests/LocalizationFlowTests.swift`
- Create: `KnitNoteTests/Localization/ResourceIntegrityTests.swift`
- Modify: `.github/workflows/test.yml`
- Create: `docs/localization-release-checklist.md`

**Interfaces:**
- Consumes: all localization resources and services.
- Produces: a release gate for completeness, device layout, accessibility, and language switching.

- [ ] **Step 1: Add resource-integrity tests**

Assert no duplicate content or term IDs, every English term has a `zh-Hant` record, every AI template has the same placeholder set in both languages, and no rendered value equals its localization key.

- [ ] **Step 2: Add UI smoke tests**

Launch with `-AppleLanguages (en)` and `(zh-Hant)`, create a project, increment and undo a row, open a pattern, search terminology, and change language in settings. Assert user-entered project names remain unchanged after switching language.

- [ ] **Step 3: Run the platform matrix**

Run macOS unit tests plus iPhone, iPad, and Watch simulator schemes available in the project. Expected: all tests pass in both languages with no missing-resource diagnostics.

- [ ] **Step 4: Perform visual and accessibility review**

Check both languages at the largest supported Dynamic Type size on the smallest supported iPhone, iPad split view, Mac window minimum size, and Apple Watch. Record pass/fail for clipping, overlap, VoiceOver labels, notification copy, widgets, offline fallback, and date/measurement formatting.

- [ ] **Step 5: Add the release checklist and CI gate**

The checklist must require translator review, knitting-domain review, App Store copy/screenshots, catalog completeness, terminology parity, AI prompt parity, and platform screenshots. CI must run unit/resource-integrity tests on every pull request.

- [ ] **Step 6: Final verification and commit**

Run: `xcodebuild test -scheme KnitNote -destination 'platform=macOS'`
Expected: all localization, terminology, AI, and resource-integrity tests pass.

```bash
git add KnitNoteUITests KnitNoteTests .github/workflows/test.yml docs/localization-release-checklist.md
git commit -m "test: add localization release gate"
```

## Implementation Entry Condition

Execution begins only after the actual KnitNote Xcode repository is available. Before Task 1, map these planned paths to the repository's existing target names and folder conventions without changing the interfaces or acceptance criteria above.
