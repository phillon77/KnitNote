# Account source provenance and recovery handoff

2026-09-08. Architectural implementation design under the user's delegated routine technical authority. Baseline d2c1673 / source08c7475; not implemented. This closes the absent-source full-seal prerequisite, not full CloudKit or release acceptance.

## Goal and retained policy

Permit safe sealing/cancellation/account switching of legitimately absent archives, including completed pending restore before first bootstrap prepare and a validated bootstrap rollback. A missing/corrupt old archive must not be reclassified as an empty account. Existing authenticated selection remains the sole cleanup/restore authority; source provenance alone never authorizes deletion.

Reuse the existing recovery transaction, storage ownership lock, inventory, encrypted vault and bootstrap installer. Keep1.7.0(13), iOS18/macOS15/watchOS11, existing remote record/journal/publication formats, exact FIFO and attachment bytes, deletion/expiry policy, incoming128batches/16MiB, journal64MiB, file/canonical/batch100,000,000bytes, recovery aggregate cap and control8192bytes. No live account/Keychain/device/signing/schema/push/upload/submission or user-data cleanup. All implementation tests use isolated fixtures.

## Alternatives and chosen boundaries

Use one versioned state machine in existing intent.json/intent-next.json. A separate provenance file would require conflicting-record precedence and two-file crash rules; keeping replayComplete indefinitely prevents runtime file creation and ties current data to vault expiry. Neither is selected.

Use the existing cooperative app-sandbox integrity model: descriptor ownership, exact hashes and crash-durable state, not a claim of cryptographic protection against a hostile same-user writer. Vault-selected cleanup is still authenticated. No new key lifecycle or retention extension.

Fresh allocation is certified only at actual successful creation of the account directory, before any producer receives paths, with exact empty owned scaffold and durable source state. Existing directories without provenance remain ambiguous even if empty. Interrupted creation before durable provenance fails closed on reopen. Do not add a parent allocation-history database in this scope. Complete deletion of the account namespace cannot be distinguished from first use by namespace-local evidence; this design makes no stronger historical claim. This is the existing storage failure model, not permission to infer first use from a missing archive inside an existing account.

## Durable control forms

Continue reading and writing ordinary v1 selected recovery intents unchanged on legacy archive routes. Add a v2 tagged envelope with exactly one state:

- selectedRecovery: existing selected vault/receipt/phase plus typed predecessor source binding.
- absentSource: compact authority UUID, generation UUID, account hash, physical account-root identity, fixed archive/journal paths, portable baseline digest and typed origin.
- sourceSpent: the former source identity/baseline plus the exact existing bootstrap transaction UUID and prepared manifest digest.

Use existing main/next filenames and8192-byte cap; no third excluded sidecar. Custom decode rejects unknown version/tag, mixed state fields, missing/null required fields, invalid hashes/paths/root bindings and derivative without valid authoritative main. Source state checksum detects corruption, not hostile forgery. Storage control validation must understand these forms rather than interpreting unrecognized controls as no selected recovery.

All write transitions compare exact predecessor main bytes/digest, write/sync next, revalidate predecessor and source under ownership, rename next over main, sync control/account directory, then reread. A readable new main after failed directory sync is resynchronized/revalidated on retry; next alone never grants authority. Capture must include the explicit control observation because ordinary entries exclude controls. Never rely on entries fingerprint to detect a control-only change.

## Source provenance and inventory

Origins are typed: restoredSelection (exact authenticated receipt/capture/packet/deletion identities), bootstrapRollback (exact validated terminal transaction/source envelope), or freshAllocation (storage-issued allocation UUID and original physical root).

The baseline hashes canonical portable proofs for the entire working-set, ordered pending mutation identities/content and every selected attachment/deletion source outside working-set. Runtime engine-state/staging descendants may evolve only under their actual scoped ownership; every byte still joins the complete inventory at capture. Selected sources inside staging remain baseline-bound. Before canonical activation no domain or journal edits are admitted; a changed baseline blocks rather than silently refreshing proof.

Legacy inventory remains its existing unversioned archive shape and SHA256(entries), requiring an archive entry. New inventory v2 includes typed sourceAuthority and fingerprint SHA256(canonical {entries,sourceAuthority}). An absent source forbids archive file/directory/descendants and contradictory canonical/publication authority. Carry exact rollback envelope bytes inside authenticated inventory so decode after cleanup validates without missing plaintext. Reuse the bootstrap pure source validator, not a second permissive parser. Include encoded proof/base64 bytes in aggregate preflight before reading selected sources. Existing path/dependency/deletion/journal validation is unchanged.

