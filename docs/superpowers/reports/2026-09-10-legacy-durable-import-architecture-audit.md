# Legacy durable import architecture audit

Date: 2026-09-10. Read-only source baseline: `378478c4dc1387ef63320db621f67c6f5a43a49a`.

## Outcome

Reuse owned native transaction phases. Require a distinct V4 legacy-import variant rather than an optional V3 binding. No V4 implementation, source capability issuance, new role output, production activation, or release is established by this audit.

The user delegated routine decisions after approving transaction recovery and write ordering. The controller wrote `../specs/2026-09-10-legacy-import-durable-transaction-design.md`, then had its concrete native assumptions independently checked. All three document findings below were checked against the actual source and corrected before implementation of the separate test-only plan.

## Native evidence and decisions

1. `SyncBootstrapOwnedManifest.swift` uses strict wire shape validation and requires version 3. The risk of a new optional binding is a missing binding becoming ordinary bootstrap in a future decoder, not the old decoder silently ignoring arbitrary added root keys. Use required V4 operation and binding, keep V3 behavior.
2. `SyncBootstrapOwnedTransaction.plan` compares input source archive against the destination working set. Its `sourceProof` and `original` are destination rollback evidence; legacy content needs a separate bound source lease. Passing legacy URL/archive into this unchanged interface is not an implementation strategy.
3. `KnitNoteBackupService` deliberately equates source and backup portable content digests. These do not identify exact package manifest bytes. The new design separates content equivalence from backup manifest digest and requires a native-retained, fully inventoried `LegacyBackup` role. Original successful backup stays retained.
4. Current `LegacyImportPreparationCoordinator.confirm` returns intent only. Current `SyncBootstrapSourceAccess` captures account-owned working-set only. A native legacy source issuer/final source freeze is still missing; a Bool, hash, URL or decoded V4 object must not substitute for it.
5. Native commit validates journal prefix, obtains receipt, exposes `afterReceipt`, validates again and only then persists committed. New process-death tests will establish this distinction on real V3 data before new integration.

## Document findings corrected

| Finding | Source check | Correction |
| --- | --- | --- |
| live→Original wording | `InstallOwner.move`, owned transaction line 874 at baseline, actually targets Displaced | Original is immutable preparation copy; live moves to Displaced and rollback restores it |
| Receipt version ambiguity | `SyncBootstrapReceipt.init(from:)`, ordinary transaction lines 105–118, tests formatVersion and defaults absent field to V1 | Explicit formatVersion 3 and complete required root fields; V1/V2 compatibility stated |
| Preparing before freeze ambiguity | owned transaction plan starts with validateContext; SyncBootstrapContext requires live freeze | Destination native freeze precedes plan/preparing; final legacy source stop/drain is separate |

## Cohesive integration boundary remaining

V4 issuance cannot start until these paths are coordinated in one implementation plan:

- Manifest/source input and builder: keep destination proof separate, bind native legacy source and retained backup, include binding in normalized/preparing digests and all reconstructed phase bodies.
- Native output roles/accounting: LegacyBackup is included before output in allocation, immutable digest, abort freeze, history retention, and worst-case recovery budget.
- Native readers: selectedRecoveryFormat, recover, terminal evidence, missing-working-set admission, history decode/transition, account inventory/authenticated recovery, and canonical handoff understand V4 without falling through to ordinary/legacy recovery.
- Receipt formatVersion 3 and strict V4 relation: phase + actual full prefix + receipt/binding/canonical/backup evidence, never receipt presence alone.
- Legacy source owner/lease + target freeze, current confirmation, producer drain and final revalidation: no shipping issuance until actual session/authentication integration is verified.
- Version downgrade/old-reader preservation and full fault/capacity/account/Watch acceptance from the spec.

These are implementation gates, not new user questions. They must not be hidden behind an isolated passing codec test. The currently executing `../plans/2026-09-10-owned-commit-crash-boundary.md` is expressly the native receipt/commit prerequisite, not completion of this whole integration.

## Current verification separation

Fresh root baseline ran `SyncBootstrapOwnedTransactionTests` on unchanged production source: 42 tests in 1 suite passed, test duration 255.691 s; bounded command exit 0, elapsed 258.218 s. It does not cover the new V4 design and does not prove CloudKit/device acceptance. Final new-test results belong in the separate verification report.

No push, merge, signature, export, upload, App Store Connect submission, automation change, user-data mutation, CloudKit schema or real account operation was performed for this audit.
