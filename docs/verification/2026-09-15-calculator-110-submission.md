# Knitting Calculator 1.1.0 submission preparation

- Source commit: 6f43557bf04b5822c5569ec34a17a86f862eab5d
- Branch: feature/calculator-stitch-dictionary
- Bundle: com.phillon.KnittingCalculator
- Version/build: 1.1.0 (4)
- Archive: /private/tmp/Calculator-1.1.0-4-videos.xcarchive
- Audited IPA: /private/tmp/calculator-110-video-export/KnittingCalculator.ipa
- IPA SHA256: 7e9e598b4fb7720349ce23cd050c09c5092da8e84458570ee24ba07536479161
- Final IPA audit passed: static scope, structure, version/build, localization, App Store Distribution signing.
- Xcode export/upload from the same archive succeeded 2026-09-15 23:37 Asia/Taipei. Automatic version/build management disabled.
- App Store Connect version 1.1.0 created; manual release retained.
- What's New updated in all 13 existing locales. Saved values checked after navigation/reload; Korean, Norwegian and Greek required a second save and were then verified.
- Review notes explain all 15 dictionary entries have external video tutorial pages, network required for videos, no sign-in, no account or purchase, offline calculators/dictionary, local drafts.
- Existing contact information and product-page screenshots retained.
- KnitNote video correction separately committed as 8fe9da8 on local main; no KnitNote upload.

Build processing and final review submission are still pending at this checkpoint.

## Build processing and export declaration checkpoint

- App Store Connect build ID: 6c11be33-2a04-46a8-8651-c51e25874450.
- Upload status: Complete. TestFlight 1.1.0 (4): Missing Export Compliance.
- Automatic approval review rejected selecting/submitting the answer that none of the listed non-Apple encryption algorithms are used. No declaration was changed.
- Follow-up technical check found no CryptoKit/CommonCrypto/Security imports, custom encryption APIs, URLSession or NWConnection in Calculator production Swift sources. The package has no external dependencies; archived binary links only Apple frameworks and Swift/system libraries. Tutorial links use SwiftUI Link to open external provider pages.
- User confirmation of the exact export declaration is required before proceeding. No App Review submission has occurred at this checkpoint.
- A subsequent attempt to associate Build 4 with the version was also rejected by automatic approval review because export compliance was still missing. Build association remains pending; no workaround was attempted.

## Final submission — 2026-09-15 23:51 Asia/Taipei

- User completed the export declaration personally. A refreshed build picker no longer showed missing export compliance.
- Build 4 was associated with version 1.1.0 and saved, then formally submitted for App Review.
- App Store Connect confirmed one submitted item and the submission detail page showed Waiting for Review (等待審查) for 1.1.0 (4).
- Submission ID: f1fad043-6fec-45cd-b55e-a6e6504f3057.
- Submission date displayed: 2026-09-15 23:51.
- Review detail: https://appstoreconnect.apple.com/apps/6795877892/distribution/reviewsubmissions/details/f1fad043-6fec-45cd-b55e-a6e6504f3057
- Manual release remains selected. Approval and publication are still pending.
- No Git push or KnitNote store upload was performed.
