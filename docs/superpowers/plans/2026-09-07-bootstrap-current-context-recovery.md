# Bootstrap Current-Context Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the forthcoming App account installer recover an interrupted bootstrap and obtain its committed canonical handoff under newly verified account ownership and freeze after process restart.

**Architecture:** Extend the existing Core bootstrap transaction with one narrow recovery entry point; retain its private manifest/preparation/handoff authority and rollback semantics. Normal transaction methods continue to require exact context equality. A historical same-account transaction may be read only through this explicit recovery path, with every operation and retained handoff still guarded by the caller's current context validator. No App-owned manifest decoding or replacement recovery transaction.

**Tech Stack:** Swift 6, existing Core bootstrap/canonical/account storage, Swift Testing, temporary filesystem fixtures.

**Spec:** `docs/superpowers/specs/2026-09-07-app-session-owner-integration-design.md` and `docs/superpowers/specs/2026-09-06-cloud-sync-app-session-lifecycle-design.md`. This is the concrete restart-authority gap identified in `/tmp/app-account-install-mapping.md`, prerequisite to the App domain installer, not a new product policy.

## Global Constraints

- 維持1.7.0(13)，iOS18/macOS15/watchOS11；不改100,000,000-byte與64MiB上限、資料/wire格式、購買、語言偏好、開發故事或30天復原條件。
- Preserve bootstrap version-1 envelope/manifest/receipt formats, Original inventory, pending journal absolute source authority and canonical revalidation. No new cleanup, migration, journal, or recovery authority.
- New epoch/freeze is valid only through the real caller-owned validator. Cached account, an existing folder or a matching hash alone is not current ownership. No empty production validation closure.
- Tests use explicit temporary roots and actual Core transactions/stores; no live App, CloudKit, Keychain, Watch, production-data operations, signing/install/merge/push/upload/submission.
- Existing App owner/root/producer work is complete and preserved. Account installer/identity/first remote fetch/legacy provenance remain unfinished; this API alone grants no local-ready or cloud-ready status.

### Task 1: Recover existing bootstrap with current ownership

**Files:**
- Modify `Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift`.
- Modify `Tests/KnitNoteCoreTests/SyncBootstrapTransactionTests.swift` for access to its private real fixture and fault-boundary matrix; create `Tests/KnitNoteCoreTests/SyncBootstrapCurrentContextRecoveryTests.swift` only if a separate self-contained fixture is materially clearer, not by copying a large fixture verbatim.
- Modify `Tests/KnitNoteCoreTests/JSONProjectStoreCanonicalDurabilityTests.swift` only for one real activation/reopen integration regression if the existing fixture makes this smaller than a new file.

**Interfaces:**
- Consumes existing `SyncBootstrapTransaction(liveRoot:context:journalRelativePath:patternFolderNameContext:validateContext:)`, `recoverInterruptedInstallation()`, `canonicalHandoff(_:)`, private manifest/preparation and `SyncCanonicalCheckpointStore` activation validation.
- Produces one public synchronous method on the current-context transaction:

```swift
public func recoverUnderCurrentContext() throws -> SyncCanonicalBootstrapHandoff?
```

Nil means no active transaction or an interrupted transaction has rolled back; it is not canonical readiness. A nonnil result is issued only by the existing committed transaction's full handoff checks, and must cease to validate when the new freeze/ownership is released.

- [x] **Step 1: Add focused RED coverage.** Use actual prepared/installed/committed fixture trees, create a new context with the same account hash but fresh epoch/freeze UUIDs, and validate that exact new context through a revocable test guard. Existing `recoverInterruptedInstallation()` must still reject changed context; only the new explicit method can bridge it. Example shape using the existing private fixture:

