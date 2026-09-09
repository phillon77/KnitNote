# Owned receipt / commit crash verification

Date: 2026-09-10. Status: bounded prerequisite complete; implementation, task/final review, focused/combined regression and fresh root checks passed. Full V4 import integration and release remain incomplete.

Plan: `../plans/2026-09-10-owned-commit-crash-boundary.md`.
Spec: `../specs/2026-09-10-legacy-import-durable-transaction-design.md`, section 10.
Architecture audit: `2026-09-10-legacy-durable-import-architecture-audit.md`.

## Scope and baseline

Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
Branch: `docs/cross-device-sync-design`.
Source baseline: `378478c4dc1387ef63320db621f67c6f5a43a49a`.
Initial spec/plan commit: `75893228f82eefdcf29fff9d94c1b46e8d60563a`.
Native document clarifications: `9847cd5` (no production changes).

Root ran the following baseline, with real-cloud flag removed:

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/knitnote-legacy-final-iHUGGh/run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'SyncBootstrapOwnedTransactionTests'
```

Result: 42 tests / 1 suite passed, 255.691 s test duration, EXIT 0, 258.218 s bounded command elapsed. The source remained unchanged; documentation-only commits during the run did not alter test inputs. This baseline predates the new test file and cannot verify it.

## Verification acceptance

Required evidence: real child termination at receipt-before-committed and commit-before-handoff; native phase checked before recovery; nonempty project and journal; two same-root reopens with stable mutation IDs/order; invalid receipt rejection preserving damaged evidence; negative phase-oracle control; task/final review; root fresh final run.

Focused results read by root from the implementer's logs:

- Negative control `/tmp/owned-commit-negative-control.log`: deliberately inverted installed/committed phase expectations produced exactly two expected failures; EXIT 1, 15.209 s test / 41.453 s bounded command. This is test-oracle sensitivity, not a production defect or fix.
- Restored `/tmp/owned-commit-green-focused.log`: 3 test functions passed, EXIT 0, 16.049 s test / 40.527 s bounded command. Two real crash cases and four damaged-receipt cases; the third test function is the worker, a no-op in the parent run. Do not count that worker as an extra safety scenario.
- Corrupt, missing, wrong-account and wrong-transaction receipt cases report native rejection with damaged evidence unchanged.

Combined regression `/tmp/owned-commit-green-combined.log`: same bounded command with filter `SyncBootstrapOwnedCommitCrashTests|SyncBootstrapOwnedTransactionTests|SyncBootstrapOwnedHandoffTests|SyncBootstrapOwnedInterruptionMatrixTests`. Root read final output: 52 tests / 4 suites passed, 562.514 s test, EXIT 0, 586.2 s bounded command. This includes the unchanged 42-test native transaction suite; it is not 52 newly implemented tests.

Source/test candidate: `1c9a1e4e666e9063bdf77722c0549cd29b508997`, containing only the new 394-line test suite. Root verified no production/project diff from 378478c4 and a clean `git diff --check`.

Fresh root run on this committed SHA used the focused command above: 3 test functions / 1 suite passed, EXIT 0, 15.869 s test / 18.597 s bounded command. Log `/tmp/owned-commit-root-final-1c9a1e4.log` records both cuts with childExit=86, sameRootTwice=yes, nonempty before/installed files, and all four receipt damage cases rejected as SyncBootstrapError.corrupt with evidenceUnchanged=yes. This is six behavioral cases plus a worker entry, not seven independent safety cases.

Independent task review: spec compliant and quality Approved, no Critical/Important findings. Exact version/floors were rechecked by root from the unchanged project file. One Minor: successful fixture cleanup is best-effort `try?`, so a cleanup failure may silently leave temporary files. This does not alter native recovery assertions; the implementer's contrary report wording was corrected.

Final independent review of `378478c4..014c559`: Approved to keep locally, no Critical/Important findings. Reviewer checked complete candidate diff/spec/plan/reports/ledger, native paths and fixture, and verified evidence hashes. The cleanup diagnostic remains an accepted deferred Minor, not a source/data-recovery defect. No additional tests were rerun by the reviewers. Final documentation status/checklist updates do not change the tested source candidate.

## Evidence hashes

- Test file SHA-256: `b0201e478d07abe8c7bbbacb0626290be9aa0f144a11ff336788b9bccc0e3184`.
- Negative-control log SHA-256: `2f9832a50652426c4b6fcc7932f040c696e56b3033fbbb2fe000bf361079ada7`.
- Focused implementer log SHA-256: `0d2e70ecb592fc982adbb1315e4abc6b8ff410777744ab4fc516aab5c01b83b8`.
- Combined log SHA-256: `d8ae2221527a155a33db3bba9d5c19ee0fbd5d961566835244b2a93f17bf4763`.
- Fresh root log SHA-256: `1af1a5a428e6ac05d5654dbc7d01423f13c11283ad0fb0c6de120e95f6344f21`.

No warnings/errors appeared in the combined and root incremental logs. This is not a clean-build warning audit or full repository test result. The suite attempts best-effort cleanup of successful test-only roots/logs; failed negative-control roots/logs are retained. No user data was deleted.

## Delegated decisions

1. Proceed through section/spec/plan routine approvals under the user's explicit 「你來決行」. Cost if wrong: local documentation/test revision, no release side effects.
2. Design V4 with required import binding and native-retained LegacyBackup rather than optional V3 binding. Cost if wrong: format-design rework before any new format is emitted.
3. Execute the native receipt/commit prerequisite first; do not substitute a caller-constructible adapter for the missing legacy native issuer. Cost if wrong: additional test time; full V4 integration remains unfinished.
4. Scope final review to this plan's candidate rather than claiming a full historical branch/release audit. Keep ledger/worktree evidence. Cost if wrong: full branch review still required and small local disk retention.

## Release boundary

Version remains 1.7.0 (13), iOS 18 / macOS 15 / watchOS 11. No new authority, V4 issuer, native import installation, App/Watch/Share activation, real CloudKit/Keychain, schema mutation, merge/push, signed export, upload, submission or automation change is established. Original unrelated untracked files remain untouched.

Next implementation work is the cohesive native V4/legacy source-lease/retained-backup/readers plan described by the architecture audit. This completed test prerequisite must not be reopened as if it were unfinished or presented as completion of that integration.
