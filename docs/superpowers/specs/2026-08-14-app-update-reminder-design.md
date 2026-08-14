# KnitNote App Update Reminder Design

**Date:** 2026-08-14  
**Status:** Approved in conversation; written-spec review pending  
**Targets:** iPhone, iPad, and Mac  
**App Store Apple ID:** `6793023054`

## Goal

Notify a user when a newer public KnitNote marketing version is available on
the App Store, without delaying launch, requiring notification permission,
collecting user data, or repeatedly interrupting the user.

## Approved product behavior

- Begin one non-blocking update check after the normal app UI becomes usable.
- Compare the installed `CFBundleShortVersionString` with the public App Store
  marketing version. Build numbers are not user-facing update criteria.
- Present an optional localized alert only when the public version is newer.
- The alert shows the installed and latest versions and offers:
  - **Go to App Store** — opens KnitNote's product page for the current
    storefront.
  - **Later** — dismisses the alert and suppresses that same public version for
    seven days.
- If a still-newer public version appears during the seven-day suppression
  window, it may be shown immediately.
- Never force an update. The app remains fully usable after dismissal.
- Do not request notification permission and do not use local or remote push
  notifications.
- Do not run the check in App Store screenshot fixture mode.

## Store source and platform rule

Use Apple's public ID lookup for Apple ID `6793023054` over HTTPS. Apple's
documented ID lookup returns JSON and avoids title-search false matches. The
current public response identifies exactly one result with bundle identifier
`com.phillon.KnitNote`, version `1.5.0`, and device-family coverage including
iPhone, iPad, and Mac.

The response is accepted only if all of these conditions hold:

1. `resultCount` is exactly `1` and there is exactly one result.
2. `trackId` is exactly `6793023054`.
3. `bundleId` is exactly `com.phillon.KnitNote`.
4. `version` parses as a supported marketing version.
5. `trackViewUrl` is HTTPS and belongs to `apps.apple.com`.
6. The record supports the running platform's device family.

KnitNote's iOS/iPadOS and macOS releases continue to use the same marketing
version. If Apple ever exposes divergent platform versions under this record,
the release process must resolve that before relying on this checker; the app
must not guess or display an ambiguous update.

Use the current App Store storefront country when available. Fall back to the
device locale region, then `tw`. Country codes must be normalized to lowercase
ASCII letters before URL construction. The response-provided, validated
`trackViewUrl` is the preferred destination; the deterministic fallback is
`https://apps.apple.com/<country>/app/id6793023054`.

Apple's archived official Search API documentation notes that ID lookup is the
faster, lower-false-positive form and that software entities cover iOS, iPad,
and Mac software:

- <https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/LookupExamples.html>
- <https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html>

Because this is a public, legacy lookup surface rather than a contractual app
update API, all transport, schema, identity, or ambiguity failures are handled
fail-silent and never block normal app use.

## Architecture

### `AppVersion`

A small value type in `KnitNoteCore` parses and compares marketing versions.
It accepts two or three dot-separated non-negative decimal components, such as
`1.5` or `1.5.1`, normalizing missing patch components to zero. It rejects:

- empty components;
- signs, whitespace within components, or non-decimal characters;
- more than three components;
- integer overflow.

Comparison is numeric by component. Examples:

- `1.5.2 > 1.5.1`
- `1.6 > 1.5.99`
- `1.5 == 1.5.0`
- `1.5.1 < 2.0`

Prerelease labels are not accepted because production App Store marketing
versions are expected to be release versions.

### `AppUpdateChecking`

An injected async interface returns a validated `AvailableAppUpdate` containing:

- public `AppVersion`;
- display version string;
- validated App Store product URL.

The live implementation uses an ephemeral `URLSession`, a short request timeout,
no credentials, no cookies, and no user-specific payload. Tests use deterministic
fakes and do not contact Apple.

### `UpdateReminderPolicy`

A pure policy receives:

- installed version;
- available public version;
- current date;
- optional stored dismissal version and date.

It returns either `.present(update)` or `.doNotPresent`. The same dismissed
version is suppressed until `dismissedAt + 7 days`. A higher public version is
eligible immediately. Equal, older, malformed, or ambiguous versions never
present.

