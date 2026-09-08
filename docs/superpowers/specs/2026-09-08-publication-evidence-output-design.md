# Publication evidence output design

## Scope
One data-only save program for the actual bootstrap helper; no applying program or runtime caller. Preserve 1.7.0 (13), iOS18/macOS15/watchOS11, current wire formats, public APIs and all ordinary read/validation/install/head-write ordering. No physical I/O, sink, issuer, trusted flags, ownership certification, cleanup, signing or publication.

## Input and output contract
Use the concrete API in the accompanying plan: complete Staged tree ingested as arrays to detect duplicate raw paths, optional exact bytes required for selected existing immutable files, fixed SyncMetadata output paths. Validate complete raw UTF-8/type/parent/alias/proof bounds. Preserve all unselected history unchanged, without decoding it. An old head is an overwrite-proof dependency, not a semantic-read dependency. A malformed old head may be replaced exactly as ordinary save permits. Planned lock requires empty proof without tightening ordinary lock rules.

Authority, tombstone and Watch candidates use shared real private codecs/matching. Reuse preserves exact existing bytes/proofs after semantic match; never substitute candidate encoded bytes. Authority nil/full records mismatch, while tombstone optional-record compatibility remains as existing helper defines. Return ordered exact writes/reuse/directories/lock and explicit parent-sync obligations; reuse has no temporary but still requires parent synchronization. Whole save lock lifetime includes final head durability. These are obligations, not executed work.

## Bounds
Authority/tombstone16MiB, Watch1MiB, head64MiB from existing journal cap, generic owned file100,000,000 bytes. No cap increase or guessed entry cap. Preflight non-temporary data before callbacks; check complete generated temporary paths and aliases afterward. UUID reuse across different noncolliding temp paths is permitted. Use shared head byte-count guard with exact/+1 tests and real small encoder parity; do not misrepresent it as a full-size semantic head test.

## Verification and integration
One implementation/test/review unit includes new source target membership and actual App harness link. Test all output families, ordinary bytes parity, noncanonical byte reuse, bare tombstone compatibility, authority mismatch, selected missing/corrupt bytes, old-head overwrite, historical retention, aliases/temp collisions, limits, ordinary I/O ordering, explicit parent sync and real finite-prefix composition. Use actual existing finite planner once over complete prefix+suffix; no fake owner or empty binding. Independent review followed by proportionate frozen App/root/unsigned builds.

## Remaining gates
No full recovery/Base64/history budget, durable preparing, output executor, abort/sourceSpent/reissue, App/transport/device acceptance or release completion. This plan is finalized only; implementation has not begun. Automatic delegation stays paused.

