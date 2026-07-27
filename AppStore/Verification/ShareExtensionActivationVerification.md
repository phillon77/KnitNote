# Share Extension Activation Verification

- Date: 2026-07-27
- Device: iPhone 17 Pro Max, iOS 26.5.2
- Root-cause diagnostic: not re-run in this task; it is not used as final evidence.
- Focused contract test: `swift test --disable-sandbox --filter ShareExtensionTargetContractTests` on 2026-07-27 — 3 tests in 1 suite, 0 failures, exit 0.
- Full Swift suite: `swift test --disable-sandbox` — 830 tests in 68 suites, 0 failures, exit 0.
- iOS build: the required clean iOS `xcodebuild` command completed with exit 0.
- macOS build: the required clean macOS `xcodebuild` command completed with exit 0.
- Embedded extension rule: canonical nested `SUBQUERY` clauses for one extension item and one attachment, with the supported PDF/PNG/JPEG/HEIC UTI checks; no permissive predicate was present. The embedded extension existed and `codesign --verify --deep --strict` exited 0 outside the sandbox.
- Physical PDF share sheet: KnitNote was visible for the single `KnitNote-Share-Test.pdf` share on iPhone 17 Pro Max.
- Physical import: imported file was visible in 織圖 as `Pattern`, `PDF・共 1 頁`; its detail view reported `檔案大小 3 kB`.
- Duplicate import: pass. At 12:28, Files shared the same `KnitNote-Share-Test.pdf` again; the formal nested-rule build's share sheet showed KnitNote directly, and selecting it returned to Files. At 12:29, KnitNote showed the toast `已收藏分享的織圖`; 織圖 still contained only one `Pattern` row (alongside the pre-existing Ida item), with no second duplicate Pattern. `Pattern` still reported `PDF・共 1 頁` and `檔案大小 3 kB`.
