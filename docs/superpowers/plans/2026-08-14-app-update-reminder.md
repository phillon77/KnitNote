# KnitNote App Update Reminder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-blocking, optional, seven-day-snoozable App Store update reminder for KnitNote on iPhone, iPad, and Mac.

**Architecture:** Pure `KnitNoteCore` types parse versions, validate Apple's lookup payload, and decide reminder eligibility. A main-app-only coordinator performs the async lookup, persists only the user's **Later** choice, and exposes one presentation model to `RootView`; the view supplies locale-aware copy and opens the validated App Store URL. A DEBUG-only deterministic fixture makes the alert physically testable without waiting for a public release.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, Foundation `URLSession`, StoreKit 2 `Storefront`, `UserDefaults`, Apple String Catalog, XcodeGen, iOS 18+, macOS 15+.

## Global Constraints

- Apple ID is exactly `6793023054`; bundle ID is exactly `com.phillon.KnitNote`.
- Targets are iPhone, iPad, and Mac. Watch does not check independently.
- Compare only `CFBundleShortVersionString`; never compare or display build-number eligibility.
- A newer valid public version is optional. Never force an update.
- **Later** suppresses only that version for exactly seven days; a higher version is eligible immediately.
- Check at most once per app process launch, after normal UI is usable, and never in Store screenshot fixture mode.
- Lookup, decoding, identity, URL, network, timeout, or version errors fail silent and never block launch.
- Do not request notification permission; do not add push, background polling, analytics, credentials, cookies, or a custom backend.
- Use the app-selected locale for every alert string; preserve user-created/imported content verbatim.
- Add all update keys to the main String Catalog for exactly the 13 shipping locales: `en`, `zh-Hant`, `zh-Hans`, `de`, `fr`, `ja`, `nb`, `sv`, `fi`, `da`, `ko`, `el`, `nl`.
- Do not change project, pattern, yarn, folder, backup, inbox, entitlement, or archive schemas.
- Production accepts only one exact Apple result with the expected Apple ID and bundle ID, an HTTPS `apps.apple.com` URL, a valid marketing version, and current-platform device-family coverage.
- The DEBUG fixture is argument-gated, must be impossible in Release, performs no network request, and must not overlap `StoreScreenshotMode`.

---

## File map

| File | Responsibility |
| --- | --- |
| `Sources/KnitNoteCore/App/AppVersion.swift` | Strict two/three-component marketing-version parsing and comparison. |
| `Sources/KnitNoteCore/App/UpdateReminderPolicy.swift` | Seven-day decision logic plus isolated `UserDefaults` dismissal history. |
| `Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift` | Lookup request construction, storefront normalization, JSON/identity/platform/URL validation. |
| `Sources/KnitNoteCore/App/AppUpdateReminderCoordinator.swift` | Main-actor once-per-launch orchestration and presentation state. |
| `KnitNote/App/AppUpdateReminderLiveFactory.swift` | StoreKit storefront and live dependency wiring for the main app. |
| `KnitNote/App/AppUpdateFixture.swift` | DEBUG-only deterministic manual-acceptance input. |
| `KnitNote/App/KnitNoteApp.swift` | Construct and inject the coordinator without starting work in screenshot mode. |
| `KnitNote/App/RootView.swift` | Trigger the check, defer behind higher-priority presentations, render localized alert, open store URL. |
| `KnitNote/Localization/Localizable.xcstrings` | Six update reminder keys in all 13 locales. |
| `project.yml` and generated `KnitNote.xcodeproj/project.pbxproj` | Keep main-app sources included and exclude update-only core files from Watch. |
| New focused test files below | Lock domain, lookup, fixture, coordinator, source ownership, localization, and presentation behavior. |

---

### Task 1: Version comparison and seven-day reminder policy

**Files:**
- Create: `Sources/KnitNoteCore/App/AppVersion.swift`
- Create: `Sources/KnitNoteCore/App/UpdateReminderPolicy.swift`
- Create: `Tests/KnitNoteCoreTests/AppVersionTests.swift`
- Create: `Tests/KnitNoteCoreTests/UpdateReminderPolicyTests.swift`

**Interfaces:**
- Consumes: installed and public marketing-version strings; a `Date`; isolated `UserDefaults`.
- Produces: `AppVersion.init?(_:)`, `Comparable`; `UpdateReminderDismissal`; `UpdateReminderPolicy.shouldPresent(installed:available:dismissal:now:)`; `UpdateReminderHistory.dismissal` and `.recordLater(version:at:)`.

