# SDD ledger — plan: docs/superpowers/plans/2026-08-13-pattern-folders.md

Plan base: 0c728eeb4abf77eb27d34eb27ac38f8a28d302d0
Task 1: complete (commits 0c728ee..e56379e, review clean)
Task 1 follow-through for Task 2: archive normalization must address malformed historical untrimmed folder names
Task 2: pending
Task 2: BLOCKED — schema 13 makes release_audit.sh schema-12 pin fail; Task 7 requires full suite green, but the current plan forbids release-script changes and assigns no later task to update the audit contract
Task 2 Fix Round 1 authorization (2026-08-14): user selected option 1 and explicitly authorized synchronizing schema 13 into `AppStore/Verification/release_audit.sh` and related fail-closed tests. This scope override permits development audit/test changes only; no archive, export, upload, App Store Connect, submission, or release action.
Task 2 Fix Round 1: commit 12098b8; original release-contract Important/Major and all three coverage Minors closed. Focused Task 2 153/153, ReleaseAudit 56/56, static audit PASS. Sole full-suite run was 1493/1494 due an unrelated 2-second PatternShareInboxEnqueuer timeout; isolated rerun 1/1 PASS.
Task 2 Fix Round 2: commit 4c8787f; added schema declaration decoy/duplicate rejection. Review found nested same-name ProjectArchive could still bypass top-level binding.
Task 2 Fix Round 3: commit 3527cb2; added top-level/nested/comment/multiline-string mutation hardening and wrapped schema-12/14 fixtures. Final review still found an Important fail-open: four-space indentation is treated as direct-member scope without brace-depth tracking, so a valid differently indented real schema-12 member plus nested four-space schema-13 decoy can pass.
Task 2 final SDD status: BLOCKED after three fix rounds; SPEC FAIL / QUALITY FAIL. Do not mark clean/final or advance to Task 3 until a new user-authorized design/fix cycle replaces indentation inference with brace-depth-aware structural parsing (or an equally fail-closed source-of-truth check), adds the exact regression, and receives fresh review approval.
Task 2 authorized replacement design cycle: complete at e73cf50 via canonical compiled schema source and whole-file byte audit; independent task review and final whole-branch review both clean with no Critical/Important/Minor. Prior structural blocker CLOSED. Full Swift Testing summary 1496/126 PASS; fresh reviewer iOS unsigned build PASS; static/Task2/ReleaseAudit/macOS/watch gates PASS. Task 2: complete (commits e56379e..e73cf50, review clean).
Task 3: pending
Task 3: minor (deferred): store tests omit explicit empty-name rejection with exact state/archive preservation.
Task 3: minor (deferred): delete-folder test covers one moved pattern but not multiple matches plus unrelated patterns.
Task 3: concern (deferred to presentation task): selection preservation is not observable in JSONProjectStore because the store owns no selection state.
Task 3: complete (commits e73cf50..cb9a502, spec PASS / quality PASS, no Critical/Important)
Task 4: pending
Task 4: minor (deferred): explicit duplicate `.createNew` file-import branch lacks a direct assertion that the newly created copy receives the captured destination folder.
Task 4: minor (deferred): Share Extension and project-import tests do not directly assert `targetFolderID == nil`.
Task 4: complete (commits cb9a502..4f8af20, spec PASS / quality PASS, no Critical/Important)
Task 5: pending
Task 5 sequencing override (2026-08-14, user selected option 1): pause after tests-only RED; execute Task 6 localization first, then resume Task 5. Task 5 scope is expanded by one `Sources/KnitNoteCore/Patterns/PatternFolderPresentation.swift` policy file so package tests exercise ordering/count/selection behavior directly; app views consume that policy. Do not hard-code translated reserved names in Swift.
Task 5 tests-only RED preserved in git stash `task5-tests-only-red-before-task6` (also copied to `/tmp/knitnote-task5-red-tests.patch`, SHA-256 712a24a151017b1ffb7bdfe142b3b1cdf1092587ed400acc1ac7afa97e1e8de2). Restore after Task 6 localization commit.
Task 5: complete at `2ece295`; independent review SPEC PASS / QUALITY PASS with no findings. Restored RED was converted to real core behavior coverage under the approved scope override; adaptive sidebar/detail UI, folder CRUD/move/import scope, durable-success-only selection change, 13-locale resolver-backed reserved names, and deferred Task 6 accessibility source requirements are implemented. Required focused selection 75/75 PASS, combined localization/accessibility selection 102/102 PASS, deterministic XcodeGen SHA `c3b2be0d83aef5a900f01c53cc02f6b7a0f631deab97eeb5dce6fff7645b560f`, fresh unsigned iOS Simulator/macOS builds PASS. Physical acceptance remains Task 7.
Task 6: pending
Task 6 sequencing override: complete catalog, structural, token, terminology, and linguistic contracts first. Defer source accessibility assertions in `PatternLibraryViewContractTests.swift` until Task 5 creates the UI; Task 5 must then close Task 6 Step 1 accessibility-label/hint requirements before its own review.
Task 6 deferred accessibility implementation: approved by the clean Task 5 independent review. Explicit localized label/hint/current-selection/count source contracts pass in the combined 102-test selection. This deferred implementation concern is CLOSED; do not mark overall Task 6 complete until the final combined Task 6 review approves the complete localization/accessibility candidate.
Task 6 final combined review at `2ece295`: SPEC FAIL / QUALITY FAIL with one Important contract-only finding. Production UI remained source-compliant, but the file-wide accessibility assertions false-passed after independent removal of New label, Rename hint, Delete count-aware hint, New 44-by-44 frame, or the count inside the sidebar-row accessibility label.
Task 6 accessibility contract Fix Round 1: implementation complete / review-pending. `PatternLibraryViewContractTests` now slices the exact sidebar row, New/Rename/Delete controls, editor field/actions, move destination, and collection Move action before asserting each control's label/hint/minimum size/selected trait/count. All five cited mutations independently RED at their intended scoped assertion; restored source GREEN 16/16, Task 5 focused 75/75, and Task 6 combined 102/102. No production/project/catalog change; await fresh combined Task 6 review.
Task 7: pending

Task 2 authorized schema-source design cycle (2026-08-14): implementation commit pending independent review. The indentation-parser workaround is replaced by the dedicated canonical compiled schema source and exact-byte audit. Task 2 status: review-pending (not complete); await independent spec/quality review before advancing Task 3.
