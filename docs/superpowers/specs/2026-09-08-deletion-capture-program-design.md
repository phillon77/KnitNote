# Deletion capture content program design

## Approved scope
Under active delegated technical authority, implement one coherent data-only incoming-deletion program using real ordinary ledger merge, stage/final reductions, envelope encoding and restoration semantics. Keep version 1.7.0 (13), deployment floors and existing limits. This is a prerequisite, not owned execution or release acceptance.

## Trust and behavior boundaries
Inputs are frozen bytes/proofs, never physical ownership certificates. The program performs no filesystem I/O, does not instantiate a ledger, and exposes no sink, issuer, trusted flag or runtime bootstrap caller. Mapper validation remains an explicit unfulfilled job, including when attachment maps are empty. Ordinary initialization, purge, locks, random identity behavior, source-read/check/write order and cleanup must remain unchanged.

A nonempty request list validates the complete initial ledger tree and exact manifest hash/size, rejects outstanding purge intents and invalid paths/proofs, then preserves historical unreferenced outputs. Empty requests are a no-op and certify nothing. Existing root missing its manifest is not absence.

## Program content
Use the concrete request/allocation/program types in the accompanying plan. Each ordered output owns its exact bytes or copy selector, not a path-keyed mutable content table. Copy selectors reference an incoming request attachment, exact initial retained file, or immutable prior output. Validation jobs reference preceding scratch writes only. All generated directories, locks, repeated manifest replacements, retained files and temporaries are explicit. Scratch belongs under ValidationMerged; ledger outputs belong under Staged. Complete prefix composition and full history/Base64 budgeting remain separate owner obligations.

Preflight all semantic, path, proof and exact envelope limits before invoking temporary-ID callbacks. Check generated temporary collisions too; callback results do not grant authority. Cross-request allocations and generated child identities must not collide with projected records/paths or previously allocated identities. Same-slot retained heads preserve the canonical lineage order; deterministic restoration sorts only complete slot tuples and retains unselected index gaps. Reject incomplete, duplicate or colliding child maps. Ordinary overload retains existing behavior.

## Shared implementation and verification
Keep manifest types private. Decoder retained-file callback stays at the existing per-group check point. Shared merge must not move final guards ahead of fallback source construction. Final prior/staged guard remains before copies. Exact sortedKeys envelope encoding and 100,000,000-byte bounds are shared with ordinary persistence.

Implement and review as one deliverable with RED/GREEN evidence: media-free and supporting-media captures, prior retained fallback, multiple captures, exact reuse versus conflict, absent/corrupt/purge ledger, raw UTF-8 aliases, size boundaries and callback rejection. Deterministic restoration regression must oppose UUID order to timestamp priority with distinct hashes and preserve the winner. Add actual Xcode target membership and App harness link with proportionate frozen App/root/unsigned platform verification.

## Explicit remaining work
No physical validation certification, durable preparing, output execution, abort history, sourceSpent/reissue, transport activation, device/cloud acceptance, signing, push or submission is authorized by this design. Those remain known integration gates.