```swift
let fixture = try Fixture()
defer { fixture.remove() }
let old = try fixture.transaction()
let prepared = try old.prepare(local: fixture.export(), sourceArchive: fixture.archive,
    remote: .init(context: fixture.context, records: [], attachments: [:], isComplete: true))
try old.install(prepared)
let receipt = try old.commit(prepared)
let current = SyncBootstrapContext(accountIDHash: fixture.context.accountIDHash,
                                  epoch: UUID(), freezeID: UUID())
var frozen = true
let restarted = try SyncBootstrapTransaction(liveRoot: fixture.live, context: current,
    journalRelativePath: "SyncMetadata/bootstrap-journal", validateContext: { candidate in
        guard frozen, candidate == current else { throw SyncBootstrapError.contextChanged }
    })
let handoff = try #require(restarted.recoverUnderCurrentContext())
#expect(handoff.transactionID == receipt.transactionID)
try handoff.revalidate()
frozen = false
#expect(throws: SyncBootstrapError.contextChanged) { try handoff.revalidate() }
```

Use a controlled complete empty remote only to seed explicit fixtures; do not introduce one into App production. Record API RED separately from behavioral mutation RED.

- [x] **Step 2: Implement the narrow internal bridge.** Reuse one validated manifest decoder, preserving exact-context validation for ordinary APIs. A private historical-context mode used only by `recoverUnderCurrentContext` must still validate envelope digest, version, account hash, exact live path, exact journal path, safe relative paths and current validator before any recovery mutation. An absent active manifest returns nil without creating an archive, journal or bootstrap directory.

An implementation may build a private historical transaction facade using the decoded old context, provided its validator checks both the exact selected historical context and the *current* transaction's validator on every operation:

```swift
// Internal only, after checked account/path/journal/envelope binding.
let historicalValidator: (SyncBootstrapContext) throws -> Void = { candidate in
    guard candidate == selectedHistoricalContext else { throw SyncBootstrapError.contextChanged }
    try currentValidator(currentContext)
}
```

Do not expose this facade, private manifest, preparation constructor or handoff constructor. Do not temporarily replace a mutable validator or weaken `loadManifest` globally. Reuse normal constructor path validation and existing rollback/handoff implementations; no copied alternate rollback.

Committed branch: obtain the private preparation from the validated selected manifest and use existing `canonicalHandoff` to verify receipt, checkpoint/archive, Original, exact live identity and canonical namespace inventory. Preserve the committed manifest/receipt bytes; retaining an old durable context is permitted only because the returned capability revalidates the new current context through the private facade. Daily canonical edits must not be accepted as a fresh bootstrap handoff.

Nonterminal branch: use existing interrupted recovery/rollback under that same current-authority guard. Only after exact Original is restored and the manifest is terminal rolledBack may its existing context fields be rebound to the current context, using the existing atomic persist/envelope format. This allows `prepare` on the current transaction after rollback. Preserve transaction ID, Original/installed proofs, mutations, receipt semantics and all retained trees. Revalidate current ownership and exact selected manifest before rebinding. On crash/failure retain enough old or terminal evidence for a later newly verified recovery. Do not rebind a corrupt or committed manifest simply to make normal APIs accept it.

- [x] **Step 3: Cover authority and interruption behavior.** Add actual assertions for each case, preserving original bytes/inventory on rejection:

1. Commit-before-canonical restart: same-account fresh epoch/freeze returns exact handoff; repeated recovery remains valid and leaves committed manifest/receipt/Original unchanged.
2. Released new freeze or changed current authority rejects both recovery and previously retained handoff; an old context being syntactically valid cannot bypass it.
3. Wrong account, substituted live root/journal, symlink ancestry, corrupt envelope/checkpoint/receipt/Original rejects. For a different empty namespace, nil must not be treated as the foreign transaction's successful recovery or create replacement data; explicitly distinguish absence from foreign evidence discovered at the selected namespace.
4. Iterate existing interruption boundaries with fresh current contexts: recover exact archive/private unsent bytes/pending attachment authority or fail preserving evidence; do not merely assert a throw.
5. After recovered rollback, a new `prepare` with the current context and freshly exported current source succeeds; old-context normal APIs cannot silently operate under the new rebound manifest.
6. Missing active transaction returns nil and creates no bootstrap/live/journal artifacts.
7. Activate a real canonical store with the recovered handoff, then reopen canonical state normally with `bootstrap: nil`; this demonstrates the new API is consumed by real existing authority, not just a receipt-shaped test value. Preserve existing activation tests proving ordinary hydration is not readiness.