- [ ] **Step 1: Verify the execution worktree before editing**

Run:

```bash
git rev-parse --show-toplevel
git branch --show-current
git status --short
git log -3 --oneline
```

Expected: an isolated feature worktree based on approved commit `2ab2468`, with no unrelated tracked changes. Preserve existing untracked files and stashes.

- [ ] **Step 2: Write strict version parser tests**

Create `AppVersionTests.swift` with exact cases:

```swift
import Testing
@testable import KnitNoteCore

@Suite struct AppVersionTests {
    @Test func parsesNormalizesAndOrdersReleaseVersions() throws {
        #expect(try #require(AppVersion("1.5")) == try #require(AppVersion("1.5.0")))
        #expect(try #require(AppVersion("1.5.2")) > try #require(AppVersion("1.5.1")))
        #expect(try #require(AppVersion("1.6")) > try #require(AppVersion("1.5.99")))
        #expect(try #require(AppVersion("2.0")) > try #require(AppVersion("1.99.99")))
    }

    @Test func rejectsMalformedPrereleaseOverflowAndWrongArity() {
        for raw in ["", "1", "1.", ".1", "1..2", "1.2.3.4", "1.5-beta", " 1.5", "1. 5", "+1.5", "-1.5", "184467440737095516160.1"] {
            #expect(AppVersion(raw) == nil, "must reject \(raw)")
        }
    }
}
```

- [ ] **Step 3: Write policy and persistence tests**

Create `UpdateReminderPolicyTests.swift`. Use a unique defaults suite per test and remove its persistent domain in `defer`. Cover these exact assertions:

```swift
let installed = try #require(AppVersion("1.5.1"))
let v152 = try #require(AppVersion("1.5.2"))
let v153 = try #require(AppVersion("1.5.3"))
let now = Date(timeIntervalSince1970: 1_800_000_000)

#expect(UpdateReminderPolicy.shouldPresent(installed: installed, available: v152, dismissal: nil, now: now))
#expect(!UpdateReminderPolicy.shouldPresent(installed: installed, available: installed, dismissal: nil, now: now))
#expect(!UpdateReminderPolicy.shouldPresent(installed: v152, available: installed, dismissal: nil, now: now))

let dismissal = UpdateReminderDismissal(version: v152, dismissedAt: now)
#expect(!UpdateReminderPolicy.shouldPresent(installed: installed, available: v152, dismissal: dismissal, now: now.addingTimeInterval(7 * 86_400 - 1)))
#expect(UpdateReminderPolicy.shouldPresent(installed: installed, available: v152, dismissal: dismissal, now: now.addingTimeInterval(7 * 86_400)))
#expect(UpdateReminderPolicy.shouldPresent(installed: installed, available: v153, dismissal: dismissal, now: now.addingTimeInterval(1)))
```

Also require:

- reading empty defaults returns `nil`;
- `recordLater` writes both version and timestamp;
- malformed stored version or missing timestamp returns `nil` and removes both corrupt keys;
- merely constructing or reading history does not write defaults.

- [ ] **Step 4: Run RED tests**

Run:

```bash
swift test --disable-sandbox --filter 'AppVersionTests|UpdateReminderPolicyTests'
```

Expected: compile failure because `AppVersion`, `UpdateReminderPolicy`, and history types do not exist.

- [ ] **Step 5: Implement the minimum domain types**

Use this public shape in `AppVersion.swift`:

```swift
public struct AppVersion: Comparable, Hashable, Sendable, Codable {
    public let major: UInt
    public let minor: UInt
    public let patch: UInt

    public init?(_ rawValue: String) { /* strict split and UInt parsing */ }
    public var displayString: String { "\(major).\(minor).\(patch)" }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
```

Do not use lexical comparison or `OperatingSystemVersion`. Preserve the public display string from Apple's validated payload separately later; `displayString` is only the canonical fallback.

Use this shape in `UpdateReminderPolicy.swift`:

```swift
public struct UpdateReminderDismissal: Equatable, Sendable {
    public let version: AppVersion
    public let dismissedAt: Date
}

public enum UpdateReminderPolicy {
    public static let snoozeInterval: TimeInterval = 7 * 86_400
    public static func shouldPresent(
        installed: AppVersion,
        available: AppVersion,
        dismissal: UpdateReminderDismissal?,
        now: Date
    ) -> Bool { /* exact approved rules */ }
}

public struct UpdateReminderHistory {
    public init(defaults: UserDefaults = .standard)
    public var dismissal: UpdateReminderDismissal? { get }
    public func recordLater(version: AppVersion, at date: Date = .now)
}
```

