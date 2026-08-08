# KnitNote 1.4.1 Release Screenshot Python Runtime Design

## Problem

The production release audit resets `PATH` to trusted system locations. Its Swift screenshot tests then launch `python3` through `/usr/bin/env`. On the release Mac this resolves to Xcode's arm64 Python, while the user-site Pillow binary is x86_64. Pillow cannot load, so three screenshot tests report 21 cascading issues after otherwise valid iOS, Watch, and macOS archives are built.

The same tests pass outside the release audit because the interactive shell resolves an x86_64 Python that matches the installed x86_64 Pillow. The result therefore depends on ambient `PATH`, which is unsuitable for a release gate.

## Decision

Add a checked-in, offline screenshot Python launcher. It will examine a small deterministic list of local Python candidates and select the first interpreter that can import the required Pillow modules successfully. It will then `exec` that interpreter with the caller's original arguments.

All screenshot validation, composition, provenance, and their Swift contract tests will use this launcher instead of invoking ambient `python3` directly. Candidate selection must not download packages, modify the user's Python installation, accept an environment override in production, or weaken the release audit.

## Boundaries

- This is developer tooling only; no Python or Pillow files are included in any App bundle.
- App behavior, user data, localization catalogs, version `1.4.1`, and build `8` remain unchanged.
- The launcher must fail clearly when no compatible Pillow runtime exists.
- The release audit continues to run the full Swift suite and all screenshot checks.

## Verification

1. A regression test supplies an incompatible first Python candidate and a compatible later candidate, then proves the launcher chooses the compatible runtime.
2. Existing screenshot fixture tests pass under the production audit's trusted `PATH`.
3. The full 1,348-test suite passes.
4. A fresh signed iOS/Watch and macOS candidate is created from the new exact commit, and the formal archive audit passes.

