# App account domain installation verification

Status: **COMPLETE for this local installation/readiness subplan. Not cloud/device/release acceptance.**

Candidate: `2d44fa42e928a39741c4d640ae82fe2391b9a6b8`, branch `docs/cross-device-sync-design`, version 1.7.0 (13). Production last changed at `48b6e4df268ac29f9a278aea8c8ef8d1484dd468`; the candidate adds an independently reviewed offline test-fixture repair only.

Plan: `docs/superpowers/plans/2026-09-07-app-account-domain-installation.md`. Detailed task commands, RED/GREEN evidence, rulings and review packages: `.superpowers/sdd/2026-09-07-app-account-domain-installation/`.

## Implemented and reviewed scope

Actual App account factory, owner-issued exact attachment sources, Core-selected canonical activation, actual durable remote committer, concrete owner lifecycle, shared transport/incoming/asset authorities, local readiness separate from cloud completion, recoverable retry, and retained transport cancellation joins. Shipping cloud route remains disabled.

Task1 `c00a3af`, Task2 `92d4fd4`, blocking review repair `48b6e4d`, offline fixture repair `2d44fa4` were independently reviewed. Whole-plan review `/tmp/app-account-domain-final-review.md` approved frozen validation with no Critical/Important findings. Scoped repair review `/tmp/app-account-offline-fixture-review.md` accepted the fixture repair. Neither review replaces pending full execution below.

## Frozen validation

Completed serial command session: `73246`, replacement frozen03, exit0. Commands are recorded in `frozen-validation-notes.md` plus the corrective progress ledger. App harnesses use explicit `KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0`; Core unsets that variable because production audit deliberately rejects every KNITNOTE_ override and Core package contains no live App tests. Isolated temporary roots, controlled drivers, unsigned builds, no live App launch. Each command started only after previous exit0.

| Check | Current evidence | Log |
| --- | --- | --- |
| Actual-source account App | 203 tests/10 suites,40.087s; exit0,41.417s | `/tmp/app-account-domain-frozen-03-app.log` |
| Full Core | 2532 tests/186 suites,1359.826s; exit0,1361.584s | `/tmp/app-account-domain-frozen-03-core.log` |
| Actual-source root/hosting | 73 tests/7 suites,0.725s; exit0,11.496s | `/tmp/app-account-domain-frozen-03-root.log` |
| macOS unsigned build-for-testing | TEST BUILD SUCCEEDED; exit0,43.679s | `/tmp/app-account-domain-frozen-03-macos.log` |
| iOS unsigned build | BUILD SUCCEEDED; exit0,41.786s | `/tmp/app-account-domain-frozen-03-ios.log` |

Frozen source trees: Sources `0262fb7568a3af485242c69dd451ddfd1ea38704`; App `d3a7b13bcbac66da392142ca0ec8892f22fad168`; Tests `9f2e90fbd297cc2d144def64458e74936e00428f`; PBX `63c90bb523c2a0422c909182b22bab13fe1c76c7`. These match final HEAD; production/test/PBX/project.yml diff empty after validation. Only this report and controller plan changed.

Final SHA256 (App/Core/root/macOS/iOS respectively):

```text
0cffa7751e92e2e5419c4f19a163f12d502dcd49bcb50e8b194a3d67a54f65c8
0266be7fdb8ce5213f1d09c9bbcd38690ae47cba7df42b7829c78024080fa33e
f2c61d5f5f3f1d64d0cd2d0bb06e7441e97606b6111b2cee4ea94c56964ee5f2
5c7bb1abefa2a008c8c943ff215b815082bc6b43ca53bef746c1df05b9a25800
e7a2e12926dfd11939e8ee4da007014e6d06e736aa9d74ed8a75d3e418ee8a12
```

Final diagnostics: no test failure/error/timeout markers. One App live-development test intentionally skipped (not live coverage). Three AppIntents metadata extraction warnings per platform build because no AppIntents.framework dependency; no corresponding build failure. macOS is build-for-testing only, not hosted test execution or UI/device acceptance.

First chain `74273` failed in the account harness, and never started later checks. `/tmp/app-account-domain-frozen-app.log` is preserved, not a passing result. Offline composed roundtrip lacked container identity, so verified account admission rejected it and no committed file existed. Test-only repair injects matching test.container and joins actual coordinator/transport teardown; original persistence, attachment and restart assertions remain. Production identity checks were not weakened.

