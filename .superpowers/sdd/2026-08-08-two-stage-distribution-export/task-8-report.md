# Task 8 — Indented pkgutil Output Compatibility Repair

Date: 2026-08-09 (Asia/Taipei)

## Root cause and TDD evidence

Real `pkgutil --check-signature` output indents its legitimate `Status:`, `Certificate Chain:`, and numbered certificate lines. The structured parser at `b62b036` compared status and header before stripping, so it rejected otherwise valid output.

RED added an exact indented fixture with leading and trailing whitespace. The package-signature contract failed as expected with audit exit `1` (`/tmp/KnitNoteTask8-red.log`).

GREEN normalizes every output line using `strip()` before all structural parsing. It still requires exactly one approved status, exactly one header, and exactly three exact numbered entries, so only leading/trailing whitespace is tolerated; embedded text, duplicate status/header/entry lines, wrong chains, and nonzero `pkgutil` cases remain rejected.

## Verification

- Targeted package contract: 1/1 PASS in 43.558 seconds (`/tmp/KnitNoteTask8-green.log`).
- Fresh `ReleaseAuditLocalizationTests`: 54/54 PASS in 284.115 seconds (`/tmp/KnitNoteTask8-release-audit-full.log`).
- Fresh `StoreScreenshotFixturesTests`: 19/19 PASS in 7.830 seconds (`/tmp/KnitNoteTask8-screenshots.log`).
- Static audit, Bash syntax, Python compilation, plist lint, and diff check passed.

No creator, Archive, Export, candidate retry, network, App Store action, push, or merge occurred.
