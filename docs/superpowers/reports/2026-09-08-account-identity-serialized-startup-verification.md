# Account identity and serialized startup verification

Status: **COMPLETE for the injectable identity/controller subplan. Not remote-bootstrap, shipping, live account/device or release acceptance.**

Version1.7.0(13), branch `docs/cross-device-sync-design`. Baseline `dbb3d73b866425da994d99014f7fcaf0fd5da424`; frozen code candidate `1d7563dd9f67f9406a27db7b80ff57d2697b9e6e`.

Plan: `docs/superpowers/plans/2026-09-08-account-identity-serialized-startup.md`. Task evidence and exact amended requirements remain in `.superpowers/sdd/2026-09-08-account-identity-serialized-startup/` (preserved by user instruction).

## Implementation and independent review

- `ae3f5aa`: SDK-backed tri-state identity query; unknown never means logout, no cached binding or live factory invocation. Focused9/1 passed; independent task review approved.
- `7ae0d80`: one serialized App pump, actual retained-account reconcile/reopen, local versus cloud readiness, generation/reentrant projection and exact observed-redelivery receipt repair. Initial175/8 passed; task review identified two Important gaps.
- `1d7563d`: post-callout generation/stopped guards and actual startup/event-work joins. Controlled resolver/startup/manual fetch suspension, source-join mutation RED and final181/8 pass. Scoped review addressed both findings, no new breakage.
- Final whole-subplan review `/tmp/account-identity-final-review.md` approved frozen local validation with no new Critical/Important/Minor, retaining the explicit deferred items below. Reports `/tmp/account-identity-query-task-review.md`, `/tmp/account-serialized-controller-task-review.md`, `/tmp/account-controller-fix1-review.md` preserved.

## Frozen execution

One serial chain session74711, DONE exit0. App and root harness explicitly set `KNITNOTE_RUN_CLOUDKIT_INTEGRATION=0`. Core explicitly unsets it because production audit rejects every KNITNOTE_ override and Core package excludes live App tests. All next commands ran only after previous exit0. No App launch, live query, signing/install or publication.

| Check | Result | Log SHA256 |
| --- | --- | --- |
| Actual-source account App | 241 tests/12 suites,51.318s; runner exit0,52.984s | `818e477cd76f26cc92161da59ed0b2844f8e50262ca0b6238a9adf1f8ca92fa5` |
| Full Core | 2532 tests/186 suites,1348.325s; exit0,1350.716s | `cce5a6e8e0dc96b9703749fb4703a3a5d4872ee62c5cf80d18fa949ee3f108f9` |
| Actual-source root/hosting | 73 tests/7 suites,0.688s; exit0,1.901s | `c8eb8dfa43fe89358e0126634f2db0b0a7daecf64f40c6f5475ad1f28c161138` |
| macOS unsigned build-for-testing | TEST BUILD SUCCEEDED; exit0,38.829s | `5d969c0eec72f3481fb5976fe077000d6a7226fe33865175a99b3285825b52c2` |
| iOS unsigned build | BUILD SUCCEEDED; exit0,40.564s | `fd87a880f158f33c1c49d1b31107f0c9f37e859e0a2539c2d2ffdffa5c9c74bd` |

Logs: `/tmp/account-identity-frozen-01-{app,core,root,macos,ios}.log`. Derived roots `/tmp/account-identity-{macos,ios}-01-derived`. One App live-development test intentionally skipped, not live coverage. Three AppIntents metadata extraction warnings per platform because no AppIntents.framework dependency; no test failure/error/timeout diagnostics. macOS build-for-testing is not hosted test execution.

Exact command bodies, each wrapped by `python3 /tmp/task4-run-bounded.py` with bounds900/3600/900/900/900seconds:

```sh
swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --package-path /tmp/knitnote-account-domain-jnjVrd --no-parallel
arch -arm64 swift test --no-parallel
arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/account-identity-macos-01-derived CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/account-identity-ios-01-derived CODE_SIGNING_ALLOWED=NO build
```

Account harness also sets `CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache`. Standard cache/build scoped escalation approved. Runner bounded process-group timeout is not an arbitrary test timeout increase.

