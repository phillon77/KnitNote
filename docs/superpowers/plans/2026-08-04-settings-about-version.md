# Settings About Version Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the installed KnitNote version and build number in a static About section at the bottom of Settings on iPhone, iPad, and Mac.

**Architecture:** Parse bundle metadata through a small immutable `KnitNoteCore` value type so invalid or missing values are handled deterministically and can be unit tested without a live app bundle. Inject the resolved value into the shared `SettingsView`, format it with localized punctuation, and keep the row read-only with no navigation, persistence, or release-state side effects.

**Tech Stack:** Swift 6, Foundation `Bundle`, SwiftUI, Swift Testing, XCStrings, XcodeGen, iOS 18, macOS 15.

## Global Constraints

- Target KnitNote 1.3.1; do not modify the approved 1.3.0 Build 6 candidate.
- Support iPhone, iPad, and Mac through the shared `SettingsView`; do not add an Apple Watch settings row.
- Place one final `About` section after `BackupSettingsSection()` with one static `Version` row.
- Read `CFBundleShortVersionString` and `CFBundleVersion` from the running app bundle; never hardcode `1.3.1`, `7`, `MARKETING_VERSION`, or project-file values.
- If either field is missing, not a string, or blank after trimming, display `—` for the entire value.
- Preserve non-empty version and build strings exactly after trimming; do not parse them as numbers.
- English format is `%1$@ (Build %2$@)` and Traditional Chinese format is `%1$@（Build %2$@）`.
- The row is static text: no `Button`, `NavigationLink`, copy action, chevron, second page, website, privacy, developer, commit, build-date, or device details.
- Do not persist version data in `JSONProjectStore`, UserDefaults, pattern/project data, or backup files.
- Do not add a dependency or modify StoreKit, pricing, trial, entitlements, privacy metadata, version/build, Git remote state, or App Store Connect state.

---

### Task 1: Parse Bundle Version Metadata in KnitNoteCore

**Files:**
- Create: `Sources/KnitNoteCore/App/AppVersionInfo.swift`
- Create: `Tests/KnitNoteCoreTests/AppVersionInfoTests.swift`

**Interfaces:**
- Consumes: `[String: Any]` or `Bundle.infoDictionary`.
- Produces: `AppVersionInfo(version:build:)`, `AppVersionInfo.init?(infoDictionary:)`, and `AppVersionInfo.current(in:)`.
- Task 2 receives an `AppVersionInfo?`; the parser does not localize or format UI text.

- [ ] **Step 1: Write failing parser tests**

Create `AppVersionInfoTests.swift`:

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite struct AppVersionInfoTests {
    @Test func parsesAndTrimsBothRequiredStrings() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 1.3.1 ",
            "CFBundleVersion": " 007 ",
        ])
        #expect(info == AppVersionInfo(version: "1.3.1", build: "007"))
    }

    @Test(arguments: [
        [:],
        ["CFBundleShortVersionString": "1.3.1"],
        ["CFBundleVersion": "7"],
        ["CFBundleShortVersionString": "", "CFBundleVersion": "7"],
        ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "   "],
        ["CFBundleShortVersionString": 131, "CFBundleVersion": "7"],
        ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": 7],
    ] as [[String: Any]])
    func rejectsIncompleteMalformedOrBlankMetadata(dictionary: [String: Any]) {
        #expect(AppVersionInfo(infoDictionary: dictionary) == nil)
    }

    @Test func preservesNonNumericComponents() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.3.1-beta",
            "CFBundleVersion": "7A",
        ])
        #expect(info?.version == "1.3.1-beta")
        #expect(info?.build == "7A")
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter AppVersionInfoTests
```

Expected: compilation fails because `AppVersionInfo` does not exist.

- [ ] **Step 3: Implement the immutable parser and live-bundle factory**

Create `AppVersionInfo.swift`:

```swift
import Foundation

public struct AppVersionInfo: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public init?(infoDictionary: [String: Any]) {
        guard
            let rawVersion = infoDictionary["CFBundleShortVersionString"] as? String,
            let rawBuild = infoDictionary["CFBundleVersion"] as? String
        else { return nil }

        let version = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = rawBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, !build.isEmpty else { return nil }

        self.init(version: version, build: build)
    }

    public static func current(in bundle: Bundle = .main) -> AppVersionInfo? {
        guard let dictionary = bundle.infoDictionary else { return nil }
        return AppVersionInfo(infoDictionary: dictionary)
    }
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter AppVersionInfoTests
```

Expected: all parser cases pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/KnitNoteCore/App/AppVersionInfo.swift \
  Tests/KnitNoteCoreTests/AppVersionInfoTests.swift
git commit -m "feat: parse installed app version"
```

---

### Task 2: Add the Static Localized About Section

**Files:**
- Modify: `KnitNote/Settings/SettingsView.swift`
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`
- Create: `Tests/KnitNoteCoreTests/SettingsAboutVersionContractTests.swift`
- Regenerate: `KnitNote.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `AppVersionInfo?` from Task 1.
- Produces: `SettingsView(storedLanguage:versionInfo:)` with a default live-bundle value and a final static About section.

- [ ] **Step 1: Write failing localization and source-contract tests**

Add these entries to the required localization dictionary in `LocalizationContractTests.swift`:

```swift
"settings.about": ["en": "About", "zh-Hant": "關於"],
"settings.version": ["en": "Version", "zh-Hant": "版本"],
"settings.version.format": ["en": "%1$@ (Build %2$@)", "zh-Hant": "%1$@（Build %2$@）"],
```

