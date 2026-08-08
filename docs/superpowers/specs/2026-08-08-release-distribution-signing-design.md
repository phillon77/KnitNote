# KnitNote 1.4.1 Distribution Signing Design

## Problem

The exact `1.4.1 (8)` archives pass source, localization, privacy, entitlement, and code-signature-integrity checks, but every bundled product is signed with `Apple Development`. The formal archive audit correctly rejects them because an App Store candidate must use the expected `Apple Distribution` certificate for team `9CFPAUL5N5`.

The machine already has a valid `Apple Distribution: Chen Chung Lung (9CFPAUL5N5)` identity. The checked-in generated Xcode project explicitly selects `iPhone Developer` for both Debug and Release, while `project.yml` does not declare the intended per-configuration identity. The supported candidate creator also does not force distribution signing.

## Design

1. Make `project.yml` the signing source of truth:
   - Debug uses `Apple Development`.
   - Release uses `Apple Distribution`.
   - The existing team remains `9CFPAUL5N5`.
2. Regenerate `KnitNote.xcodeproj` so manual Xcode Archives inherit the same contract.
3. Harden `create_release_candidate.sh`:
   - fail early unless the expected team's local Apple Distribution identity exists;
   - pass `CODE_SIGN_STYLE=Automatic`, `DEVELOPMENT_TEAM=9CFPAUL5N5`, and `CODE_SIGN_IDENTITY=Apple Distribution` to both archive invocations;
   - do not download profiles or mutate signing assets.
4. Extend source-contract tests before implementation, then rebuild and rerun the existing formal archive audit.

## Boundaries

- No App source, behavior, data, localization, version, or build-number changes.
- No certificate/profile creation, download, network provisioning, upload, submission, pricing, or App Store Connect changes.
- The release audit remains fail-closed and is not weakened.
- A signed Archive is not release approval; physical and App Store parity gates remain separate.
