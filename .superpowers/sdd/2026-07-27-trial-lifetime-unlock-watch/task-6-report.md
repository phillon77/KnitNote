# Task 6 Report — Share Extension Read-Only Projection

## Scope

- Base: `9dc3d9a0d0886361845a23c48098892c16797794`
- Added a minimal versioned entitlement projection shared through the existing
  App Group.
- Added atomic main-app publication and a Share Extension read-only gate before
  provider selection, byte loading, or inbox enqueue.
- Added localized blocked guidance and a public-API, best-effort
  “Open KnitNote” action.
- Added no Watch entitlement payload or command behavior from Task 7.

## TDD evidence

### Projection model

The first focused RED run failed to compile because
`EntitlementProjection` did not exist. The GREEN implementation and six tests
cover:

- missing projection as first-use eligible;
- active trial acceptance and exact expiry rejection;
- permanent and legacy entitlement acceptance;
- unsupported schema and malformed field combinations failing closed;
- conversion from the authoritative snapshot without exposing trial start
  time or purchase details.

### Writer, reader, and pre-byte gate

The integration-contract RED run failed because the writer and reader files
did not exist and because the Share controller had no entitlement gate,
blocked state, localization, app URL, or action.

The GREEN implementation:

- encodes the projection to `EntitlementProjection.json` in
  `group.com.phillon.KnitNote`;
- uses `Data.write(..., options: .atomic)`;
- treats a missing file as first-use eligible, while an unavailable App Group,
  unreadable data, decode failure, unsupported schema, malformed projection,
  or expired trial fails closed;
- checks access before provider selection and before
  `PatternShareImportProviderSession.start()`;
- publishes prepared, refreshed, purchased, restored, deferred-transaction,
  and newly started trial snapshots through the coordinator callback.

App-hosted tests verify writer round-trip, authoritative preparation
publication, and trial-start publication before the triggering mutation
returns.

## Review fixes

The first independent review found no Critical issues and two Important
issues.

1. Share Extension URL opening is not guaranteed for this extension point, and
   the original completion handler left the blocked sheet open when the system
   returned `false`. The public-API best-effort request remains, but missing
   context closes immediately and every completion result now completes the
   extension. The localized retained-data text still tells the user to open
   KnitNote manually.
2. `RootView` inbox processing could race the app's initial entitlement
   preparation. A staged first-use item could therefore reach the mutation
   gate while the coordinator was still unprepared. New RED tests captured
   the ordering gap. `ensurePrepared()` now waits for the current
   single-flight preparation and reports whether preparation succeeded;
   scene-active inbox processing runs only after it returns `true`.

The second independent review found no remaining Critical or Important
issues.

## Localization and user flow

- English and Traditional Chinese explain that existing data remains safe and
  that KnitNote must be opened to continue.
- The blocked state shows a lock rather than loading or file-failure UI.
- The action uses the registered `knitnote://open` URL as a public-API
  best-effort request and always dismisses the extension callback path so the
  user is not trapped.
- When no projection exists, the Share Extension may stage the file. The main
  app remains authoritative: it prepares entitlement first, then inbox
  publication starts the first trial through the existing store mutation gate.

## Verification

| Command | Result |
| --- | --- |
| `swift test --filter EntitlementProjectionTests` | 6 tests passed |
| Share entitlement + inbox contract tests | 11 tests in 2 suites passed |
| Coordinator-focused app tests | 21 tests passed |
| `swift test` | 910 tests in 77 suites passed |
| Full `KnitNoteAppTests` | 28 tests / 30 executions passed |
| `KnitNoteShare` generic iOS Simulator build | passed |
| unsigned generic iOS Simulator build | passed |
| unsigned generic watchOS Simulator build | passed |
| unsigned generic macOS build | passed |
| independent re-review | no Critical or Important findings |

## Limitations

- Apple documents containing-app opening through `NSExtensionContext.open` for
  Today widgets, not Share Extensions. Task 6 therefore uses the only public
  best-effort URL request and a non-sticking fallback; it does not use private
  responder-chain or `UIApplication` workarounds. Physical-device acceptance
  must confirm the host-specific result.
- Projection writer construction and writes are best effort. An atomic write
  failure can leave the previous valid projection until a later successful
  entitlement publication. The authoritative main-app store gate still
  prevents unauthorized durable inbox publication.
