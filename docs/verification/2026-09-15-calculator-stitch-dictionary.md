# Calculator stitch dictionary verification

Ports the link-based KnitNote dictionary from commit 48a7a6aafc147adaee658cc9daf74f92b1ce9849 into Knitting Calculator. Includes 15 knitting stitches, multilingual search, source-specific chart symbols and external teaching/reference links. Detail views do not display procedural diagrams. Calculator theme and localization are used; data is bundled in KnittingCalculatorCore.

Validation on 2026-09-15:
- Full Calculator core suite: 46 tests across 6 suites passed.
- Calculator app suite: 7 tests passed on iPad simulator, iOS 26.5.
- Generic iOS device build succeeded; version remains 1.0.1 (3).
- Simulator UI: home dictionary entry opens, all 15 entries appear, k1 search resolves to Knit with repeat count 1, detail exposes teaching/reference links without procedural steps.
- Updated app installed successfully on the previously selected iPad Air 5. Physical user acceptance is pending.
- git diff --check passed.

Offline bundled lookup is distinct from external tutorials, which require network. Calculator-specific VoiceOver, large text and multilingual manual acceptance were not completed in this pass. Installation does not establish physical UI acceptance. No store upload or remote Git push performed.
