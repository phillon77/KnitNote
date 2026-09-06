# Store background write drain verification

## Result and boundary

The store now exposes `waitForTrackedBackgroundWritesAfterRevocation() async throws` as the aggregate wait for the four registered categories: backup, pattern, journal-photo, and thumbnail. The API documentation intentionally limits the termination result: successful return proves those registered operations have terminated after revocation. It is not a health or account-readiness receipt and does not prove durable health, a complete store or App freeze, cleanup authority, CloudKit or Watch acceptance, or release readiness.

No production App caller was added. Version/build remains 1.7.0 (13). This work did not enable CloudKit, Keychain, Watch, an App factory, signing, installation, upload, submission, migration, cleanup, or account switching.

The Task 4 focused behavior and the exact original default-concurrent affected filter are green after one controller-scoped, test-only real-event observation correction. The two earlier broad failures and the read-only sample that motivated that correction remain recorded below. No production behavior, timeout, test serialization, or native blocker was changed.

## Frozen identity inspected for Task 4

- Worktree: `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`
- Branch: `docs/cross-device-sync-design`
- Base and current HEAD during implementation: `60649e8d3b286a3e516e9649021be658e6ab72e9` (`feat(sync): drain accepted photo and thumbnail work`)
- Pre-Task-4 production SHA-256 / Git blob: `084d1c25f45ce0b875bdd6ea65e43bf07b70eda031b6444caf58355301aa9cb5` / `cf6f45e98f6349e97578b4a9ecab32637f8de92d`
- Pre-Task-4 test SHA-256 / Git blob: `43ca7522ccc959c477a0606abfacbe776af30088a9f4617061dcc888b5dd31bb` / `c9a84d76c1ff504dad64cc4f40bddffe9ae73c43`
- Final Task-4 production SHA-256 / Git blob: `e212cc5de1984884b5bad12253e3184477e68d19c3c18f584ee6156f42c0d9d9` / `4ae0dfd581448453159a65dbd03f8f93a1375dd4`
- Final Task-4 aggregate-test SHA-256 / Git blob: `82aefa748f6dadd1b01d43fa2182d951aa377eae36af96314f954418b9769302` / `2d4043bd034584ef382af80a3305d6cd04323c68`
- Pre-correction/final `PatternLibraryModelTests.swift` SHA-256 / Git blob: `65ebb0983574cc332f02030c077a172378dac28884a18cf3b22355498558356f` / `1e030f3e9023dee28575e2b1ae00b3b8525fd4a1`; `6f7bacdbeaad5009bb3e228eab705c856358a114c4bc6a437aa2a9640fdf2260` / `52f545b1e59c19ac4ba731303ab2d656e3bad050`
- Pre-correction/final `YouTubePatternThumbnailLoaderTests.swift` SHA-256 / Git blob: `9697e3469a20956e134d8e45811ef8e91c0df712176462be17c0d621ca6cd5f2` / `b345fb32a6ceeb76435032049f5623559627571e`; `d1b6127b5bc9504541ae3e3a77e104f6fe5eac3f2d2c1e57b86ba6f0601e13b9` / `d65af4b08c36793023b277a6c21c30f2ac591857`

These identities came from `shasum -a 256` and `git hash-object` command output. The corrected Task 3 test identity is the command-backed `43ca7522...`; the superseded unsourced `43f82a...` value was not used.

## Producer and waiter acceptance

`StoreBackgroundDrainIntegrationTests` uses real store entry points and existing fixture service hooks:

- The mixed test starts a journal-photo write and direct pattern import in one fixture, consumes both native block observations, revokes the store, and confirms the backup-only wait returns because no backup is active.
- The aggregate wait remains pending after journal-photo release and its revoked result, then completes only after pattern release and its revoked result. Both native task outcomes are awaited and inspected.
- A second, independently created B store is snapshotted before A starts. Its full-root evidence stays byte-identical while A's mixed drain completes, and a normal edit on B succeeds afterward; A's own full-root evidence is independently snapshotted and unchanged.
- Cancelling one registered aggregate waiter produces `CancellationError` without cancelling the peer or unregistering the native pattern work; the peer completes only after the native operation terminates.
- An open public aggregate wait throws `StoreSessionDrainError.sessionStillActive`; an empty closed store returns successfully.
- Parameterized journal-photo and pattern-inbox native failures preserve their exact errors and full fixture evidence across the subsequent aggregate wait. Import source bytes remain present.

Every Task 4 worker reports whether it reached its blocker. All failure cleanup after work starts releases blockers and awaits owned tasks before fixture cleanup. No sleep, arbitrary yield, elapsed-time assertion, unbounded child task, production seam, or native cleanup rewrite was added.

