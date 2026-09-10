# V4 legacy import integration preflight

Date: 2026-09-10
Inspected baseline: a13ce35c81bd3afa74538c9f71412c12cfe3fe3e
Status: compatibility-contract clarification approved by the user's subsequent `go on`; V4 remains disabled pending implementation and verification.

## Evidence boundary

This is a source inspection, not an executed V4 recovery test, device acceptance, or App Store status check. The earlier native V3 commit-crash prerequisite is complete; it does not implement V4 import or shipping integration. No production source was changed during this preflight.

## Compatibility contradiction

The durable import design section 8 requires an old V3 reader to reject V4 before writes or cleanup. In `SyncAccountStorage.open(identity:mode:)`, the `.legacy` entry skips existing-evidence preflight and verified source validation. With a present working set and no recovery-control evidence, it removes abandoned decrypted temporary sessions before creating a fresh session directory. Filesystem tree validation does not decode the bootstrap selector version.

Thus an unknown V4 selector does not itself prevent this old admission path from performing cleanup. The bootstrap persistent tree is not directly removed by that specific cleanup; temporary recovery evidence can be affected. Missing-working-set protection is a separate branch and cannot establish the live-present guarantee.

Nonempty valid recovery control suppresses that deletion but does not reject legacy open or prevent new-session creation. An empty control directory is insufficient. Fabricating recovery intent or invalid markers solely to influence old cleanup is not an authorized migration mechanism. Current reader changes cannot retroactively repair historical binaries.

`CloudAccountTransitionCoordinator.open` uses verified admission when provided an account validation callback and otherwise retains the legacy entry. The local `v1.6.0-build12` tag contains neither the inspected account storage file nor the CloudSync App directory. This does not prove what binary is currently distributed: deployed older-version exposure remains unverified. Do not describe the finding as a shipped-app data-loss incident.

Approved contract clarification: current supported readers must reject unknown formats before mutation; pre-change internal development binaries are not supported for direct reopening of V4 account storage. Preserve original legacy data and successful backups. If direct downgrade into those historical readers is required in the future, first design and verify storage isolation against those exact readers; do not promise that changing the new decoder achieves it. This does not waive actual shipped-version upgrade verification.

## Cohesive implementation map

The subsequent executable plan must cover these together before enabling any V4 issuer:

- Strict V3/V4 manifest dispatch with variant-preserving phase transitions and normalized prepared digests. Do not decode V4 through V3 and discard its binding.
- Variant-specific output roles, including retained immutable LegacyBackup, preparation program, output planner, full-prefix capacity and retry/history projections. Existing V3 role acceptance must not widen accidentally through allCases.
- Strict receipt version 3 with tagged destination source proof and legacy binding digest; preserve existing receipt versions 1 and 2 unchanged.
- Native transaction preparation, install, receipt, commit, rollback, selector recovery, terminal validation and handoff.
- Mixed-format history, account inventory and authenticated recovery selection, account storage admission, and mutation-journal owned-original snapshots.
- Source authority issued by a qualified native source owner, not a caller-supplied URL, load success, disabled publication sink, observation digest, or confirmation Boolean.
- Backup before irreversible source revocation: JSONProjectStore export requires write access both before and after its await. Target freeze precedes native preparation; final source drain and revalidation precede install. Existing producer drain alone is not a complete source authority or freeze.
- Destination original archive and destination pending journal remain distinct from imported legacy records. Merge must preserve conflict decisions and upload intent; legacy Watch queues and account proofs must not be transferred.
- Actual crash/reopen, malformed proof and receipt, budget boundary, stale generation, and compatibility admission tests. Shipping factories remain disabled until the complete native contract is verified.

## Next gate

The supported-reader contract is now resolved in the design section 8. Complete the cohesive integration plan and its implementation before enabling V4. Do not substitute a codec-only task for native integration, repeat the completed V3 crash prerequisite, infer real-device acceptance from local test counts, or claim submission readiness.
