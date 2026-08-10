# KnitNote macOS Package Permissions and Build 10 Design

## Goal

Produce one synchronized KnitNote 1.5.0 (Build 10) release candidate whose
iOS, iPadOS, watchOS, Share extension, and macOS products come from one exact
commit, pass the checked-in release audit, and upload to App Store Connect
without submitting for review.

## Observed Failure

The exact 1.5.0 (Build 9) candidate at commit
`6b013d9f091e5f04c0ee2bf25e77fa98556da70c` passed local provenance and formal
release audit. Its iOS, iPadOS, and watchOS binary uploaded successfully. Apple
rejected the macOS upload with error `90255` because the installer contained
files readable only by the owner.

The rejected archive contains
`KnitNote.app/Contents/_CodeSignature/CodeResources` with mode `0600`. The
successful 1.0.0 macOS archives contain the same file with mode `0644`. The
candidate creator sets `umask 077` before invoking Xcode, so files created by
codesign and export inherit an inappropriate release-product mode.

## Design

### Private staging, standard product permissions

The creator continues to start with `umask 077` and creates its staging and
worktree directories before changing the mask. Those parent directories stay
private. Before any Xcode archive or export command, the creator changes to
`umask 022`, allowing signed product files to receive standard readable modes.
The final candidate root remains explicitly `0700`, raw `Packaging.log` files
remain deleted, and the atomic publication flow remains unchanged.

The fix must not chmod files inside a signed application after signing. Doing
so would treat the symptom after code signing and could invalidate or obscure
the package's signed state.

### Fail-closed release audit

After expanding the exported macOS package, the production release audit must
reject:

- any regular file within `KnitNote.app` that is not world-readable; and
- any directory within `KnitNote.app` that is not world-searchable.

This permission gate runs against the exported PKG payload, not merely the
archive. Existing signature, provisioning-profile, entitlement, localization,
privacy, inventory, and provenance checks remain in force.

### TDD coverage

Tests first reproduce both missing guarantees:

1. a macOS exported app containing a `0600` signature resource is incorrectly
   accepted by the current audit; and
2. the creator's test harness observes `0077` during Xcode archive/export
   invocations instead of the required `0022`.

The minimal production changes then make those tests pass. Existing creator
ordering, override, atomic publication, raw-log, and distribution-signing
contracts must remain green.

## Build Identity and Publication

All shipping targets move together from 1.5.0 (Build 9) to 1.5.0 (Build 10).
The generated Xcode project, release audit constants, candidate identity tests,
and screenshot/release instructions must agree on Build 10. The marketing
version and thirteen localized What's New packages remain 1.5.0.

The Build 10 creator runs exactly once after focused tests, the complete Swift
suite, static audit, XcodeGen drift checks, and required unsigned builds pass.
The resulting IPA and PKG receive independent provenance, formal-audit, signing,
profile, entitlement, privacy, localization, revision, and permission checks.

Both Build 10 platform binaries are then uploaded to App Store Connect. The
already uploaded iOS Build 9 remains unused and is not selected for release.
No workflow in this task may add for review, submit for review, automatically
release, merge, or push.

## Success Criteria

- The permission regressions fail before the production fix and pass after it.
- All shipping targets report 1.5.0 (Build 10) and one exact source revision.
- The complete Swift suite and production release audit pass.
- The expanded macOS PKG has no unreadable files or unsearchable directories.
- Xcode reports `Uploaded to Apple` for both iOS and macOS Build 10.
- App Store Connect submission and release actions remain untouched.