Use dedicated keys `updateReminder.dismissedVersion` and `updateReminder.dismissedAt`. Store the canonical three-component version string and `Date.timeIntervalSince1970`.

- [ ] **Step 6: Run GREEN and adjacent tests**

Run:

```bash
swift test --disable-sandbox --filter 'AppVersionTests|UpdateReminderPolicyTests|AppVersionInfoTests|BackupHistoryTests'
git diff --check
```

Expected: all selected tests pass; no whitespace errors.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/KnitNoteCore/App/AppVersion.swift Sources/KnitNoteCore/App/UpdateReminderPolicy.swift Tests/KnitNoteCoreTests/AppVersionTests.swift Tests/KnitNoteCoreTests/UpdateReminderPolicyTests.swift
git commit -m "feat: define app update reminder policy"
```

---

### Task 2: Apple lookup request and fail-silent validation

**Files:**
- Create: `Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift`
- Create: `Tests/KnitNoteCoreTests/AppStoreUpdateLookupTests.swift`

**Interfaces:**
- Consumes: `AppVersion` from Task 1, Apple ID `6793023054`, bundle ID `com.phillon.KnitNote`, platform, country candidate, and injected HTTP loader.
- Produces: `AppStorePlatform`, `AvailableAppUpdate`, `AppUpdateHTTPResponse`, `AppStoreUpdateLookup.fetch(countryCode:platform:) async -> AvailableAppUpdate?`, `.live()`, `.normalizedCountryCode(_:)`, and `.alpha2CountryCode(storefrontCountryCode:)`.

- [ ] **Step 1: Write request and valid-payload tests**

Use an injected loader that captures `URLRequest` and returns:

```json
{
  "resultCount": 1,
  "results": [{
    "trackId": 6793023054,
    "bundleId": "com.phillon.KnitNote",
    "version": "1.5.2",
    "trackViewUrl": "https://apps.apple.com/tw/app/knitnote/id6793023054?uo=4",
    "supportedDevices": ["iPhone17ProMax-iPhone17ProMax", "iPadAir5-iPadAir5", "MacDesktop-MacDesktop"]
  }]
}
```

Require:

```swift
#expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?id=6793023054&country=tw")
#expect(request.httpMethod == "GET")
#expect(update?.version == AppVersion("1.5.2"))
#expect(update?.displayVersion == "1.5.2")
#expect(update?.storeURL.host == "apps.apple.com")
```

Test `.iPhone` against an `iPhone`-prefixed token, `.iPad` against an `iPad`-prefixed token, and `.macOS` against `MacDesktop-MacDesktop`; each platform must reject payloads containing only either of the other families.

- [ ] **Step 2: Write fail-silent mutation tests**

One parameterized test must return `nil` for every mutation:

- HTTP `404` or `500`;
- empty data or invalid JSON;
- `resultCount` `0` or `2`;
- zero, duplicate, non-object, or extra results;
- wrong `trackId` or wrong `bundleId`;
- missing or malformed `version`;
- `http://apps.apple.com/...`;
- `https://example.com/...` and `https://apps.apple.com.evil.example/...`;
- missing `trackViewUrl`;
- current platform absent from `supportedDevices`;
- injected loader throws `URLError(.notConnectedToInternet)`, `.timedOut`, or `CancellationError`.

Add request-country cases requiring `tw`, `us`, `jp`, `de` and rejecting values with punctuation, path/query characters, or more/fewer than two ASCII letters. Invalid candidates fall back to `tw`.

Add storefront conversion cases requiring `TWN -> tw`, `USA -> us`, `JPN -> jp`, and `DEU -> de`. Unknown, empty, or malformed alpha-3 codes return `nil`; they do not silently become `tw` until the request-construction fallback is applied.

- [ ] **Step 3: Run RED tests**

```bash
swift test --disable-sandbox --filter AppStoreUpdateLookupTests
```

Expected: compile failure because lookup interfaces do not exist.

- [ ] **Step 4: Implement the lookup client**

Use these signatures:

