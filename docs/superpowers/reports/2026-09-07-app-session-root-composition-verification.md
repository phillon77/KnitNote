# App session root composition verification

狀態：本子計畫完成。實作、來源契約修正、獨立審查及第二輪固定候選四項完整驗證均通過。這不是送審、實機驗收或同步啟用證據。

版本維持 **1.7.0 (13)**；iOS 18 / macOS 15 / watchOS 11。

## Scope and candidate

- Plan: `docs/superpowers/plans/2026-09-07-app-session-root-composition.md`.
- Approved scope: existing owner integration and App session lifecycle specifications dated 2026-09-07 and 2026-09-06.
- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`.
- Branch: `docs/cross-device-sync-design`.
- Whole-subplan base: `73d574971fe9e885ac30b6ae2ca4f251d8f72240`.
- Task base: `c33d3bd570bf68097a548398bb3de8b405503e2e`.
- Implementation: `53fdc0b3f64c59e091e90db51e87cd82c6ba3cfb`.

Actual App now composes fixed session store/inbox/presenters/Watch resources through the existing owner, injects them under a production session-identity SwiftUI root, and selects screenshot mode before the lazy live local dependency factories. Shared entitlement, language and update environment remain outside the session boundary. Normal shipping still uses the existing non-sync local route; this does not establish verified legacy ownership or account readiness.

## Implementation evidence, not final acceptance

Controller read the implementer's full preserved report and the following result tails. Actual-source harness: `/tmp/knitnote-app-root-kbh3SM`; all production/test inputs use worktree symlinks. No actual App launch or real CloudKit/Keychain/Watch factories in tests.

| Check | Result | Log |
| --- | --- | --- |
| Combined owner/producer/native/composition/hosting tests | 73 tests / 7 suites, exit 0 | `/tmp/app-root-green-combined.log` |
| Affected source contracts, corrected run | 49 tests / 6 suites, exit 0 | `/tmp/app-root-green-contracts-02.log` |
| macOS unsigned build-for-testing preflight | exit 0 | `/tmp/app-root-macos-preflight.log` |
| iOS unsigned build preflight | exit 0 | `/tmp/app-root-ios-preflight.log` |

The first source-contract log `/tmp/app-root-green-contracts.log` is exit 1 despite its filename: one old assertion expected update injection directly after RootView. The corrected contract checks the shared outer session boundary and preserves normal/screenshot factory guards. It was rerun successfully. Each platform preflight has three AppIntents metadata-extraction warnings; these are not Swift compilation errors. No full Core run on this candidate has yet been claimed.

Actual NSHostingView tests verify shared identities across two windows, removal of A, state/selection/preview reset on coalesced A-to-B replacement, shared entitlement/language stability, and a retained A mutation closure rejecting writes while B remains unchanged. These test controlled content through the real production wrapper, not the complete product sheet UI or physical devices.

Runtime mutation REDs independently reproduced missing `.id` state leakage, mismatched backup presentation, and forbidden local factory construction in screenshot mode. Mutations were restored before GREEN. Fixtures directly stop and join real components/store before removing their exact temporary roots; retained harnesses/logs are evidence, not production data.

## Review and final validation gates

Task review `/tmp/app-root-composition-task-review.md` approved both compliance and quality for packaged `c33d3bd..53fdc0b`. Whole-subplan review `/tmp/app-root-composition-final-review.md` approved `73d5749..53fdc0b`; no Critical/Important findings or production fixes. Both reviews explicitly retain a non-blocking test-local timeout follow-up for the PDF notice event, and diagnostic disclosure including unsigned strip-bitcode noise in addition to AppIntents warnings.

First frozen full Core chain ended in unified session 93801, exit 1: 2520 tests / 186 suites, two issues, 1425.381 command seconds. `/tmp/app-root-frozen-core.log` preserves the failure. Combined/macOS/iOS steps never started. The two failed expectations referenced old App-local variable names in LanguageSelectionProjectionTests and ShareExtensionEntitlementContractTests; actual lazy-route writes remained present. This failed candidate was superseded by the reviewed correction below, not relabeled successful.

Validation correction is committed as `c70d53252bc21513a59f3f8ac94bba15f225aa5f`, changing only those two Core test files. Focused RED reproduced both failures (13 tests / 2 suites). Focused GREEN passed 14 tests / 2 suites, including a new screenshot-route check; expanded App-root contracts passed 111 tests / 11 suites, exit 0. Logs `/tmp/projection-contract-{red,green-focused,green-regression}.log` and preserved `projection-contract-fix-report.md` document commands and hashes. Independent scoped review `/tmp/app-root-projection-fix-review.md` confirmed both findings addressed without new Critical/Important issues.

## Final frozen validation

Session 14246 completed exit 0; no running validation remains. Frozen code/test candidate `c70d53252bc21513a59f3f8ac94bba15f225aa5f` was unchanged through all four serial commands. Controller verified an empty diff for Sources, KnitNote, Tests, PBX and project.yml; only completion documentation changed.

| Final check | Result | Command seconds | Log |
| --- | --- | --- | --- |
| Full Core | 2521 tests / 186 suites, exit 0 | 1433.403 | `/tmp/app-root-frozen-02-core.log` |
| Actual-source combined/hosting | 73 tests / 7 suites, exit 0 | 2.844 | `/tmp/app-root-frozen-02-combined.log` |
| macOS unsigned build-for-testing | TEST BUILD SUCCEEDED, exit 0 | 27.082 | `/tmp/app-root-frozen-02-macos.log` |
| iOS unsigned build | BUILD SUCCEEDED, exit 0 | 5.629 | `/tmp/app-root-frozen-02-ios.log` |

Commands used the inspected `/tmp/task4-run-bounded.py`: Core 3600s limit, others 900s. Combined used `swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel`; Core used worktree `swift test --no-parallel`, both through `arch -arm64`. Build destinations were macOS arm64 and generic iOS, `CODE_SIGNING_ALLOWED=NO`, existing isolated `/tmp/app-root-{macos,ios}-derived` caches. No App launch, signing, install or live services.

Final diagnostics: Core emitted three deliberate provenance mismatch messages and four missing-artifact negative cases with chained Python tracebacks; each enclosing rejection test passed. Combined had no compiler warnings. Final incremental builds had no warning/error matches; each retained two `Ignoring --strip-bitcode because --sign was not passed` messages. Earlier preflight AppIntents warnings remain disclosed above and are not rewritten away. The test-local PDF event timeout remains a reviewed, nonblocking follow-up.

Frozen source identities: Sources `e95550a541be26609812713062a5dfe0fc5dd166`; KnitNote/App `20e636b382539585e21a7103419472c810da5746`; Tests `c3d2af0029699f62ebf1e91e3782147b1b79fbf1`; PBX `f53ecc5c062fa0f122ca092b48b0f7c908eb9ce9`.

SHA-256:

```text
bd8e133090b74c643df65020098afac8f1ae844c70c37fa74ae69140ffe888f2  app-root-frozen-02-core.log
f9e0204516740c94c62921a6bb46ed421d2f6ab84c207e0bb097b02b10d0f421  app-root-frozen-02-combined.log
58094fc170169b24284f852473b1732802766c09629bdb1b7ba19291e7ae015c  app-root-frozen-02-macos.log
34b14f4a7c4bdfcba4267ebe0e71a370ab2de7fbab172236456d9dd30de86b12  app-root-frozen-02-ios.log
```

## Decisions made inside approved scope

The following decisions were made under the user's routine execution delegation. Worktree, branch and all SDD evidence are preserved for continuing account integration; no merge/push or cleanup is part of closing this slice.

1. Integrate typed resources, root and screenshot routing together while preserving existing local-only shipping behavior. If wrong, later account orchestration must be adapted to this seam rather than forked.
2. Preserve the lower-level resource initializer with optional presentation, but reject missing presentation at the production root. If wrong, a caller could construct a non-displayable bundle; the App uses the full factory.
3. Update PatternInbox source-contract checks to follow actual App delegation and production typed injection, retaining RootView behavior assertions. If wrong, weaker source checks could miss wiring regressions; real hosted identity tests and independent review remain required.
4. Likewise update backup and Watch source contracts for owner/current-bundle routing, retaining safety assertions. If wrong, stale presenter or Watch access could go undetected without the runtime and review checks.
5. Move the update source-contract expectation to the required shared outer environment while retaining screenshot/normal factory checks. If wrong, an accidental live update factory in screenshots could be missed; independent review inspects the conditional call sites.
6. Update the two language/entitlement projection source contracts revealed by full Core to follow renamed lazy-local dependencies, retaining actual construction/write placement and atomic/share safety assertions. If wrong, propagation could be missed by weakened tests; focused RED/GREEN and an independent fix review are required.

## Remaining release boundaries

Identity confirmation, concrete account lifecycle/readiness, bootstrap restart recovery, first-install remote preparation, status/settings/recovery UI, full localization, backup/Watch account integration and exact cloud/device acceptance remain separate unfinished work. Do not infer success from local fixtures or unsigned builds. No merge, push, signing/install, schema deployment, upload, submission or production-data cleanup was performed by this slice.
