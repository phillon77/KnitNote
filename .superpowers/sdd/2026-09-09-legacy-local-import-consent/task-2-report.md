# Task 2 implementation report: one-shot legacy import confirmation

## Result

- Implemented `LegacyLocalImportObservation` and `@MainActor LegacyLocalImportConsentModel` as internal, in-memory-only model code.
- Added six Swift Testing cases covering one-shot confirmation, proposal identity/ownership, all seven bindings, blocked/malformed input, replacement/reopen, and invalid presentation revocation.
- Added only the required `Equatable` conformance to `LegacyLocalImportSource` from Task 1.
- Implementation commit: `90208641571486fc28da98e8b5431ef089ce54ba` (`feat: model one-shot legacy import confirmation`).

## TDD evidence

- Environment-only attempt: `swift test --disable-xctest --disable-sandbox --no-parallel --filter LegacyLocalImport` failed before compilation because the sandbox denied `/Users/longzhenzhong/.cache/clang/ModuleCache`; log: `/tmp/knitnote-legacy-consent-red.cZpEjn/output.log`. This was not counted as RED.
- RED: `env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-legacy-consent-cache.GLUBwo/clang-cache swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-legacy-consent-cache.GLUBwo/cache --config-path /tmp/knitnote-legacy-consent-cache.GLUBwo/config --security-path /tmp/knitnote-legacy-consent-cache.GLUBwo/security --no-parallel --filter LegacyLocalImport`; exit 1 with expected missing `LegacyLocalImportObservation`/`LegacyLocalImportConsentModel` symbols; log: `/tmp/knitnote-legacy-consent-red.WBd6gM/output.log`.
- GREEN: `env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter LegacyLocalImport`; exit 0, 7 tests in 2 suites; log: `/tmp/knitnote-legacy-consent-green.ZCJuO2/output.log`.

## Regression and review

- Related regression command used the same bounded runner/cache with filter `LegacyLocalImport|SyncAccountSourceStateTests|JSONProjectStoreSessionAdmissionTests`; exit 0, 30 tests in 4 suites; log: `/tmp/knitnote-legacy-consent-regression.yzG73p/output.log`.
- `git diff --check` passed before commit. `rg -n 'LegacyLocalImport' Sources Tests KnitNote KnitNoteWatch` found only the policy/model/test slice and the existing policy test; no formal entry call.
- Self-review against spec §8 and the four-file diff found no behavior or scope defects: stale proposals cannot confirm or clear replacements; malformed presentation revokes the old proposal; invalidation cannot be revived with the old observation.
- Task 1 review minor evidence carried forward: repeated pre-existing `HighlightOverlayContractTests.swift:92` deprecation warnings remain; the duplicate GREEN2 invocation waited on SwiftPM's package lock and passed. No unrelated source/test repair was made, and logs are not claimed pristine.

## Explicit non-claims

This slice has no real source authentication, no installer/admission authority, no disk encoding or persistence, no crash-recovery implementation, no Watch wiring, no App startup/factory integration, and no formal enablement.

## Baseline and dirty preservation

Baseline before Task 2 was `6fdc316389716a1eb45f4ee966c3ba540182f6f6`. Pre-existing unrelated dirty/untracked paths preserved: `docs/superpowers/specs/2026-09-09-legacy-local-import-safety-design.md`, `.superpowers/absent-source-design-progress.md`, `docs/superpowers/plans/2026-09-09-legacy-local-import-consent.md`, and the four pre-existing reports under `docs/superpowers/reports/`.