```swift
public enum AppStorePlatform: Sendable { case iPhone, iPad, macOS }

public struct AvailableAppUpdate: Equatable, Sendable, Identifiable {
    public var id: AppVersion { version }
    public let version: AppVersion
    public let displayVersion: String
    public let storeURL: URL
}

public struct AppUpdateHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
}

public struct AppStoreUpdateLookup: Sendable {
    public typealias Loader = @Sendable (URLRequest) async throws -> AppUpdateHTTPResponse
    public init(loader: @escaping Loader)
    public func fetch(countryCode: String?, platform: AppStorePlatform) async -> AvailableAppUpdate?
    public static func live(timeout: TimeInterval = 8) -> Self
    public static func normalizedCountryCode(_ candidate: String?) -> String?
    public static func alpha2CountryCode(storefrontCountryCode: String?) -> String?
}
```

Build URLs with `URLComponents`, not string interpolation. Decode into private `Decodable` payload types, require `200...299`, validate exact identity and URL components, then validate device families:

- iPhone: any token beginning `iPhone`;
- iPad: any token beginning `iPad`;
- Mac: exact `MacDesktop-MacDesktop` or a token beginning `Mac`.

For `.live()`, use an ephemeral session, set request/resource timeout to eight seconds, disable cookies, and convert `HTTPURLResponse.statusCode` into `AppUpdateHTTPResponse`. Catch every error inside `fetch` and return `nil`.

- [ ] **Step 5: Run GREEN and mutation coverage**

```bash
swift test --disable-sandbox --filter 'AppStoreUpdateLookupTests|AppVersionTests|UpdateReminderPolicyTests'
git diff --check
```

Expected: all selected tests pass, including all identity and URL mutations.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/KnitNoteCore/App/AppStoreUpdateLookup.swift Tests/KnitNoteCoreTests/AppStoreUpdateLookupTests.swift
git commit -m "feat: validate public app update lookup"
```

---

### Task 3: Coordinator, deterministic DEBUG fixture, and root presentation

**Files:**
- Create: `Sources/KnitNoteCore/App/AppUpdateReminderCoordinator.swift`
- Create: `KnitNote/App/AppUpdateReminderLiveFactory.swift`
- Create: `KnitNote/App/AppUpdateFixture.swift`
- Modify: `KnitNote/App/KnitNoteApp.swift`
- Modify: `KnitNote/App/RootView.swift`
- Create: `Tests/KnitNoteCoreTests/AppUpdateReminderCoordinatorTests.swift`
- Create: `Tests/KnitNoteCoreTests/AppUpdateReminderViewContractTests.swift`
- Create: `Tests/KnitNoteCoreTests/AppUpdateFixtureContractTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2 domain and lookup interfaces; `AppVersionInfo.current()`; selected locale; `OpenURLAction`; current scene phase; existing root presentation state.
- Produces: `AppUpdateReminderCoordinator.pendingUpdate`, `.checkIfNeeded()`, `.remindLater()`, `.didOpenStore()`; `AppUpdateReminderLiveFactory.make(...)`; `AppUpdateFixture.resolve(arguments:)`.

- [ ] **Step 1: Write coordinator behavior tests before production code**

The coordinator test target must instantiate the coordinator with injected closures, a unique defaults suite, and fixed `now`. Require:

- `checkIfNeeded()` calls the checker exactly once across two calls;
- enabled + installed `1.5.1` + public `1.5.2` publishes one pending update;
- equal/older/malformed installed version publishes nothing;
- disabled mode never calls the checker;
- lookup `nil` publishes nothing;
- an existing seven-day dismissal suppresses the same version;
- a higher version bypasses dismissal;
- `remindLater()` persists exactly the pending version/date and clears presentation;
- `didOpenStore()` clears presentation without writing defaults;
- cancellation after the async loader starts publishes nothing.

Expose only the minimum initializer needed for deterministic tests:

```swift
@MainActor
init(
    enabled: Bool,
    installedVersion: @escaping () -> String?,
    platform: AppStorePlatform,
    countryCode: @escaping @Sendable () async -> String?,
    fetch: @escaping @Sendable (String?, AppStorePlatform) async -> AvailableAppUpdate?,
    history: UpdateReminderHistory,
    now: @escaping () -> Date = { .now }
)
```

- [ ] **Step 2: Write source-owner and alert-scope contracts**

`AppUpdateReminderViewContractTests` must slice the exact update-alert modifier in `RootView.swift` between unique markers or helper boundaries and require inside that slice:

