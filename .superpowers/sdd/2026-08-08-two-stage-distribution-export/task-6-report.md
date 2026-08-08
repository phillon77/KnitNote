# Task 6 — macOS Package Status Compatibility Repair

Date: 2026-08-08 (Asia/Taipei)

## Root cause

The Retry 1 candidate creator's package-container audit rejected the exported macOS pkg even though read-only local `pkgutil --check-signature` evidence had exit status zero, the exact leaf `1. 3rd Party Mac Developer Installer: Chen Chung Lung (9CFPAUL5N5)`, the Apple Worldwide Developer Relations intermediate, and Apple Root CA. Its status line was exactly:

```text
Status: signed by a developer certificate issued by Apple (Development)
```

The audit parser accepted only `Status: signed by a certificate trusted by macOS`, making the failure a compatibility false negative at the status-line boundary rather than evidence of a missing leaf/team/chain check.

## TDD repair

- RED: a fake `pkgutil` fixture emitted the observed status with exit zero and the complete expected chain. The focused contract failed as expected: audit exit `1` at `ReleaseAuditLocalizationTests.swift:449`.
- GREEN: the parser now matches an exact full status line from a two-item allowlist: the existing `trusted by macOS` form or the observed Apple developer-issued form.
- Safety retained: `pkgutil` must still exit zero, leaf entry `1.` must be the exact expected installer team, and output must contain the WWDR intermediate plus Apple Root CA.
- New negatives remain rejected: arbitrary status, revoked status, error status, wrong chain, existing wrong-team/prefix/suffix and mixed-chain cases, plus unsigned/tampered/untrusted package failures.

## Verification

- Targeted RED log: `/tmp/KnitNoteTask6-pkg-status-red.log` — one expected failure.
- Targeted GREEN: `archiveAuditRequiresTrustedExactTeamMacInstallerPackageSignature` passed, 1 test in 1 suite, 31.223 seconds (`/tmp/KnitNoteTask6-pkg-status-green2.log`).
- Fresh full `ReleaseAuditLocalizationTests`: 54 tests in 1 suite passed, 293.083 seconds (`/tmp/KnitNoteTask6-release-audit-full.log`).
- Fresh `StoreScreenshotFixturesTests`: 19 tests in 1 suite passed, 21.487 seconds (`/tmp/KnitNoteTask6-screenshots.log`).
- Static release audit, Bash syntax, Python compilation, plist lint, and `git diff --check` passed.

## Scope

This task changed only the package-status parser and its audit fixture coverage. It performed no Archive, Export, creator, candidate retry, network, App Store Connect, provisioning/profile/session mutation, push, or merge. The Task 5 candidate remains absent; no release or submission gate is cleared by this source-only repair.