### `AppUpdateReminderCoordinator`

A main-actor observable coordinator owns presentation state and prevents
duplicate concurrent checks. It is constructed at app startup and injected
into the root presentation layer.

The coordinator:

1. receives an active-scene opportunity after the main UI is usable;
2. runs at most one check per app process launch;
3. exits immediately in screenshot fixture mode;
4. obtains and validates the public result off the main actor;
5. applies `UpdateReminderPolicy`;
6. exposes an optional alert model;
7. records the version and date only when the user chooses **Later**;
8. opens the validated product URL when the user chooses **Go to App Store**.

The check does not depend on entitlement preparation, project loading, pattern
inbox processing, or user data. Update state uses dedicated `UserDefaults` keys
and is never part of project archives or backups.

## Presentation and interaction ordering

The update alert is attached at the app's root presentation boundary so it can
appear on iPhone, iPad, and Mac. It must use locale-aware strings based on the
app's selected language rather than the system language.

Existing blocking errors and user-initiated sheets take priority. If another
alert or modal is active when the update becomes eligible, the coordinator
retains the pending update and presents it only after that presentation clears.
The alert must not replace pattern-import failures, backup warnings, paywall
requests, or destructive confirmations.

Changing the in-app language while the alert is visible must update its title,
message, and button labels without translating either version number.

## Localization

Add a compact update-reminder key family to the main String Catalog for all 13
shipping locales:

- `update.available.title`
- `update.available.message`
- `update.available.currentVersion`
- `update.available.latestVersion`
- `update.available.openStore`
- `update.available.later`

The message format must preserve positional placeholders and version values
exactly. Localization contracts must require translated, nonblank values and
matching placeholder structure for every locale.

## Failure behavior and privacy

All failures are silent:

- offline or captive network;
- timeout or cancellation;
- non-2xx HTTP status;
- invalid JSON or unexpected result count;
- wrong Apple ID or bundle identifier;
- missing device-family coverage;
- non-HTTPS or non-Apple destination URL;
- malformed installed or public version.

The checker records no analytics, device identifier, project content, language
selection, or response body. It sends only the App Store lookup request needed
to identify the public KnitNote record.

## Testing

### Core behavior

- Version parsing, normalization, ordering, overflow, and invalid inputs.
- Newer, equal, and older App Store versions.
- First presentation for a new public version.
- Same-version suppression before seven days and eligibility at seven days.
- Immediate eligibility for a higher version during suppression.
- No persistence change when merely checking or opening the store.
- Persistence only when **Later** is selected.

### Lookup validation

- Exact valid Apple ID, bundle ID, result count, version, HTTPS Apple URL, and
  running device family.
- Wrong identity, duplicate/empty results, wrong host, HTTP URL, malformed
  payload, transport error, and timeout all fail silent.
- Storefront country normalization and deterministic fallback URL.

### Presentation contracts

- One process-launch check only and no check in screenshot fixture mode.
- Update presentation does not displace existing higher-priority alerts.
- **Go to App Store** and **Later** call the correct coordinator actions.
- The alert resolves through the selected in-app locale on iOS/iPadOS and Mac.
- All six keys exist and are structurally valid in all 13 locales.

### Regression and builds

- Existing project, pattern, yarn, folder, backup, entitlement, inbox, and
  screenshot suites remain green.
- Unsigned iOS Simulator and macOS builds pass from the generated project.
- Physical smoke acceptance confirms the alert layout and App Store navigation
  on iPhone/iPad and Mac without altering existing user data.

## Non-goals

- Forced or minimum-version enforcement.
- Push notifications or background polling.
- Release notes, marketing announcements, or remote-config messages.
- App Store Connect authentication or a custom backend.
- Updating Watch independently; Watch follows the companion app update.
- Comparing build numbers.
- Changing any project, pattern, yarn, folder, backup, or archive schema.

## Acceptance criteria

The feature is complete when a newer valid public marketing version produces
one localized optional alert on iPhone, iPad, and Mac; **Later** suppresses that
same version for seven days; a higher version bypasses that suppression; **Go
to App Store** opens the validated KnitNote page; failures remain silent; and
all existing user data and release gates remain unchanged.