- all six localization keys;
- `LocaleAwareText.string`/`format` with `locale`;
- current and latest version values;
- one **Later** action calling `remindLater()`;
- one store action calling `openURL(update.storeURL)` and `didOpenStore()`;
- a presentation binding gated by backup reminder, inbox failure/selection, unlock sheet, backup settings, and pending update;
- active-scene task calling `checkIfNeeded()`;
- no hard-coded English or Traditional Chinese user-facing update copy.

Add mutation tests or fixture-based source probes that separately remove each button action, locale argument, blocker, and scene guard while leaving decoy tokens elsewhere; every mutation must fail exactly the intended contract.

- [ ] **Step 3: Write DEBUG fixture contracts**

The fixture accepts only:

```text
-appUpdateFixture YES
-appUpdateFixtureVersion 9.9.9
```

Require `#if DEBUG`; exact opt-in flag/value; strict `AppVersion` parsing; deterministic `https://apps.apple.com/tw/app/id6793023054`; no fixture in Release; no environment-variable override; and a guard preventing simultaneous `-storeScreenshotMode` use. Production `KnitNoteApp` must not honor either fixture argument outside DEBUG.

- [ ] **Step 4: Run RED tests**

```bash
swift test --disable-sandbox --filter 'AppUpdateReminderCoordinatorTests|AppUpdateReminderViewContractTests|AppUpdateFixtureContractTests'
```

Expected: compile/source-contract failures because coordinator, fixture, and root wiring are absent.

- [ ] **Step 5: Implement coordinator and storefront-country resolution**

Create the coordinator as `@MainActor final class ...: ObservableObject` with `@Published private(set) var pendingUpdate`. Set `didCheck = true` before the first suspension to prevent concurrent duplicates.

Keep the coordinator in `KnitNoteCore`; it imports Foundation and Combine but not SwiftUI or StoreKit. Resolve the country in `KnitNote/App/AppUpdateReminderLiveFactory.swift` immediately before lookup:

```swift
import StoreKit

let storefrontCode = await Storefront.current?.countryCode
let alpha2 = storefrontCode.flatMap {
    Locale(identifier: "en_\($0)").region?.identifier
}
return AppStoreUpdateLookup.normalizedCountryCode(alpha2)
    ?? AppStoreUpdateLookup.normalizedCountryCode(Locale.current.region?.identifier)
    ?? "tw"
```

Do not persist storefront data. Apple documents `Storefront.current` as async and storefront `countryCode` as ISO alpha-3; tests must lock alpha-3-to-alpha-2 normalization for `TWN -> tw`, `USA -> us`, `JPN -> jp`, and `DEU -> de`.

When DEBUG fixture mode is active, inject its `AvailableAppUpdate` through the same policy/coordinator path and never call the live loader.

- [ ] **Step 6: Construct and inject the coordinator in `KnitNoteApp`**

Add one `@StateObject private var appUpdateReminderCoordinator`. In `init`, resolve `AppUpdateFixture` only after `StoreScreenshotMode`; reject overlapping fixture/screenshot requests. Use `AppUpdateReminderLiveFactory.make(...)` only when `screenshotMode == nil`; inject the coordinator only into the normal `RootView` hierarchy with `.environmentObject(...)`.

Do not start the check in `KnitNoteApp.init` or its entitlement `.task`.

- [ ] **Step 7: Present the alert in `RootView`**

Add `@Environment(\.locale)`, `@Environment(\.openURL)`, and the coordinator environment object. Add a separate active-scene `.task(id: scenePhase)` that calls `await coordinator.checkIfNeeded()` without waiting for entitlement preparation.

Build the message from all approved keys:

```swift
let currentLine = "\(LocaleAwareText.string("update.available.currentVersion", locale: locale)): \(installedVersion)"
let latestLine = "\(LocaleAwareText.string("update.available.latestVersion", locale: locale)): \(update.displayVersion)"
let message = LocaleAwareText.format(
    "update.available.message",
    locale: locale,
    currentLine,
    latestLine
)
```

The format string will contain positional `%1$@` and `%2$@`. Use `Text(verbatim:)` for the fully formatted message and `Text(verbatim: LocaleAwareText.string(...))` for button labels.

The presentation binding may be true only when:

- `pendingUpdate != nil`;
- no backup reminder or backup settings sheet is active;
- no inbox failure or pending selection is active;
- no unlock sheet is active.

If blocked, retain `pendingUpdate`; SwiftUI presents it when blockers clear. Never dismiss or mutate the higher-priority presentation.

