# Task 4 — Candidate Publication and Retained-Artifact Hardening

Base: `ff3b61304d291bd2ef81b27878a30354c4494870`.

## Result

- Raw `Packaging.log` files are removed immediately after both local exports, before provenance and the formal audit. The creator uses `umask 077`, publishes only after audit, and sets the final candidate root to `0700`.
- The audit rejects any unexpected Distribution file, including either raw packaging log, even when a fixture creates provenance after adding that file.
- The macOS package container is now verified with `pkgutil --check-signature`; the audit requires a trusted macOS result, an Apple-issued `3rd Party Mac Developer Installer` certificate for exact team `9CFPAUL5N5`, the Apple Worldwide Developer Relations intermediate, and Apple Root CA. Fixture coverage rejects unsigned, tampered, wrong-team, and untrusted results. The already confirmed sandbox-external candidate check was successful; it was not repeated here.
- Schema-2 provenance now inventories every retained regular file or safe in-root symlink below the candidate root, except canonical `provenance.json`; later extra, mutation, or removal fails verification.
- Publication uses `renameatx_np(..., RENAME_EXCL)` on the same filesystem. The creator-level fake-command fixture proves a destination created immediately before publication yields nonzero exit, no success marker or nested `artifacts`, and trap cleanup of staging.
- Screenshot Python selection requires Pillow `11.3.0`; an executable wrong-version candidate falls through to the compatible candidate.

## Boundary correction

The creator still forbids app upload, App Store mutation, `destination=upload`, and `-allowProvisioningUpdates`. macOS local export may contact authorized Apple developer services for managed installer-package signing. This task did not run Archive, Export, the creator, network, or any App Store operation; fixture commands were local temporary fakes only.

## Verification

- RED demonstrated the old audit accepted raw Distribution files, all four invalid package-signature outcomes, unbound retained entries, and a wrong Pillow runtime.
- Targeted GREEN tests passed for raw Distribution rejection, package signature success/failures, complete provenance, Pillow fallback, atomic helper behavior, and creator-level race/private-root/log-removal behavior.
- Fresh full `ReleaseAuditLocalizationTests`: exit 0, 51 tests in 1 suite PASS, 244.637 seconds; retained output is `/tmp/KnitNoteTask4-ReleaseAudit-final.log`.
- Fresh full `StoreScreenshotFixturesTests`: exit 0, 19 tests in 1 suite PASS, 8.304 seconds; retained output is `/tmp/KnitNoteTask4-Screenshots-final.log`.
- `release_audit.sh --static-only`, Bash syntax, Python compilation, plist lint, and `git diff --check` all passed.

No candidate bytes were modified or deleted. The earlier candidate remains quarantined.