Second chain `79901` passed App but Core2532/186 finished with6 issues in3 audit tests, exit1. The controller's global `KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0` conflicted with production audit's intentional rejection of all KNITNOTE_ overrides. No later stage ran. Unsetting that variable in Core alone passed the exact3 tests/2 suites1.842s, runner exit0 at `/tmp/app-account-domain-core-env-diagnostic-02.log` (89189). First sandbox diagnostic41576 failed before tests on Swift cache permission; preserved separately. No production/test edits or weakened audit. Full frozen03 above supersedes this failure without deleting evidence.

## Controller rulings and costs if wrong

1. Factory and lifecycle share one final full chain after focused task reviews. Cost: interface rework if task boundaries were mistaken; no test coverage reduction.
2. Attachment locators stay in existing owners; Core selects the canonical candidate. Cost: narrow internal seam rework, never App private-path inference or publication selection.
3. Advanced canonical reopen skips stale initial bootstrap handoff. Cost: ordinary edited accounts could otherwise be locked out; actual daily-edit/reopen regressions required.
4. Legacy test adapters default localAccessReady false; concrete activation alone can return true. Cost: unintended access or lockout; real transport receipt remains separate.
5. Split corrupt metadata from nonterminal phase and require captured generation validation without production no-op. Cost: error compatibility or stale publication if wrong; both corruption and generation cases tested.
6. Retry retains initial replay mode and receipt callback. Cost: permanent send gate or false readiness if either is lost; real receipt/send regression required.
7. Sealed-and-cleaned A→B→A proves recovered pending/source and hidden bootstrap-required, not reconstructed canonical availability. Cost: roundtrip remains a release blocker until actual remote reconstruction, rather than inventing a local archive.
8. Full App runs before long Core. Cost: ordering only; all five checks remain mandatory.
9. Read-only canonical probe avoids mkdir/fsync before unresolved rollback recovery. Cost: unsafe evidence could be mistaken for absence; activation stays authoritative and temporary-file follow-up remains explicit below.
10. Selected-photo success fixture includes valid project/counter/photo projection; malformed attachment-only input separately rejects. Cost: false supported-shape claims without actual downloaded-byte/receipt assertions.
11. Repeated invalidation/stream termination retains the original transport cancellation task and joins it before inventory/cleanup/close/retry completion. Cost: premature cleanup or ownership cycle; suspended cancellation and overlap regressions required.
12. Defer final-review Minor1, not an identified readiness bypass: structural probe and actual selected-candidate activation have distinct authority. Cost: routing confusion; four temporary-state cases must be covered in next integration.
13. Fix the offline fixture's identity and cleanup only. Cost: incorrect test evidence if real assertions were removed; scoped review retained all durable assertions and final full App now passes.
14. Scope live opt-out to App harnesses, unset the variable for Core's production-audit tests. Cost: unexpected live scope or weakened audit; verified Core package excludes live App tests, App gate requires explicit1, and actual audit rejects any KNITNOTE_ variable. Exact failing tests now pass without code edits.

## Required follow-on and release gates

- Minor1: document/test valid temporary-only, exact-current temporary, unrelated valid same-account temporary, and legitimate interrupted daily candidate. Do not blanket-reject legitimate Core recovery or turn probe nil into readiness.
- Separate unexecuted live development helper also omits container identity. Bind correct actual identity before opting into later authorized live acceptance; offline identity is not real authority.
- System identity and serialized startup: use actual tri-state evidence, invalidate synchronously, coalesce queries, join transitions. Partial transition errors may leave a different retained account; caller must not use only last successful UI binding. Read `/tmp/account-identity-startup-exact-map-20260908.md`.
- Real remote bootstrap: installation currently precedes transport creation; current Core prepare requires an existing archive; bootstrap receipt does not bind consumed incoming batch identities. Resolve those concrete seams, full versus delta authority, hard deletes, assets and crash-safe ACK before claiming a cleaned returning account is usable. Read `/tmp/account-remote-bootstrap-exact-map-20260908.md` and `next-bootstrap-routing-notes.md`.
- Complete applicable product UI/localization, backup/Watch isolation, actual cloud/device acceptance and release contracts. Existing local tests and unsigned builds are not those results.
- No live account/Keychain, signing/install, schema deployment, merge/push, upload or submission performed. Exact candidate release gates remain. Preserve all worktrees and evidence.