- [ ] **Step 8: Run GREEN and adjacent presentation suites**

```bash
swift test --disable-sandbox --filter 'AppUpdateReminderCoordinatorTests|AppUpdateReminderViewContractTests|AppUpdateFixtureContractTests|StoreScreenshotModeContractTests|RuntimeLocalizationBehaviorTests|RuntimeLocalizationSourceContractTests'
git diff --check
```

Expected: all selected tests pass and screenshot isolation remains intact.

- [ ] **Step 9: Commit Task 3**

```bash
git add Sources/KnitNoteCore/App/AppUpdateReminderCoordinator.swift KnitNote/App/AppUpdateReminderLiveFactory.swift KnitNote/App/AppUpdateFixture.swift KnitNote/App/KnitNoteApp.swift KnitNote/App/RootView.swift Tests/KnitNoteCoreTests/AppUpdateReminderCoordinatorTests.swift Tests/KnitNoteCoreTests/AppUpdateReminderViewContractTests.swift Tests/KnitNoteCoreTests/AppUpdateFixtureContractTests.swift
git commit -m "feat: present optional app update reminders"
```

---

### Task 4: Complete 13-locale update copy and contracts

**Files:**
- Modify: `KnitNote/Localization/Localizable.xcstrings`
- Modify: `Tests/KnitNoteCoreTests/LocalizationContractTests.swift`

**Interfaces:**
- Consumes: six exact keys used by Task 3.
- Produces: complete 13-locale String Catalog entries with exact positional placeholder parity.

- [ ] **Step 1: Add a failing update-key-domain contract**

Add `shippingMainCatalogRequiresCompleteAppUpdateReminderDomain()` requiring exactly these keys:

```swift
let requiredUpdateKeys = [
    "update.available.title",
    "update.available.message",
    "update.available.currentVersion",
    "update.available.latestVersion",
    "update.available.openStore",
    "update.available.later",
]
```

For every key require exactly `SupportedLocalization.v150Identifiers`, translated state, nonblank/non-key-valued text, and a comment containing `app update`. For `update.available.message`, require exactly one `%1$@` and one `%2$@` in every locale and no other format tokens.

- [ ] **Step 2: Run localization RED**

```bash
swift test --disable-sandbox --filter 'shippingMainCatalogRequiresCompleteAppUpdateReminderDomain|StringCatalogLocalizationContractTests'
```

Expected: fail because all six keys are absent.

- [ ] **Step 3: Add the exact approved translations**

Use this table. In each `message`, encode a localized introductory sentence followed by a newline, `%1$@`, another newline, and `%2$@`.

| Locale | Title | Message prefix | Current | Latest | Open Store | Later |
| --- | --- | --- | --- | --- | --- | --- |
| `en` | New Version Available | A newer version of KnitNote is available. | Current version | Latest version | Go to App Store | Later |
| `zh-Hant` | 有新版本可用 | KnitNote 已推出較新的版本。 | 目前版本 | 最新版本 | 前往 App Store | 稍後 |
| `zh-Hans` | 有新版本可用 | KnitNote 已推出更新版本。 | 当前版本 | 最新版本 | 前往 App Store | 稍后 |
| `de` | Neue Version verfügbar | Eine neuere Version von KnitNote ist verfügbar. | Aktuelle Version | Neueste Version | Zum App Store | Später |
| `fr` | Nouvelle version disponible | Une version plus récente de KnitNote est disponible. | Version actuelle | Dernière version | Accéder à l’App Store | Plus tard |
| `ja` | 新しいバージョンがあります | KnitNoteの新しいバージョンが利用できます。 | 現在のバージョン | 最新バージョン | App Storeを開く | あとで |
| `nb` | Ny versjon tilgjengelig | En nyere versjon av KnitNote er tilgjengelig. | Gjeldende versjon | Nyeste versjon | Gå til App Store | Senere |
| `sv` | Ny version tillgänglig | En nyare version av KnitNote finns tillgänglig. | Nuvarande version | Senaste version | Gå till App Store | Senare |
| `fi` | Uusi versio saatavilla | KnitNotesta on saatavilla uudempi versio. | Nykyinen versio | Uusin versio | Siirry App Storeen | Myöhemmin |
| `da` | Ny version tilgængelig | Der er en nyere version af KnitNote. | Nuværende version | Nyeste version | Gå til App Store | Senere |
| `ko` | 새 버전을 사용할 수 있습니다 | KnitNote의 새 버전을 사용할 수 있습니다. | 현재 버전 | 최신 버전 | App Store로 이동 | 나중에 |
| `el` | Υπάρχει νέα έκδοση | Υπάρχει διαθέσιμη νεότερη έκδοση του KnitNote. | Τρέχουσα έκδοση | Νεότερη έκδοση | Μετάβαση στο App Store | Αργότερα |
| `nl` | Nieuwe versie beschikbaar | Er is een nieuwere versie van KnitNote beschikbaar. | Huidige versie | Nieuwste versie | Ga naar de App Store | Later |