Portable baseline excludes device/inode only to allow proven bootstrap directory replacement; actual captured inventory/root binding keeps physical identities. A decoder verifies source proof against embedded inventory and authenticated payload; it does not trust an App-provided absent flag. Old v2 rolled-back bootstrap evidence may be admitted as an explicit compatibility origin only when no conflicting current control exists and actual terminal validator proves Original/current equality. No-bootstrap-files is not proof.

## Restore consumption without an authority gap

Authenticate selected vault at current time, require replayComplete, validate/synchronize exact restored state under transaction mutex and one storage ownership scope. Replace replayComplete main atomically with absentSource instead of unlinking to no selection. Only after durable handoff may assets/transport initialization proceed. Repeated consumption recognizes only matching origin/capture; different selections cannot succeed. Public false remains no completion proof, never authority.

Expiry before durable handoff keeps existing failure behavior. Expiry after successful handoff does not invalidate current restored local data or extend permission to replay the expired vault. A new seal is a new authenticated capture of current pending data under unchanged policy.

Legacy callers that expect selection absence must be updated to distinguish active source provenance from selected recovery. lifecycleSnapshot must not falsely expose absentSource as a selected vault phase; a separate typed source observation supplies runtime routing. synchronizeSelectionAbsence must not delete or overwrite active/spent source state.

## Fresh allocation and upgrade boundary

Storage keeps the actual directory-created fact, acquires the account lock, verifies initial owned scaffold/no prior data, and durably initializes freshAllocation source before returning producer-accessible paths. A validated freshly queried account/session generation remains the App issuance/use prerequisite; CloudAccountBinding alone is only a hashable binding, not a query result. Existing legacy archive accounts continue their old route. Existing missing accounts lacking selected recovery, valid rollback or durable source state remain blocked.

Creation interruption before source state is durable leaves an ambiguous existing namespace; fail closed without deleting it. This bounded fail-closed case is explicit rather than guessed recovery. No automatic recreation of provenance for existing directories and no parent-history migration.

## Spend before archive installation

After bootstrap has durably prepared its normal manifest/Original/Staged evidence, bind its exact UUID and manifest digest into sourceSpent before its first live archive-producing move. Existing transaction UUID/digest suffices; do not change its v2 evidence format merely to duplicate source generation. The source control references that immutable prepared evidence, and owned installation checks the matching spent binding.

Use an internal Core-issued installation capability, not public arbitrary UUID/boolean bypass. Capture bootstrap validated evidence outside storage ownership, then compare exact bound evidence/source inside a synchronous ownership scope using pure validators; do not call a public context validator recursively while holding the same storage mutex. No ownership lock crosses await.

Owned App bootstrap, ordinary first-binding installation when using account paths, and account domain factory activation must respect this gate. Generic non-account stores retain their current behavior; no future account caller may construct a default archive while absentSource is active. Inspect actual reachable constructors/writers before implementation completion. Tests must show accidental factory initialization is rejected before source bytes change.

A committed install leaves sourceSpent, never reusable absence. Archive later deleted or corrupted cannot revive that state. A matching actual terminal rollback may replace sourceSpent with a new absentSource generation after verifying original tree and exact bound transaction. Lost/conflicting manifest stays blocked. A spent transaction that is still prepared or interrupted routes through existing bootstrap recovery before any replacement authority; no second rollback implementation.

## Transport namespace ownership

Keep bootstrap session state/incoming/system-fields below engine-state/bootstrap-sessions/<validated UUID>. Existing recursive inventory captures descendants already; no exclusions or new cleanup roots. Add a Core-issued account-bound descriptor for exact session paths, used by transport binding validation; caller-supplied arbitrary paths are rejected. Legacy descriptor retains engine-state/engine.json paths unchanged.

This provenance subplan needs namespace descriptor validation and actual inventory/cleanup coverage, not engine collection or active-session promotion. Later transport work owns fresh manual engine issuance, source sealing, exact consumed-input ACK and durable active selection. Runtime namespace mutation after prepare must invalidate seal; mutation after seal must invalidate cleanup. Neither source baseline exceptions nor a valid descriptor permits inventory omission. Engine state is not restored as pending user data.

## Verification and implementation sequence