## Task 4 command evidence

### Existing-behavior integration check

Command:

```text
python3 /tmp/task4-run-bounded.py 600 arch -arm64 swift test --filter StoreBackgroundDrainIntegrationTests
```

Before the public visibility change, the already-internal aggregate implementation passed 5 test methods / 6 argument cases in 1 suite, with 0 issues; exit 0, test runtime 0.103 s, bounded elapsed 22.078 s. This is integration validation, not behavioral RED. Raw log: `/tmp/task4-integration-initial-20260907-01.log`; SHA-256 `fb0cc04447dc12b481450136e4de2068199bde5f403fe05b66ceeb6ccfb08644`.

### Required aggregate-scope mutation RED and restoration

The temporary mutation removed `.pattern` from the aggregate wait while the mixed test released journal-photo first and kept pattern blocked. Production SHA-256 changed from `084d1c25...` to `ae11a43d0852425dd535e25d6b445a920f3c48894386a536bc1525926d77a7ad`; the test SHA-256 remained `69da3dfe...`.

Command:

```text
python3 /tmp/task4-run-bounded.py 300 arch -arm64 swift test --filter StoreBackgroundDrainIntegrationTests.aggregateWaitIncludesBothNativeProducers
```

Result: 1 test in 1 suite failed with exactly 1 issue at the intermediate `#expect(!ended)` after journal-photo termination; exit 1, test runtime 0.028 s, bounded elapsed 10.036 s. Both native operations were subsequently released and joined. Raw log: `/tmp/task4-integration-mutation-pattern-excluded-20260907-01.log`; SHA-256 `7522c168bf9b8a2579b7a44b258eab146ac6716bee9640418888f16b10558bd5`.

The mutation was restored with `apply_patch`. Before public promotion, production SHA-256 and Git blob returned exactly to `084d1c25...` / `cf6f45e...`, while the test identity remained `69da3dfe...` / `9535507...`. After adding only the specified public visibility and API documentation, the same mixed command passed 1 test in 1 suite; exit 0, test runtime 0.028 s, bounded elapsed 29.032 s. Raw log: `/tmp/task4-integration-mutation-restored-20260907-01.log`; SHA-256 `b9c79b582216620fb9e0f0cb89271049a407a2f63d7609d9e3434d46f985b03f`.

### Final focused GREEN

Command:

```text
python3 /tmp/task4-run-bounded.py 600 arch -arm64 swift test --filter StoreBackgroundDrainIntegrationTests
```

Result: 5 test methods / 6 argument cases in 1 suite passed with 0 issues; exit 0, test runtime 0.104 s, bounded elapsed 1.022 s. No warning or error diagnostic appeared. Raw log: `/tmp/task4-integration-green-20260907-01.log`; SHA-256 `d374872a2c9df1d646816b06dd9b176adcb5e9c633177a4de3d7d479b43366f7`.

After adding the independent B evidence, the same focused command passed 5 methods / 6 cases in 1 suite with 0 issues; exit 0, test runtime 0.124 s, bounded elapsed 1.022 s. Raw log: `/tmp/task4-integration-with-independent-b-20260907-02.log`; SHA-256 `8b4183ce6a5ccaa965f29191a82c26db50ada579f06110fe5f5b553837a0dfa1`. A preceding sandbox-only attempt never compiled because Swift could not write its Clang module cache; exit 1, bounded elapsed 0.979 s, raw log `/tmp/task4-integration-with-independent-b-20260907-01.log`, SHA-256 `c167b02cb89a6c56920378d64342b41475c19a29a07b1bfcaa2929c1f3d056d9`. It is not behavioral evidence.

### Prescribed default-concurrent affected filter

Both runs used the exact command, including explicit ARM64 and default Swift Testing concurrency:

```text
python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --filter 'JSONProjectStore|StoreBackground|StorePatternSession|StoreMediaSession|StoreSessionWorkTracker|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch|PatternImport|PatternInbox|PatternLibrary|ProjectJournal|PatternThumbnail|YouTubeThumbnail'
```

Run 1 completed 1123 tests in 70 suites with 5 issues; exit 1, test runtime 169.982 s, bounded elapsed 171.198 s. Failures:

- `storeSuppressesPageThumbnailWhenAssetRevisionChangesDuringRendering`
- `storePublishesPageThumbnailWhenOnlyGlobalGenerationChanges`
- `storeSuppressesPageThumbnailWhenAssetIsDeletedDuringRendering`
- `cancellingStoreRequestCancelsStartedDetachedPageThumbnailRender`
- `cancellingTheRowRequestCancelsTheInFlightMetadataFetchAndDoesNotCache`