Every entry must have extraction state `manual`, localization state `translated`, and a precise English developer comment. Do not change existing catalog values.

- [ ] **Step 4: Add exact-copy regression assertions**

Add a compact `[key: [locale: value]]` oracle for all six English/Traditional Chinese values and every locale's title and action labels. Assert full exact `message` values for all 13 locales, including `%1$@\n%2$@`, to prevent placeholder-preserving but linguistically wrong copy.

- [ ] **Step 5: Run GREEN localization suites**

```bash
jq empty KnitNote/Localization/Localizable.xcstrings
swift test --disable-sandbox --filter 'StringCatalogLocalizationContractTests|LocalizationContractTests|KnittingTerminologyContractTests|RuntimeLocalizationBehaviorTests'
git diff --check
```

Expected: JSON valid; all selected tests pass; terminology contracts remain green.

- [ ] **Step 6: Commit Task 4**

```bash
git add KnitNote/Localization/Localizable.xcstrings Tests/KnitNoteCoreTests/LocalizationContractTests.swift
git commit -m "feat: localize app update reminders"
```

---

### Task 5: Generated-project ownership and target builds

**Files:**
- Modify: `project.yml`
- Modify (generated): `KnitNote.xcodeproj/project.pbxproj`
- Modify: `Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift`

**Interfaces:**
- Consumes: all Task 1–4 sources.
- Produces: deterministic Xcode membership: update sources in main iOS/macOS app and excluded from Watch/Share.

- [ ] **Step 1: Write the target-ownership RED contract**

Require `project.yml` to exclude from `KnitNoteWatch`:

```text
App/AppVersion.swift
App/UpdateReminderPolicy.swift
App/AppStoreUpdateLookup.swift
App/AppUpdateReminderCoordinator.swift
```

Require the generated project to compile the four core files in `KnitNote`, contain no membership in `KnitNoteWatch` or `KnitNoteShare`, and include both main-app files `AppUpdateReminderLiveFactory.swift` and `AppUpdateFixture.swift` only in `KnitNote`.

- [ ] **Step 2: Run RED contract**

```bash
swift test --disable-sandbox --filter ReleaseConfigurationContractTests
```

Expected: fail because Watch exclusions and generated membership are not yet synchronized.

- [ ] **Step 3: Update `project.yml` and regenerate twice**

Add the four exact Watch exclusions. `KnitNote` already glob-includes `KnitNote` and `Sources/KnitNoteCore`; Share has an explicit allowlist and needs no change.

Run:

```bash
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj
xcodegen generate
shasum -a 256 KnitNote.xcodeproj/project.pbxproj
git diff --check
```

Expected: both hashes are byte-identical.

- [ ] **Step 4: Run focused tests and unsigned builds**

```bash
swift test --disable-sandbox --filter 'AppVersionTests|UpdateReminderPolicyTests|AppStoreUpdateLookupTests|AppUpdateReminderCoordinatorTests|AppUpdateReminderViewContractTests|AppUpdateFixtureContractTests|LocalizationContractTests|ReleaseConfigurationContractTests|StoreScreenshotModeContractTests'

xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/KnitNoteUpdateReminder-iOS CODE_SIGNING_ALLOWED=NO build

xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/KnitNoteUpdateReminder-macOS CODE_SIGNING_ALLOWED=NO build
```