1. Implement control/source observation and explicit predecessor checks with legacy codec and crash matrix, including fresh-created-only issuance. No App activation yet.
2. Extend inventory capture/authenticated decode and actual seal/restore/handoff: v2 rollback, restored/cancelled preprepare, fresh source, pending/deletion/media, expired selection and all faults. Replace the current unsafeBinding success-expectation regression with real full roundtrip, retain corrupt/unknown absence rejection.
3. Bind/spend/reissue around actual owned bootstrap/recovery and App destination path; prove create-then-delete never restores authority, no recursive-lock deadlock, no pre-canonical writer escapes, and real cancellation/account switch joins existing work.
4. Add typed transport session path descriptors and captured descendant coverage without starting a live engine. Independent reviews, then one frozen full validation of cohesive implementation.

Tests must cover main/next write/sync/rename/sync failures; changed control without entries changing; root replacement; wrong selection/source generation; pending FIFO/bytes and selected attachment/deletion changes; unknown/mixed codecs; exact legacy readers; consumed old-vault expiry versus pre-handoff expiry; fresh-existing ambiguity; archive path directory/symlink; install/rollback every boundary; actual App factory and recovery calls; namespace descendant addition before seal/cleanup. Preserve all source bytes on rejection and no tests touch live services.

## Remaining boundaries

Complete full fetch provenance/hard-delete reduction/committed-input ACK bridge/event-consumer transfer is subsequent work. Canonical temporary-routing four cases and live helper account/container remain open unless explicitly covered by new integration tests. Shipping product UI/localization, backup/Watch, actual cloud/devices and exact-candidate release gates remain. No completed subplan/test count is full sync acceptance.

Self-review: one authoritative control, one installer, explicit compatibility and integrity/first-allocation boundaries; no empty-source inference, independent sidecar, parent history or key/retention expansion. Above decisions are routine technical choices under delegation; their tradeoffs must appear in the final verification report.

## Inventory integration compatibility clarification

For the first selection of a positively validated legacy missingArchive rolledBack source with both account controls absent, retain the existing v1 initial Intent selector while its authenticated vault carries Envelope v2 / Inventory v2 and exact rollback evidence. This narrow bridge is an exception to ordinary archive-only v1 selection, not a fake predecessor or reusable absence authority. Authenticate and synchronize vault, repeat exact nil/nil control and root/source/inventory checks, then write/synchronize/read back v1 main before cleanup. Visible complete main is authenticated and resynchronized on retry; torn first main remains fail-closed with plaintext/vault preserved. Later v1 phases stay with the existing authenticated owner, and consumption replaces the actual replayComplete main using its true hash.

Per-phase selectedRecovery predecessor is always the immediate prior main hash. Immutable captured source control bytes and origin belong in authenticated Envelope v2 / Inventory v2, bound by the Intent's envelope/fingerprint; never equate later phase edges with the original source hash. Decoding retained temporary sessions permits only exact authenticated safe UUID directory trees with parent proofs, not broad suffix/path exceptions. Existing legacy archive wire remains unchanged. Costs are a dual-version selector/payload matrix, extra bounded metadata, and retained plaintext until authenticated cleanup. The scoped implementation plan is 2026-09-08-account-source-inventory.md; owned-bootstrap lineage and App activation remain later work.

## Selected capture lifetime clarification

Before attempting initial selector publication, the authenticated recovery transaction registers its private sealed receipt and exact current temporary subtree with the existing Storage ownership scope. Storage validates the receipt/inventory fingerprint, account/root and current session's physical entries. Ordinary close preserves that registered tree, including publication or synchronization uncertainty. Only the authenticated transaction can release registration after synchronizing cleanupStarted or a later allowed cleanup phase. Storage never decodes an unauthenticated phase into deletion permission. No public trusted flag, new owner or persistent sidecar is introduced.

Registration protects the currently held session only. A reopened UUID did not exist in the earlier capture and starts unregistered; normal repeated close does not accumulate extra unselected session directories. Generic legacy open preserves abandoned trees whenever bounded safe main/next control evidence exists, and rejects unsafe control metadata before removal. No-control legacy temporary cleanup remains supported. Preserved trees still join exact inventory and authenticated cleanup; sealed missing-entry checks are unchanged.

Normal ARC deallocation invokes the same validated close on a best-effort basis: registered captures remain, ordinary current copies may be removed, and errors have no fallback deletion. This introduces cleanup I/O at normal deallocation, whose errors cannot be reported as successful cleanup. Abrupt process termination does not run this path. An abrupt crash leaving extra unselected session directories remains fail-closed unless a separate orphan-session design is approved; these ordinary close/ARC tests do not prove that route. The distinct nil-control nested-rollback admission gate also remains unresolved.
