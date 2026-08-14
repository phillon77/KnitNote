# Project Archive Schema Source Design

Date: 2026-08-14

## Context

Pattern folders raise `ProjectArchive.currentVersion` from 12 to 13. The live
release audit must fail closed when the source archive schema and the audited
schema disagree.

The first implementation searched `JSONProjectStore.swift` with progressively
stricter text parsers. Independent review showed that indentation, nested types,
comments, and multiline strings can still create decoys. Continuing to extend a
partial Swift parser would make the release gate harder to reason about.

## Decision

Move the archive version declaration into a dedicated, canonical Swift source
file:

`Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift`

Its complete contents are:

```swift
extension ProjectArchive {
    public static let currentVersion = 13
}
```

Remove the existing `currentVersion` declaration from
`JSONProjectStore.swift`. Runtime code continues to use
`ProjectArchive.currentVersion`; no archive format or migration behavior changes
in this fix.

## Audit Contract

`AppStore/Verification/release_audit.sh` compares the complete bytes of the
dedicated schema file with the canonical schema-13 contents. It does not infer
Swift structure from indentation, regular expressions, comments, strings, or
brace depth.

The static audit fails when the file is missing or when any byte differs,
including:

- schema 12 or schema 14;
- an additional declaration;
- a nested-type decoy;
- a comment or string containing a matching declaration;
- extra executable or declarative content;
- ambiguous or reformatted content.

The canonical formatting requirement is intentional. A future schema bump must
update the dedicated file, the audit expectation, current submission
documentation, and the associated tests in the same reviewed change.

The Swift compiler is the complementary structural gate: because the canonical
file extends the real `ProjectArchive` type, a conflicting duplicate
`currentVersion` in the module cannot compile. Static audit and compilation are
both required; neither is presented as a substitute for the other.

## Tests

TDD coverage must first demonstrate that the existing parser falsely accepts
the final reviewed nested/direct-member decoy. The implementation then replaces
that parser and proves:

- the canonical schema-13 file passes;
- schema-12 and schema-14 canonical variants fail;
- appended/prepended declarations fail;
- comment, multiline-string, nested-type, and duplicate decoys fail;
- `ProjectArchive.currentVersion` is 13 at runtime;
- release configuration tests, the static release audit, and release-audit
  fixtures pass;
- the complete Swift test suite passes before the task is called complete.

## Scope and Safety

Allowed changes are limited to the dedicated schema source, removal of the old
declaration, the live release audit and current schema documentation, related
tests, and generated project membership if XcodeGen requires it.

This work does not change version/build identity, signing, localization,
metadata copy, archive contents beyond the already-approved schema-13 model, or
user-created data. It does not authorize archive, export, upload, App Store
Connect, submission, or release actions.

Existing untracked workspace content must remain untouched.

## Acceptance

The design is accepted only when an independent review finds no Critical or
Important issue in the canonical-file binding, all required tests and audits
are green, and the worktree retains only the pre-existing untracked paths.
