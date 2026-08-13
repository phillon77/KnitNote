# Live Yarn Library Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Yarn Library navigation title re-resolve immediately from KnitNote's currently selected App locale instead of retaining the language used when the view first appeared.

**Architecture:** Keep `YarnLibraryView` stateless with respect to localized copy. Resolve `yarn.library.title` from the existing environment `locale` through `LocaleAwareText.string` on every SwiftUI body evaluation, matching the already accepted Projects-title pattern.

**Tech Stack:** Swift 6, SwiftUI, String Catalogs, Swift Testing, XcodeGen, Xcode 26.

## Global Constraints

- Do not translate or modify yarn names, brands, colors, notes, photos, project links, or any other user-created content.
- Do not add a second locale source or cache a resolved title in `@State`.
- Preserve the existing iPhone, iPad, and macOS Yarn Library layout and behavior.
- Do not change version, Build, signing, archive, App Store metadata, or release scripts.
- Automated tests and successful builds do not replace physical language-switch acceptance.

---

### Task 1: Bind the Yarn Library title to the selected App locale

**Files:**
- Modify: `KnitNote/Yarn/YarnLibraryView.swift`
- Modify: `Tests/KnitNoteCoreTests/RuntimeLocalizationSourceContractTests.swift`
- Modify: `Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift`
- Test: `Tests/KnitNoteCoreTests/YarnViewContractTests.swift`

**Interfaces:**
- Consumes: `@Environment(\.locale) private var locale` already declared by `YarnLibraryView`.
- Consumes: `LocaleAwareText.string(_:locale:bundle:) -> String` from the existing localization layer.
- Produces: `.navigationTitle(LocaleAwareText.string("yarn.library.title", locale: locale))` as the only Yarn Library title expression.

- [ ] **Step 1: Add a failing source contract for the title expression**

Add this test to `RuntimeLocalizationSourceContractTests`:

```swift
@Test func yarnLibraryTitleIsResolvedFromTheSelectedAppLocale() throws {
    let source = try sourceText("KnitNote/Yarn/YarnLibraryView.swift")

    #expect(source.contains("@Environment(\\.locale) private var locale"))
    #expect(source.contains(
        ".navigationTitle(LocaleAwareText.string(\"yarn.library.title\", locale: locale))"
    ))
    #expect(!source.contains(".navigationTitle(\"yarn.library.title\")"))
}
```

- [ ] **Step 2: Add a failing behavior contract for all 13 shipping locales**

In `RuntimeLocalizationBehaviorTests`, extract the catalog helper so it accepts a key, then add:

```swift
@Test func yarnLibraryTitleResolvesInEveryVersion150LocaleWithoutChangingYarnNames() throws {
    let titles = try navigationTitlesFromShippingCatalog(key: "yarn.library.title")
    let bundle = try localizedFixtureBundle(
        additionalStringsByLanguage: titles.mapValues { ["yarn.library.title": $0] }
    )

    for language in SupportedLocalization.v150Identifiers {
        #expect(
            LocaleAwareText.string(
                "yarn.library.title",
                locale: Locale(identifier: language),
                bundle: bundle
            ) != "yarn.library.title"
        )
    }

    #expect(LocaleAwareText.string(
        "yarn.library.title",
        locale: Locale(identifier: "en"),
        bundle: bundle
    ) == "Yarn Library")
    #expect(LocaleAwareText.string(
        "yarn.library.title",
        locale: Locale(identifier: "ja"),
        bundle: bundle
    ) == "毛糸ライブラリ")
    #expect(LocaleAwareText.string(
        "yarn.library.title",
        locale: Locale(identifier: "zh-Hant"),
        bundle: bundle
    ) == "毛線庫")

    let userYarnName = "Jaipur peace silk"
    #expect(userYarnName == "Jaipur peace silk")
}
```

Rename `projectsNavigationTitlesFromShippingCatalog()` to this reusable helper and update its existing call site:

```swift
private func navigationTitlesFromShippingCatalog(key: String) throws -> [String: String] {
    let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appending(
        path: "KnitNote/Localization/Localizable.xcstrings"
    ))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    return try Dictionary(uniqueKeysWithValues: SupportedLocalization.v150Identifiers.map { language in
        let translation = try #require(localizations[language] as? [String: Any])
        let unit = try #require(translation["stringUnit"] as? [String: Any])
        return (language, try #require(unit["value"] as? String))
    })
}
```

- [ ] **Step 3: Run the two contracts and witness RED**

Run:

```bash
swift test --disable-sandbox --filter 'RuntimeLocalizationSourceContractTests|RuntimeLocalizationBehaviorTests'
```

Expected: the new source contract fails because the view still contains `.navigationTitle("yarn.library.title")`; the existing localization behavior tests remain green.

- [ ] **Step 4: Implement the minimal title fix**

Replace the Yarn Library title expression with:

```swift
.navigationTitle(
    LocaleAwareText.string("yarn.library.title", locale: locale)
)
```

Do not add `@State`, `.id(locale.identifier)`, manual refresh notifications, or a second locale environment.

- [ ] **Step 5: Run focused GREEN verification**

Run:

```bash
swift test --disable-sandbox --filter 'RuntimeLocalizationSourceContractTests|RuntimeLocalizationBehaviorTests|YarnViewContractTests|StringCatalogLocalizationContractTests'
```

Expected: all selected tests pass, including the existing Projects-title contract and all 13 Yarn-title catalog values.

- [ ] **Step 6: Build iOS and macOS without signing**

Run:

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteYarnTitle-iOS CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteYarnTitle-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: both commands end with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Verify scope and commit**

Run:

```bash
git diff --check
git diff -- KnitNote/Yarn/YarnLibraryView.swift Tests/KnitNoteCoreTests/RuntimeLocalizationSourceContractTests.swift Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift
git add KnitNote/Yarn/YarnLibraryView.swift Tests/KnitNoteCoreTests/RuntimeLocalizationSourceContractTests.swift Tests/KnitNoteCoreTests/RuntimeLocalizationBehaviorTests.swift
git commit -m "fix: refresh yarn library title language"
```

Expected: the commit contains only the Yarn title expression and its localization contracts.

- [ ] **Step 8: Perform physical acceptance only on an exact built commit**

Before installing, record these command results in the task report:

```bash
git rev-parse HEAD
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /tmp/KnitNoteYarnTitle-iOS/Build/Products/Debug-iphonesimulator/KnitNote.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /tmp/KnitNoteYarnTitle-iOS/Build/Products/Debug-iphonesimulator/KnitNote.app/Info.plist
```

Then test this exact binary on iPhone, iPad, and Mac:

1. Switch zh-Hant -> en -> ja without terminating KnitNote.
2. Open the Yarn Library after each switch and require `毛線庫`, `Yarn Library`, then `毛糸ライブラリ`.
3. Confirm existing yarn names and photos remain unchanged.

If a physical target is unavailable, report that target as `PENDING`; do not infer PASS from another platform or from automated tests.