Create `SettingsAboutVersionContractTests.swift`:

```swift
import Foundation
import Testing

@Suite struct SettingsAboutVersionContractTests {
    @Test func settingsEndsWithAStaticInjectedVersionRow() throws {
        let source = try appSource("KnitNote/Settings/SettingsView.swift")
        #expect(source.contains("let versionInfo: AppVersionInfo?"))
        #expect(source.contains("versionInfo: AppVersionInfo? = AppVersionInfo.current()"))
        #expect(source.contains("Section(\"settings.about\")"))
        #expect(source.contains("Text(\"settings.version\")"))
        #expect(source.contains("BackupSettingsSection()"))
        #expect(source.range(of: "BackupSettingsSection()")!.lowerBound < source.range(of: "Section(\"settings.about\")")!.lowerBound)
        #expect(!source.contains("NavigationLink(value: versionInfo"))
        #expect(!source.contains("Button(\"settings.version\""))
    }

    @Test func settingsDoesNotHardcodeThePlannedReleaseNumbers() throws {
        let source = try appSource("KnitNote/Settings/SettingsView.swift")
        #expect(!source.contains("1.3.1"))
        #expect(!source.contains("Build 7"))
        #expect(!source.contains("MARKETING_VERSION"))
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: repositoryRoot.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter SettingsAboutVersionContractTests
swift test --filter LocalizationContractTests
```

Expected: the contract suite fails because the new section and localization entries are absent.

- [ ] **Step 3: Inject version info without changing existing call sites**

Replace the synthesized `SettingsView` initializer with this explicit initializer:

```swift
struct SettingsView: View {
    @Binding var storedLanguage: String
    let versionInfo: AppVersionInfo?

    init(
        storedLanguage: Binding<String>,
        versionInfo: AppVersionInfo? = AppVersionInfo.current()
    ) {
        _storedLanguage = storedLanguage
        self.versionInfo = versionInfo
    }
```

Existing app call sites continue using `SettingsView(storedLanguage:)`; tests and previews can inject known values or `nil`.

- [ ] **Step 4: Add the final static row with localized formatting and fallback**

Add this section immediately after `BackupSettingsSection()` in `settingsForm`:

```swift
Section("settings.about") {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text("settings.version")
        Spacer(minLength: 12)
        Text(versionDisplay)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
}
```

Add this computed property to `SettingsView`:

```swift
private var versionDisplay: String {
    guard let versionInfo else { return "—" }
    return String(
        format: String(localized: "settings.version.format"),
        locale: Locale.current,
        versionInfo.version,
        versionInfo.build
    )
}
```

The row has no gesture, button style, link, chevron, focus target, or persistence call.

- [ ] **Step 5: Add localization, regenerate membership, and verify focused checks**

Add the exact English and Traditional Chinese strings from Step 1 to `Localizable.xcstrings`, then run:

```bash
xcodegen generate
swift test --filter AppVersionInfoTests
swift test --filter SettingsAboutVersionContractTests
swift test --filter LocalizationContractTests
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: all focused suites and both builds pass. Inspect the generated project diff and accept only new source/test membership; reject any version/build drift.

- [ ] **Step 6: Commit Task 2**

```bash
git add KnitNote/Settings/SettingsView.swift \
  KnitNote/Localization/Localizable.xcstrings \
  Tests/KnitNoteCoreTests/LocalizationContractTests.swift \
  Tests/KnitNoteCoreTests/SettingsAboutVersionContractTests.swift \
  KnitNote.xcodeproj/project.pbxproj
git commit -m "feat: show installed version in settings"
```

---

### Task 3: Full Regression and Exact-Candidate Acceptance

**Files:**
- Modify only if an acceptance defect is found: files owned by Tasks 1–2 and their tests.
- Do not modify release metadata during this task.

**Interfaces:**
- Consumes: the parser and Settings row from Tasks 1–2.
- Produces: verified evidence suitable for later inclusion in one separate 1.3.1 release candidate.

- [ ] **Step 1: Run the complete automated suite**

```bash
swift test --disable-sandbox
```

Expected: zero failures.

- [ ] **Step 2: Run clean unsigned iOS and macOS builds**

```bash
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .derived-data/settings-version-ios \
  CODE_SIGNING_ALLOWED=NO clean build
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .derived-data/settings-version-macos \
  CODE_SIGNING_ALLOWED=NO clean build
```

Expected: both builds end with `BUILD SUCCEEDED`.

- [ ] **Step 3: Perform same-commit physical acceptance**

Install builds from the same recorded commit, then verify:

1. iPhone Settings shows the exact bundle version and build from Xcode/archive, including English half-width punctuation and Traditional Chinese full-width punctuation.
2. iPad portrait, landscape, and enlarged Dynamic Type show the complete row without clipping.
3. Mac shows the same version and build at the bottom of the existing bounded Settings form without changing its width or layout.
4. VoiceOver reads the version and build as static information and does not announce a button or link.
5. A test build with either bundle field omitted displays `—` and leaves language, calculators, yarn-label storage, backup, and restore usable.

- [ ] **Step 4: Record the verified boundary**

```bash
git rev-parse HEAD
git status --short
git diff --check
```

Record the exact commit and installed artifact for all three platforms. Stop if any platform shows a different version/build or was built from a different commit. Do not merge, push, change version/build, upload, or submit without separate authorization.
