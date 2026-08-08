# KnitNote 1.4.1 Two-Stage Distribution Export Design

## Problem

Xcode-managed Store profiles cannot be selected by manual signing. Automatic Archive creation signs the archive for development, and forcing `Apple Distribution` conflicts with automatic provisioning. A read-only local probe proved the Apple-supported two-stage flow works with the existing signing assets:

1. create an automatic development-signed Archive;
2. run `xcodebuild -exportArchive` with `method=app-store-connect`, `destination=export`, and automatic export signing.

The exported iOS IPA and macOS pkg use Apple Distribution and the correct existing Store profiles for the main app, Watch app, Share extension, and Mac app. No app upload or profile update is required. macOS export may contact authorized Apple developer services for managed installer-package signing; that remote signing boundary is not an App Store mutation.

## Design

1. Restore standard automatic Development signing for Debug and Release Archive creation. Remove manual Store-profile bindings from project build settings.
2. Add a checked-in App Store export-options plist that:
   - exports locally instead of uploading;
   - uses automatic export signing for team `9CFPAUL5N5`;
   - preserves version/build numbers;
   - uses the App Store Connect method.
3. Harden `create_release_candidate.sh` to:
   - preflight the expected local Distribution identity;
   - create clean exact-commit iOS/Watch and macOS Archives with automatic development signing;
   - export each Archive locally into `Distribution/iOS` and `Distribution/macOS`;
   - create provenance only after both exports exist;
   - run the formal audit before publishing the candidate directory.
4. Change the formal archive audit to inspect the actual exported products:
   - unpack `Distribution/iOS/KnitNote.ipa` and audit its main, Watch, and Share bundles;
   - expand `Distribution/macOS/KnitNote.pkg` and audit its Mac app;
   - retain exact version/build/source/locales/privacy/entitlement/profile/certificate checks;
   - require Apple Distribution and the expected team for every exported product.
5. Extend deterministic provenance to include both exported upload artifacts and their distribution summaries/export options, in addition to the source Archives.

## Boundaries

- No App behavior, data, localization, version `1.4.1`, or build `8` changes.
- No profile/certificate creation, download, mutation, provisioning update, upload, submission, pricing, build selection, or App Store Connect mutation.
- Export must run with `destination=export`; `destination=upload` and `-allowProvisioningUpdates` are forbidden.
- A local macOS export may use authorized Apple developer-service network access for managed package signing. It remains forbidden to upload the app, mutate App Store Connect, or request provisioning updates.
- The original Archives are build inputs; the exported IPA/pkg are the Distribution-signed products that determine candidate clearance.
- Physical acceptance and App Store parity remain separate after a formal audit passes.
