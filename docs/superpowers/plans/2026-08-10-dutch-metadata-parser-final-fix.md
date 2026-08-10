# Dutch Metadata Parser Final Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the two remaining bounded Dutch App Store metadata claim-detection gaps without changing metadata copy or release state.

**Architecture:** Extend the existing token-based Dutch relation parser rather than adding phrase-specific regex exceptions. One bounded helper recognizes `maar ook` with at most one approved modifier, and the existing backup attachment helper validates only noun phrases structurally attached to `reservekopie*`.

**Tech Stack:** Python 3 standard library, `unittest`, repository metadata validator.

## Global Constraints

- Modify only `AppStore/Verification/metadata_check.py` and `AppStore/Verification/metadata_check_test.py`.
- Do not change any App Store metadata package, app source, version/build, signing, archive, upload, submission, merge, or push state.
- Add tests first and observe the expected failures before production changes.
- Keep contrast scanning bounded to zero or one approved modifier between `maar` and `ook`.
- Keep backup-source recognition bounded to the reviewed backup noun phrase; do not introduce general Dutch NLP.
- Preserve all prior recovery/Share prohibited-claim and safe-copy behavior.

---

### Task 1: Bind Dutch contrast and backup-source attachments

**Files:**
- Modify: `AppStore/Verification/metadata_check_test.py`
- Modify: `AppStore/Verification/metadata_check.py`

**Interfaces:**
- Consumes: `validate(path: Path) -> list[str]`, `dutch_is_completed_additive_negation(...) -> bool`, and `dutch_backup_has_source_attachment(...) -> bool`.
- Produces: bounded additive-contrast recognition and structurally attached backup-source recognition used by the existing Dutch forbidden-claim validator.

- [ ] **Step 1: Add the failing contrast and source-attachment regressions**

Extend `test_dutch_recovery_and_share_concept_matrix` with these prohibited cases:

```python
(
    "completed recovery relation with vooral ook",
    "deleted project recovery",
    "Herstel een verwijderd project niet alleen snel maar vooral ook veilig.",
),
(
    "completed plural recovery relation with nu ook",
    "deleted project recovery",
    "Verwijderde projecten herstel je niet alleen snel maar nu ook volledig.",
),
(
    "completed Share relation with vooral ook",
    "Share system-only language",
    "De deel-extensie gebruikt uitsluitend de systeemtaal niet alleen voor titels maar vooral ook voor knoppen.",
),
(
    "completed Share relation with nu ook",
    "Share system-only language",
    "Het deelscherm toont uitsluitend de systeemtaal niet alleen in menu's maar nu ook in meldingen.",
),
(
    "backup source with informal possessive",
    "deleted project recovery",
    "Verwijderde projecten herstellen via je reservekopie.",
),
(
    "backup source with formal possessive",
    "deleted project recovery",
    "Verwijderde projecten herstellen vanuit jouw reservekopie.",
),
(
    "backup source with plural possessive",
    "deleted project recovery",
    "Verwijderde projecten herstellen uit hun reservekopie.",
),
(
    "backup source with demonstrative",
    "deleted project recovery",
    "Verwijderde projecten herstellen via deze reservekopie.",
),
```

Extend `safe_recovery_cases` with:

```python
"Bij een verwijderd project herstel je via het menu reservekopieën.",
"Bij een verwijderd project herstel je met een tik reservekopieën.",
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
python3 -m unittest \
  AppStore.Verification.metadata_check_test.MetadataCheckTests.test_dutch_recovery_and_share_concept_matrix
```

Expected: FAIL with ten subtest failures: eight prohibited claims are not detected and two safe plural backup descriptions are falsely rejected.

- [ ] **Step 3: Implement the minimal bounded contrast rule**

Add an approved-modifier constant beside the existing Dutch token constants:

```python
DUTCH_ADDITIVE_MODIFIERS = frozenset({"vooral", "nu"})
```

Replace the exact `branch_end + 1 == "ook"` condition in
`dutch_is_completed_additive_negation` with a bounded suffix check:

```python
additive_suffix = tokens[branch_end + 1:branch_end + 3]
has_additive_suffix = (
    additive_suffix[:1] == ["ook"]
    or (
        len(additive_suffix) == 2
        and additive_suffix[0] in DUTCH_ADDITIVE_MODIFIERS
        and additive_suffix[1] == "ook"
    )
)
```

Require `has_additive_suffix` in the return expression. Do not scan beyond two tokens after `maar`.

- [ ] **Step 4: Implement the minimal backup noun-phrase attachment rule**

Extend `DUTCH_BACKUP_DETERMINERS` with:

```python
{"je", "jouw", "hun", "deze"}
```

Add the single reviewed adjective used by the existing positive matrix:

```python
DUTCH_BACKUP_ADJECTIVES = frozenset({"oude"})
```

In `dutch_backup_has_source_attachment`, require the tokens between the source marker and `reservekopie*` to match one of these bounded shapes:

```python
[]
[approved_determiner]
[approved_determiner, approved_adjective]
```

Implement the three shapes exactly:

```python
if not noun_phrase:
    return True
if len(noun_phrase) == 1:
    return noun_phrase[0] in DUTCH_BACKUP_DETERMINERS
return (
    len(noun_phrase) == 2
    and noun_phrase[0] in DUTCH_BACKUP_DETERMINERS
    and noun_phrase[1] in DUTCH_BACKUP_ADJECTIVES
)
```

This keeps `via het menu reservekopieën` and `met een tik reservekopieën` safe while preserving `vanuit de oude reservekopie` as a source attachment.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run:

```bash
python3 -m unittest \
  AppStore.Verification.metadata_check_test.MetadataCheckTests.test_dutch_recovery_and_share_concept_matrix
```

Expected: PASS, including all prior and ten new matrix cases.

- [ ] **Step 6: Run the complete metadata verification**

Run:

```bash
python3 -m unittest AppStore/Verification/metadata_check_test.py
python3 AppStore/Verification/metadata_check.py
git diff --check
```

Expected: all metadata unit tests pass, checker prints `METADATA CHECK: PASS`, and diff check exits 0.

- [ ] **Step 7: Review the exact scope and commit**

Run:

```bash
git diff -- AppStore/Verification/metadata_check.py \
  AppStore/Verification/metadata_check_test.py
git status --short
git add AppStore/Verification/metadata_check.py \
  AppStore/Verification/metadata_check_test.py
git commit -m "fix: close Dutch metadata parser gaps"
```

Expected: the commit changes exactly the checker and its test; the pre-existing untracked `.superpowers/brainstorm/`, `AppStore/Verification/CounterReminders150Verification.md`, `build/`, and `task-3-report.md` remain untouched.

- [ ] **Step 8: Request independent review**

The reviewer must independently rerun the focused ten-case matrix, complete metadata unit suite, metadata checker, and inspect that no metadata package or release state changed. Any finding is fixed in a new commit with a new RED/GREEN cycle.
