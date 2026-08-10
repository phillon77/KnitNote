# Dutch Metadata Parser Final Fix Design

Date: 2026-08-10

## Goal

Close the two remaining bounded Dutch App Store metadata validation gaps
without changing store copy, app behavior, version/build identity, or release
state.

## Scope

Only these files may change during implementation:

- `AppStore/Verification/metadata_check.py`
- `AppStore/Verification/metadata_check_test.py`

The existing thirteen-locale metadata packages remain unchanged.

## Additive contrast rule

`niet alleen ... maar ook` after an already completed prohibited relation is
additive, not a negation of that relation. The checker currently recognizes
only exact `maar ook` adjacency.

The bounded fix accepts either:

- `maar ook`
- `maar <one approved modifier> ook`

The approved modifier set is limited to the reviewed natural forms `vooral`
and `nu`. Standalone negation and earlier cross-branch cases retain their
existing behavior. The implementation must not scan an unbounded number of
tokens between `maar` and `ook`.

## Backup-source attachment rule

A recovery action sourced from a backup remains a prohibited deleted-project
recovery claim. The source markers `met`, `vanuit`, `via`, and `uit` count only
when they structurally introduce the backup noun phrase.

The bounded noun phrase may contain:

- a directly adjacent `reservekopie*` noun; or
- one approved article, possessive, or demonstrative before the noun; or
- that approved determiner plus at most one adjective before the noun.

The determiner set is extended with `je`, `jouw`, `hun`, and `deze`. An
intervening content noun such as `menu` or `tik` is not attached to the later
backup object, including plural `reservekopieën`. Existing safe phrases such as
`met één tik`, `via het menu`, and `uit voorzorg` must remain accepted.

## Test strategy

Tests are written and observed failing before production changes.

Positive prohibited-claim regressions cover:

- two recovery and two Share claims using `maar vooral ook` or `maar nu ook`;
- four source-attached recovery claims using `je`, `jouw`, `hun`, and `deze`.

Safe-copy regressions cover:

- plural backup objects after `via het menu` and `met een tik`.

After the minimal fix, run the full metadata unit suite and the repository
metadata checker. Existing prior recovery/Share matrices must remain green.

## Boundaries

This work does not perform native-language editorial acceptance, change any
metadata package, archive/export a build, upload, submit, merge, or push. It
only clears the checker review gate; physical and release gates remain
separate.