The four `PatternLibraryModelTests` issues are existing 10-second native blocker-start expectations. The loader issue is its existing diagnostic that the utility-priority metadata fetch did not start within 10 seconds. They surfaced after approximately 118-119 seconds under broad concurrency. Raw log: `/tmp/task4-affected-green-20260907-01.log`; SHA-256 `ba03f1c92a781e42e51350750d60177b4ce2d6b212f74a05d2b19e7ca1e20d05`.

Run 2 captured output directly rather than through `tee`, keeping the command and concurrency unchanged. It completed 1123 tests in 70 suites with 3 issues; exit 1, test runtime 178.648 s, bounded elapsed 181.174 s. The recurring failures were `storePublishesPageThumbnailWhenOnlyGlobalGenerationChanges`, `cancellingStoreRequestCancelsStartedDetachedPageThumbnailRender`, and `cancellingTheRowRequestCancelsTheInFlightMetadataFetchAndDoesNotCache`, after approximately 127 seconds. Raw log: `/tmp/task4-affected-rerun-20260907-01.log`; SHA-256 `ed6555f5b5baae265ed0299c9a7903f19356e5e2081ca46ad10589a0b4f2d699`.

The two implicated existing suites were then run together without changes:

```text
python3 /tmp/task4-run-bounded.py 300 arch -arm64 swift test --filter 'PatternLibraryModelTests|YouTubePatternThumbnailLoaderTests'
```

Result: 23 tests passed with 0 issues; exit 0, test runtime 0.097 s, bounded elapsed 1.218 s. Raw log: `/tmp/task4-affected-failures-isolated-20260907-01.log`; SHA-256 `19862da0ef90bbd38688940cdd58757c87d2fe3e43bd6b03a583b39b2c1e68ca`.

This isolates the observed failure condition to the broad default-concurrent context, but does not prove whether the root cause is cooperative-executor pressure, synchronous semaphore interaction, another shared resource, or a combination. No timeout, assertion, helper, test concurrency, or production behavior was changed to manufacture a green result. Both broad runs also emitted the known expected-negative `CoreGraphics PDF has logged an error` diagnostic from invalid-PDF coverage; neither emitted compiler `warning:` or `error:` diagnostics. Both bounded commands reached their own terminal exit, and a final process check found no matching bounded runner, `swift test`, or `KnitNoteCorePackageTests` descendant.

### Read-only comparison without the new Task 4 suite

The controller requested one diagnostic run using the same affected filter and default concurrency while skipping only `StoreBackgroundDrainIntegrationTests`:

```text
python3 /tmp/task4-run-bounded.py 1200 arch -arm64 swift test --filter 'JSONProjectStore|StoreBackground|StorePatternSession|StoreMediaSession|StoreSessionWorkTracker|SyncConflict|SyncRemoteBatch|SyncPublication|SyncDeletion|Backup|Watch|PatternImport|PatternInbox|PatternLibrary|ProjectJournal|PatternThumbnail|YouTubeThumbnail' --skip StoreBackgroundDrainIntegrationTests
```

Result: 1118 tests in 69 suites completed with 3 issues; exit 1, test runtime 179.856 s, bounded elapsed 181.533 s. The failures were `storePublishesPageThumbnailWhenOnlyGlobalGenerationChanges`, `cancellingStoreRequestCancelsStartedDetachedPageThumbnailRender`, and `cancellingTheRowRequestCancelsTheInFlightMetadataFetchAndDoesNotCache`. Raw log: `/tmp/task4-affected-skip-new-suite-20260907-01.log`; SHA-256 `5a4eaac5dea4a3ab6064685250e1671c1b0d372b599464d76df4885fe78860cb`.

During the comparison, a single five-second native sample targeted only Swift Testing helper PID 72090, resolved from the active command line. It captured three utility cooperative threads spending the entire sample in `PageThumbnailRenderBlocker.blockOnce()` -> `dispatch_semaphore_wait`, plus a user-initiated cooperative thread in the existing `StoreOperationBlocker.blockOnce()` backup path. It also showed Swift global jobs being enqueued. Sample: `/tmp/task4-affected-skip-new-suite-sample-72090-20260907-01.txt`; SHA-256 `f3948c6d2d77a3139f700e2ce771c00577b9ccd98cf573a0263c9624d483d416`.

The skip-only comparison proves the new Task 4 suite is not necessary to reproduce the broad gate failure. The sample provides direct evidence that existing synchronous semaphore blockers occupy cooperative-executor threads during the delayed broad run. It does not prove that semaphore occupancy is the sole root cause or identify a safe fix. Source/test identities stayed exactly `e212cc5d...` / `69da3dfe...`, no code was changed, and a final exact process check found no test descendants. Any broader diagnosis or helper redesign requires a separately scoped controller ruling.

