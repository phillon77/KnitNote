# Task 4 Report — Immutable Asset Staging Filesystem Authority

## Scope

This review fix is based on `cbfe663466a45534d63b33e6481bf402e41b225f` and changes only the local immutable-asset staging service and its app tests. It does not add or exercise live CloudKit transport, change a version/build, push a branch, submit a build, or claim physical-device acceptance.

## RED

- Manifest publication tests initially did not compile because there was no deterministic boundary after manifest load and no boundary before a coordinated operation returned.
- The legacy-retirement stress test left all 1,024 zero-byte retirement markers in place after restart reconciliation, proving the retired directory and each later scan were unbounded.
- The first-manifest post-publication substitution test left injected bytes at the authoritative manifest path. A retry therefore started from a knowingly corrupt authority instead of a recoverable canonical manifest.
- The new cleanup test supplied a prefix/suffix-matching but noncanonical UUID tombstone while durable acknowledgement intent existed. The old suffix-only discovery path accepted that namespace instead of rejecting it before clearing intent.

## GREEN

### Bounded retirement authority

- Retirement reuses at most one verified zero-byte marker per retirement kind (`asset`, `manifest`, and `quarantine`). The active pathname is moved over that verified slot atomically while the service holds the verified account-directory and advisory locks; the descriptor-bound payload is then truncated and synchronized.
- Restart reconciliation validates and compacts legacy zero-byte markers to one per kind, then future operations scan only the bounded live retirement set.
- A sustained regression performs 2,048 stage/ack cycles with repeated manifest publication/replacement and verifies no more than three retirement entries (and therefore no more than three reachable retirement inodes) before and after restart. A separate restart regression begins with 1,024 legacy markers and verifies one survivor.

### Manifest publication CAS and recovery

- Loading a manifest now records its inode, byte count, SHA-256, and canonical bytes. Every publication revalidates that authority before staging, immediately before publication, and after the testable identity boundary.
- A displaced manifest is opened without following links and must still match the loaded inode and content version before it can be retired.
- Failed post-swap publication moves the candidate and any substituted entries to distinct `.preserved` names, then durably reinstalls the exact previously loaded canonical bytes. Nothing at a substituted pathname is truncated.
- For the first manifest, a synchronized canonical candidate is durably reinstalled after a post-publication substitution. The failing call still reports the authority violation; an exact-version retry can recover idempotently.

### Account-tree binding

- The root pathname and every descriptor-resolved parent/child edge (`Accounts`, account token, `Uploads`, `Installed`, `Quarantine`, and `Retired`) are identity-checked after opening, after locking, and immediately before a coordinated result returns.
- Renaming/replacing the account directory at the return boundary makes the call fail closed. The regression verifies bytes exist only in the displaced locked tree and no URL for the replacement tree is returned.

### Exact cleanup grammar

- Cleanup recovery accepts only `.<exact immutable asset name>.<lowercase canonical UUID>.cleanup`.
- A malformed matching entry makes reconciliation fail closed; both matching byte copies and the checksummed cleanup intent remain unchanged.

### Cleanup

- Removed the unused `retiredRootURL` stored property.
- Replaced the prior unrelated, stale Task 4 report with this bounded statement of the current asset-staging work.

## Files

- `KnitNote/CloudSync/CloudAssetStagingService.swift`
- `Tests/KnitNoteAppTests/CloudAssetStagingServiceTests.swift`
- `task-4-report.md`

## Verification

- Focused app staging and descriptor-reader tests: 50/50 passed on macOS.
- Relevant Core attachment, backup, pattern, and yarn-photo slice: 163 tests in 4 suites passed.
- Full Core regression: 2,047 tests in 155 suites passed.
- Generic iOS build with code signing disabled: passed.
- `git diff --check`: passed before final verification and will be rerun immediately before commit.
- Static search finds no remaining `retiredRootURL` or `restoreCapturedFile` references.

The first in-sandbox `swift test` attempt could not initialize SwiftPM's nested sandbox. The same command was rerun outside that sandbox with isolated module and scratch caches; both relevant and full Core suites passed. Pre-existing warnings in unrelated Core tests remain unchanged.

## Remaining boundaries

- `.preserved` artifacts are intentional evidence/recovery material for adversarial namespace substitution and are not automatically deleted. They can grow only when a publication is actively displaced or substituted, not during normal staging, acknowledgement, manifest replacement, or restart reconciliation.
- These are deterministic local filesystem and generic-build checks. Live CloudKit development-container integration, network behavior, and physical-device acceptance were not run in this correction pass.