Use synchronous boundary injection and exact file/inventory evidence; no sleeps, live factories or fake successful verifier. Any asynchronous store fixture must directly revoke/join before deleting its temporary root even when the body fails.

- [x] **Step 4: Focused GREEN and one behavioral RED.** Run affected bootstrap/canonical suites under the bounded runner:

```sh
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --no-parallel --filter '(SyncBootstrapTransactionTests|SyncBootstrapCurrentContextRecoveryTests|JSONProjectStoreCanonicalDurabilityTests)'
```

Demonstrate a runtime RED by temporarily removing the new-current-context guard from the private bridge or retained handoff, showing the released-current-freeze test fails. Restore and rerun affected suites. Also retain existing exact-context ordinary-API tests to prove no global relaxation. No full Core/Xcode while another lane is active; coordinate with controller.

- [x] **Step 5: Self-review, exact-file commit and evidence.** Run diff check, record commands/exits/log hashes and exact changed file list. Verify only the explicit API can admit a historical context, failure does not rewrite corrupt evidence, and committed Original/receipt bytes are preserved. Commit scoped production/tests; preserve other worktree changes. Report limitations: this supplies recovery authority, not App readiness or cloud enablement.

```sh
git diff --check
git add -- Sources/KnitNoteCore/CloudSync/SyncBootstrapTransaction.swift Tests/KnitNoteCoreTests/SyncBootstrapTransactionTests.swift
git commit -m 'feat(sync): recover bootstrap under current ownership'
```

Only include the named optional test files if actually changed.

### Task 2: Review, fixed-candidate validation and account-installer handoff

**Files:** create `docs/superpowers/reports/2026-09-07-bootstrap-current-context-recovery-verification.md`.

- [x] Independent task review and whole-subplan review, specifically historical/current authority separation, committed immutable evidence, rollback/reprepare and real canonical activation. Scoped fixes if needed; do not repeat completed App-root review.
- [x] Freeze reviewed candidate, run full Core, existing actual-source App harness and unsigned macOS/iOS serially with unique logs and the inspected bounded runner. No live App launch. Full prior Core 2521/186 and root harness 73/7 are baseline only, not proof for changed Core authority.

```sh
python3 /tmp/task4-run-bounded.py 3600 arch -arm64 swift test --no-parallel
python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --package-path /tmp/knitnote-app-root-kbh3SM --no-parallel
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/bootstrap-current-macos-derived CODE_SIGNING_ALLOWED=NO build-for-testing
python3 /tmp/task4-run-bounded.py 900 xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -destination 'generic/platform=iOS' -derivedDataPath /tmp/bootstrap-current-ios-derived CODE_SIGNING_ALLOWED=NO build
```

- [x] Preserve final report, logs, candidate identities and ledger decisions; continue the App account domain installation/readiness plan using the actual new API. Keep the heartbeat active. Do not claim account integration complete or request another routine go-on.

## Self-review

This slice resolves a specific existing Core public-authority gap required before the App lifecycle can recover nonterminal bootstrap ahead of terminal namespace validation. It neither decodes private evidence in App nor grants access based on cache/receipt existence. Ordinary APIs remain strict. Manifest fields may be rebound only after validated rollback using the same format; committed evidence stays immutable. Account identity, local-vs-cloud readiness, real ACK/source resolver, first remote snapshot and proven legacy ownership remain explicit subsequent integration requirements, not substituted by this API.