### Controller-scoped real-event observation correction

The controller then authorized one test-harness-only correction in `PatternLibraryModelTests.swift` and `YouTubePatternThumbnailLoaderTests.swift`. Page-render tests now observe a buffered `AsyncStream<Bool>` event instead of occupying a detached cooperative worker in a timed semaphore wait. Metadata tests synchronously record buffered start/cancellation events and await a buffered release event instead of deadline-first polling. Completion before start and completion without cancellation publish `false`, so failure paths join cleanly rather than hang. The existing native semaphores and every semantic result, generation, revision, deletion, cancellation, cache, and read-count assertion remain.

The new helper-contract tests were first compiled before the event APIs existed with `python3 /tmp/task4-run-bounded.py 300 arch -arm64 swift test --filter 'pageRenderBlockObservation|pageRenderCompletionBeforeStart|metadataGate'`. Compilation failed only for the missing test-helper API; exit 1, bounded elapsed 16.810 s. Raw log `/tmp/task4-observation-helper-compile-red-20260907-01.log`; SHA-256 `cb9317fde1da53f02661a7e983e03351d5a524c06d05ebdc6784e912bf5751f3`.

Focused implicated tests plus helper contracts used `python3 /tmp/task4-run-bounded.py 300 arch -arm64 swift test --filter 'storePublishesPageThumbnailWhenOnlyGlobalGenerationChanges|storeSuppressesPageThumbnailWhenAssetRevisionChangesDuringRendering|storeSuppressesPageThumbnailWhenAssetIsDeletedDuringRendering|cancellingStoreRequestCancelsStartedDetachedPageThumbnailRender|YouTubePatternThumbnailLoaderTests|pageRenderBlockObservation|pageRenderCompletionBeforeStart'`. It passed 11 tests in 1 suite with 0 issues; exit 0, test runtime 0.040 s, bounded elapsed 59.725 s. The build emitted only the unrelated existing deprecation warning at `HighlightOverlayContractTests.swift:92`. Raw log `/tmp/task4-observation-focused-green-20260907-01.log`; SHA-256 `71a176db1200634d325d5cf6a2f32c1f432a26fea5cdafa494cb2780e7bf875b`.

The exact original broad command above, with no skip, timeout change, serialization, or concurrency flag, then passed 1128 tests in 70 suites with 0 issues; exit 0, test runtime 171.350 s, bounded elapsed 172.830 s. It emitted the known expected-negative CoreGraphics invalid-PDF diagnostic and no compiler `warning:` or `error:` line. Raw log `/tmp/task4-affected-observation-fix-20260907-01.log`; SHA-256 `e0aa7b8c5add59ebbb9e5a69c07945af2fa0e0a5158ed80b91989748accfc411`. The post-run escalated exact process check returned only its own `pgrep` shell and no owned runner, SwiftPM, or test-helper descendant.

## Prior task evidence carried forward

- Task 1 is committed as `83417e2` and established the category-aware tracker plus backup-only compatibility. Its authoritative ARM64 focused result was 30 tests in 4 suites passing. The backup-only wait remains backup-only and is not a full freeze.
- Task 2 is committed as `f99a990` and wired pattern/inbox lifetimes. Its 261-test / 20-suite affected run predates the latest test-only cleanup fix and is not represented as final frozen evidence. The authoritative fix1 evidence is the command-backed 1 test / 2 argument cases plus the 6-test suite rerun. The known CoreGraphics invalid-PDF diagnostic and the missing exact deterministic regression between `PatternImportCoordinator.prepare` completion and synchronous MainActor publication remain open before real-sync activation.
- Task 3 is committed as `60649e8` and wired journal-photo and thumbnail lifetimes. Its corrected command-backed test identity is `43ca7522ccc959c477a0606abfacbe776af30088a9f4617061dcc888b5dd31bb`; its frozen affected result was 131 tests in 17 suites passing. The earlier unsourced `43f82a...` report line is superseded.

## Pending controller and release gates

The independent precommit review is pending. The controller-owned frozen full Core suite and platform build/test validation are pending until the controller supplies actual evidence; they were deliberately not run during Task 4. The exact affected default-concurrent Task 4 filter is green, but it is not a substitute for those controller-owned gates.

App startup/account-switch wiring, App-external producers, Watch/engine behavior, UI generation, construction-time recovery, real authority, live CloudKit, device acceptance, cleanup authorization, signing, upload, submission, and release acceptance all remain separate pending gates. No result in this report authorizes activation or release.