Expected: selected tests pass and both builds end `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit generated ownership**

```bash
git add project.yml KnitNote.xcodeproj/project.pbxproj Tests/KnitNoteCoreTests/ReleaseConfigurationContractTests.swift
git commit -m "build: include app update reminder sources"
```

---

### Task 6: Full regression, deterministic UI smoke, and acceptance record

**Files:**
- Create: `AppStore/Verification/AppUpdateReminder151Verification.md`
- Modify only if a real regression is found: files owned by the failing task, with a separate RED/GREEN fix commit and review.

**Interfaces:**
- Consumes: reviewed commits from Tasks 1–5.
- Produces: exact SHA/version/build-bound automated evidence plus pending or completed physical checks; no release action.

- [ ] **Step 1: Run static and complete automated gates once**

```bash
git status --short
git diff --check
bash AppStore/Verification/release_audit.sh --static-only
swift test --disable-sandbox
```

Expected: clean scoped status, static audit PASS, and the complete suite passes with an exact test/suite count. Retain the full-suite log and exit status; do not infer PASS from a detached process and do not duplicate a retained run.

- [ ] **Step 2: Verify DEBUG fixture is deterministic on simulators**

Install the fresh iOS Debug build and launch on the first available dedicated iPhone 17 Pro Max simulator:

```bash
IPHONE_SIMULATOR_UDID=$(xcrun simctl list devices available -j | jq -er '[.devices[][] | select(.name == "iPhone 17 Pro Max")][0].udid')
xcrun simctl boot "$IPHONE_SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$IPHONE_SIMULATOR_UDID" -b
xcrun simctl install "$IPHONE_SIMULATOR_UDID" /tmp/KnitNoteUpdateReminder-iOS/Build/Products/Debug-iphonesimulator/KnitNote.app
xcrun simctl launch --terminate-running-process "$IPHONE_SIMULATOR_UDID" com.phillon.KnitNote -appUpdateFixture YES -appUpdateFixtureVersion 9.9.9
```

Require visible localized alert, current/latest lines, **Go to App Store**, and **Later**. Relaunch before seven days and require no alert after choosing **Later**. Reset only the simulator fixture app data—not any personal device—to verify version `10.0.0` bypasses the `9.9.9` dismissal.

Repeat the presentation on an iPad simulator. Launch the macOS Debug binary with the same arguments and verify identical policy/copy semantics.

- [ ] **Step 3: Verify locale reactivity and presentation priority**

With fixture alert visible, switch the app language among `zh-Hant`, `en`, and `ja`; require title/message/actions to update immediately while version strings remain exact.

Use deterministic test fixtures to place each higher-priority presentation first (inbox failure, backup reminder/settings, unlock sheet, pending pattern selection). Require the update to wait and appear only after the higher-priority presentation clears.

- [ ] **Step 4: Perform data-preserving physical smoke only after exact build binding**

Build a signed Debug app from the exact reviewed SHA and inspect its main/Watch/Share identity. Overlay install—never uninstall or erase—on the approved iPhone/iPad test device. Use the DEBUG fixture flags to verify alert layout, seven-day **Later**, App Store navigation, and preservation of existing projects, patterns, yarn, folders, notes, and settings.

On Mac, verify alert layout, keyboard focus, button activation, App Store navigation, and unchanged existing data. Do not mark unavailable devices as PASS.

- [ ] **Step 5: Write an exact verification record**

`AppUpdateReminder151Verification.md` must record:

- exact source SHA, branch, `1.5.1 (11)`, date/time zone;
- XcodeGen hash;
- focused/full test counts and retained log hashes;
- iOS/macOS build outcomes and product identities;
- simulator fixture versions and locale results;
- each physical device/OS and overlay-install result;
- checked PASS boxes only for actions actually observed;
- explicit PENDING boxes for anything unavailable;
- statement that no archive, export, upload, App Store selection, submission, release, merge, or push occurred.

- [ ] **Step 6: Commit verification evidence separately**

```bash
git add AppStore/Verification/AppUpdateReminder151Verification.md
git commit -m "test: record app update reminder acceptance"
git show --check --stat --oneline HEAD
git status --short
```

Expected: verification-only commit; no source or project drift.

---

## Plan self-review result

- **Spec coverage:** Every approved requirement maps to Tasks 1–6: version comparison, public lookup validation, seven-day policy, higher-version bypass, optional buttons, all platforms, selected-language copy, alert priority, fail-silent behavior, screenshot exclusion, privacy, builds, and physical smoke.
- **Completeness scan:** Every action names its exact file, command, expected failure or success, and required behavior.
- **Type consistency:** Task 1 produces `AppVersion`/policy/history; Task 2 consumes `AppVersion` and produces `AvailableAppUpdate`/lookup; Task 3 consumes both and exposes coordinator APIs used verbatim by the view contracts; Tasks 4–6 consume the exact six localization keys and source paths defined earlier.
- **Scope:** One bounded feature with no backend, push system, forced update, release notes, Watch-only flow, or schema migration.
