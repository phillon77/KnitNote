# App session owner boundary — verified local slice

Candidate `44ae9cbf397d41846b697f23927b01055cccb71b`, worktree `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`, branch `docs/cross-device-sync-design`. Task review and final whole-slice review approved with no findings: `/tmp/app-owner-boundary-task-review.md`, `/tmp/app-owner-boundary-final-review.md`. Reviewed full slice `81941c7..44ae9cb`.

Implemented fixed store/producer resources, synchronous hide/revoke, generation-gated publication, Combine reentry reconciliation, retained identity-specific drains and independent cancellation-safe test cleanup. This is a local ownership boundary only: identity/readiness, full session presentation, App startup/UI and cloud/account transaction integration are not yet wired.

## Frozen verification

Controller serially ran the following against unchanged clean candidate, inspected final summaries and log hashes. No App host or live service was run. Commands use `/tmp/task4-run-bounded.py`; cache access required scoped escalation.

| Run | Result / command elapsed | Log SHA-256 |
| --- | --- | --- |
| Full Core | 2520 tests /186 suites, exit0 /1435.475s | `a6fd1d706193e2020ff5c2426ceb66de39d99e3fc595f379dfc317f6492bcb31` |
| Actual-source combined | 64 tests /5 suites, exit0 /2.358s | `97df97e70c4bbc755d6bf1219674153026a4e5c84eb580a7bea0eb2966761818` |
| macOS unsigned build-for-testing | success, exit0 /12.329s | `35d21db58c8c141530d671db5d4fe297df820c6a9c3d8121c5c026f15603733c` |
| iOS unsigned build | success, exit0 /50.665s | `874ecf82b30b87eb3efe0aa1bbfe1423db4a8e08d2fdc66ba956b6cfeb4916ef` |

Logs `/tmp/app-owner-boundary-frozen-core.log`, `/tmp/app-owner-boundary-frozen-combined.log`, `/tmp/app-owner-boundary-frozen-macos.log`, `/tmp/app-owner-boundary-frozen-ios.log`, respectively.

```sh
# worktree
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
# /tmp/knitnote-app-owner-7xxHpr
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel
# worktree
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/app-owner-boundary-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/app-owner-boundary-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Core diagnostic output includes three intentional provenance mismatches and four missing archive/Info.plist negative-test chained tracebacks; the enclosing tests passed. These correspond to `ReleaseAuditLocalizationTests.swift:1194` and adjacent provenance negative tests. No test failure or CGPDF diagnostic observed. Combined and final incremental macOS log have no compiler warning/error; iOS has three AppIntents metadata-extraction-skipped warnings, no compiler errors. Earlier macOS preflight also passed,69.040s with three such warnings; it is not substituted for frozen results.

Harness `/tmp/knitnote-app-owner-7xxHpr` compiles actual Core/App/test symlinks, including14 owner tests plus50 producer/native tests, not copies or every Xcode test. Exact manifest,21-link inventory, test names, four runtime RED mechanisms and independent teardown proof are retained in `.superpowers/sdd/2026-09-07-app-session-owner-boundary/task-1-report.md`. Broken owner drain was never the sole fixture cleanup proof; actual producers/stores were directly joined before root deletion. Both reviews inspected this evidence.

Frozen trees: Sources `e95550a541be26609812713062a5dfe0fc5dd166`; KnitNote/App `a18a9e450a9ca5f0fad74029a767dbdbf382b2c5`; Tests `3f88da3cb9fbf2774ae0ed594ca2103e8028fabd`; PBX `db2eacb78c9cac64007afc5e51d7a1aa2b03aa9b`. Version readback1.7.0(13),iOS18/macOS15/watchOS11. Final documentation commit must leave tested source/test/PBX unchanged.

## Decisions and continuation

- First prove local owner boundary before full assembly; cost if wrong: extra integration seam/review cycle, not whole4A completion.
- Keep local publication explicitly non-authoritative for account readiness; cost if wrong: future callers might misuse it, requiring renewed boundary review when wired.
- Use one implementer plus independent reviews and preserve worktree/evidence; cost if wrong: small retained scratch and review overhead.

Keep branch and evidence; no deletion, merge, push, sign, install, upload, schema deployment, submission or production cleanup. Latest user delegation authorizes routine continued work toward release preparation, not arbitrary candidate publication. Existing heartbeat is ACTIVE; do not pause at this slice. Next consume these primitives in approved full session/presentation composition, identity and lifecycle/readiness integration, generation UI/root startup wiring, then product UI/localization and candidate/device release gates. Do not redispatch this completed owner boundary plan.