Frozen trees verified unchanged after completion: Sources `0262fb7568a3af485242c69dd451ddfd1ea38704`; App `78721554b1f8c32862824939dc7ec2e986fded90`; Tests `3b392d6052fe1146050267a02e48100b6a295645`; PBX `534acbdd575b5e8093a1a277f519645149b66352`. Production/test/PBX/project.yml diff empty. All shipping targets remain1.7.0(13).

Account Package SHA256 `be651083b0427f1d2067dbc2b4fe0e6f1248d46211ff0d125baf7ef7d3c3f04b`; actual-source manifest `537c8219ca4bab4b5df11b49dc2b8a6ff3a9dc289e9b0673cf1c8b7b805f2fe4`; root Package `9d80d3ca53ffbb96203f5cb590a54dac7a095a102d5bba3148afa4eb828e89eb`; bounded runner `c9fbdb35fa3743e27a7fbf63a1a0cbabfb02ca10e299167c214841a915faec0b`.

## Rulings and costs if wrong

1. Stateless SDK adapter then actual serialized controller, one full validation after both reviews. Cost: interface rework if boundaries wrong; never inferred identity.
2. Keep shipping/native notifications unactivated; explicit synchronous accountDidChange is the tested entry. Cost: later live composition still required, not complete shipping sync.
3. Same-account reconcile reuses retained storage and destination recovery rather than sealing A→A. Cost: helper/recovery rework; actual no-vault, journal-identity and partial-failure tests enforce this.
4. Add coordinator stop/join/status seams for idle teardown and local readiness before fetch completion. Cost: callback reentry or premature freeze; observer and suspended-drain tests required.
5. Fresh runtime generation guards every callback on reused Session. Cost: old closures could regain authority; actual replaced-runtime tests check it.
6. Current-fetch membership includes fully observed durable redelivery without new envelope, but commitment requires exact current account/zone ACK verification; partial observations remain gated. Cost: false receipt or permanent gate; empty/populated/partial/frontier/invalid-proof and epoch tests required. No incoming/Core format or ACK weakening.
7. Join actual sync startup/event work before replacement/freeze/cleanup, not merely transition continuation/driver cancellation. Cost: self-join deadlock or hidden task; callbacks only initiate stop and external owner joins. Actual pre-admission resolver, initial/manual fetch and source-join mutation tests required.

## Failures preserved, not erased

Task2 original RED exposed same-account sealing, receipt omission, nested state overwrite and canceled waiter/nested generation bugs. Fix1 RED reproduced both independent review findings. Final affected attempts before03 included a fixture deadlock: an existing test awaited true cancellation completion before releasing its blocked fetch. It now asserts pending, releases fetch, then awaits completion. Query probe polling was aligned to MainActor scheduling without increasing retry count/delay. Compile mistakes/intermediate warnings are recorded and resolved. Exact isolated test helper27402 was terminated after verified PID/parent/group; its runner46747 reaped exit1, no data roots deleted to conceal failure. Full appendix has commands/hashes and every completed session. Only final181/8 then frozen241/12 are success evidence.

## Immediate next integration and retained gates

- Implement real first-remote preparation/reconstruction: transport currently follows domain install; Core prepare needs an archive; bootstrap receipt lacks exact consumed-batch binding. Use `/tmp/account-remote-bootstrap-exact-map-20260908.md`, recheck current code and resolve complete-versus-delta fetch, pending/attachments, install and crash-safe ACK under existing authority. Missing canonical remains bootstrapRequired; no empty visible replacement or fake receipt.
- Canonical-probe temporary-routing Minor1 remains nonblocking here but required next: valid temporary-only, exact-current, unrelated valid same-account temporary and legitimate interrupted daily candidate. Actual activation remains authoritative; do not blanket-reject valid recovery.
- Separate live helper still omits container identity. Bind actual queried identity before authorized live acceptance, never the offline test identifier or availability Boolean.
- Native notification/shipping composition, product UI/localization, backup/Watch, actual cloud/device, privacy/schema/store and exact-candidate release gates remain incomplete. No push/upload/submission/merge performed. Preserve worktrees and all evidence.
