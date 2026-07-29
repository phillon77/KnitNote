# Knitting Calculator physical verification

## Independent project release-audit evidence — 2026-07-29

### Candidate and preserved Task 12 input

- Migration branch: `codex/knitting-calculator-independent-project`
- Task 4 base commit: `b2fa89cee48f0530598a93029cc5984010ae8f99`
- Independent project: `KnittingCalculator.xcodeproj`
- Scheme: `KnittingCalculator`
- Expected identity: `com.phillon.KnittingCalculator`, version/build `1.0.0 (1)`
- The archive was built from the Task 4 working tree based on the commit above.
  The final Task 4 commit is the commit containing this evidence section.
- No App Store Connect record, upload, submit, Git remote, merge, or push action
  was performed.

The interrupted Task 12 source was imported from
`/Users/longzhenzhong/Documents/Codex/2026-07-28/app/knitting-calculator`.
The two untracked files were byte-identical before Task 4 edits (`cmp` exit 0);
the two tracked test deltas were merged into the newer independent-project
contracts instead of replacing them.

| Preserved source file | Source SHA-256 | Import |
| --- | --- | --- |
| `Tests/KnitNoteCoreTests/KnittingCalculatorProjectContractTests.swift` | `f57c7a91532a2534c491db9c05f7af4fab40b22c1f9d6f530fde77405530b51c` | Prior `freeAppReleaseAuditPinsIdentityAndRejectsSentinels` delta merged. |
| `Tests/KnitNoteCoreTests/PrivacyManifestContractTests.swift` | `e2e618adde9ed26e017d8e9970bfb4e18b4c638a1e8a1eb4b41798603c67949b` | Prior calculator privacy-manifest delta merged. |
| `AppStore/Verification/knitting_calculator_release_audit.sh` | `441612e2640fd236b894eb5f4c3f814fc200739998ea48d80b602622c30b89b0` | Imported byte-identically, then isolated through TDD. |
| `AppStore/Verification/KnittingCalculatorPhysicalVerification.md` | `5beb4c288b8e3e151a6e267619c121378c88705d6debb272761691fafe9ba915` | Imported byte-identically, then this evidence was appended. |

### TDD and project-scope audit

The new `releaseAuditTargetsOnlyTheIndependentCalculatorProject` contract was
first run against the preserved script and failed because the script had no
independent spec/project declarations and still let XcodeGen default to the
root `project.yml`. After the change, this command passed all 12 project
contract tests:

```bash
swift test --filter KnittingCalculatorProjectContractTests
```

The audit now pins:

- `PROJECT_SPEC="KnittingCalculator/project.yml"`
- `PROJECT_FILE="KnittingCalculator.xcodeproj"`
- XcodeGen `--spec "$PROJECT_SPEC"` with repository `--project-root`
- an `xcodebuild -list -json` topology containing exactly
  `KnittingCalculator` and `KnittingCalculatorTests`
- calculator-only `git diff --check` paths

It contains no reference to `KnitNote.xcodeproj`, `KnitNoteWatch`, or
`KnitNoteShare`; therefore their target packaging and version state cannot
change this audit result.

### Independent signed archive

The first archive used only existing local automatic-signing material. It did
not use `-allowProvisioningUpdates`:

```bash
xcodebuild archive \
  -project KnittingCalculator.xcodeproj \
  -scheme KnittingCalculator \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/KnittingCalculatorIndependent.xcarchive \
  -derivedDataPath /tmp/KnittingCalculatorIndependentArchive
```

Result: `** ARCHIVE SUCCEEDED **`.

| Archive check | Result | Evidence |
| --- | --- | --- |
| Bundle identifier | PASS | `com.phillon.KnittingCalculator` |
| Version/build | PASS | `1.0.0 (1)` |
| Required resources | PASS | `Assets.car`, `PrivacyInfo.xcprivacy`, and `en` / `zh-Hant` `Localizable.strings` plus `InfoPlist.strings` are present. |
| Prohibited app capabilities | PASS | No app group, iCloud, push, camera, photo, document, or file-browser declaration. |
| Signature integrity in the normal Keychain context | PASS | `codesign --verify --deep --strict --verbose=2` reported valid on disk and satisfied its designated requirement. |
| Distribution signing | BLOCKED | Xcode selected `Apple Development: lzz.1999@gmail.com (6VTQJ4MR59)` and wildcard profile `bb3d61d1-4aa7-4ef9-ab1b-712da0f32a20`. The decoded profile has `application-identifier=9CFPAUL5N5.*`, `get-task-allow=true`, no `beta-reports-active`, and a `ProvisionedDevices` list. Its leaf identity is not Apple Distribution. |
| Restricted/sandbox trust check | BLOCKED | A separate restricted-context strict verification reported `CSSMERR_TP_NOT_TRUSTED`; no release claim relies on that context passing. |

Archive artifact SHA-256:

- executable:
  `b51cee070e487860de437fb3397c9219827febff28bae50c8abf161362b63062`
- `Info.plist`:
  `e2550a6d7857eef4d977aacd8402633024cbe2d66fe5944fab313ccd4bef3756`

### Audit results and App Store signing

Static-only command:

```bash
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
```

Result:

```text
KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS
KNITTING CALCULATOR RELEASE AUDIT: PASS
```

Archive command:

```bash
AppStore/Verification/knitting_calculator_release_audit.sh \
  --archive /tmp/KnittingCalculatorIndependent.xcarchive
```

Result:

```text
KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS
KNITTING CALCULATOR RELEASE AUDIT: ARCHIVE STRUCTURE PASS
KNITTING CALCULATOR RELEASE AUDIT: FAIL — embedded profile is missing beta-reports-active
```

App Store Connect record created on 2026-07-29:

- App name: `編織計算器`
- Apple ID: `6795877892`
- Bundle ID: `com.phillon.KnittingCalculator`
- SKU: `com.phillon.KnittingCalculator`
- Primary language: Traditional Chinese
- Platform/version state: iOS 1.0, Prepare for Submission

`CalculatorShareText.swift` now uses the calculator's own public destination,
`https://apps.apple.com/app/id6795877892`. The existing
`https://apps.apple.com/app/id6793023054` remains the KnitNote promotion
destination.

App Store signing completed locally on 2026-07-29:

- development archive:
  `/tmp/KnittingCalculatorAppStore-20260729.xcarchive`
- exported App Store IPA:
  `/tmp/KnittingCalculatorAppStoreExport-20260729/KnittingCalculator.ipa`
- IPA SHA-256:
  `720dcb242f6bd56d0e216a860a5e23e5b80113fecfe2cc45be0b9585e74286a0`
- provisioning profile:
  `iOS Team Store Provisioning Profile: com.phillon.KnittingCalculator`
- profile UUID: `9c823f5b-ce62-47cd-9b51-5fa7a7152e5c`
- profile expiration: 2027-07-17
- application identifier:
  `9CFPAUL5N5.com.phillon.KnittingCalculator`
- entitlements: `get-task-allow=false`, `beta-reports-active=true`
- profile contains neither `ProvisionedDevices` nor `ProvisionsAllDevices`
- leaf signer:
  `Apple Distribution: Chen Chung Lung (9CFPAUL5N5)`
- strict `codesign` verification: pass

Final IPA command:

```bash
AppStore/Verification/knitting_calculator_release_audit.sh \
  --ipa /tmp/KnittingCalculatorAppStoreExport-20260729/KnittingCalculator.ipa
```

Result:

```text
KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS
KNITTING CALCULATOR RELEASE AUDIT: IPA STRUCTURE PASS
KNITTING CALCULATOR RELEASE AUDIT: IPA RELEASE SIGNING PASS
KNITTING CALCULATOR RELEASE AUDIT: PASS
```

App Store Connect upload completed on 2026-07-29 at 20:06 Asia/Taipei:

- version/build: `1.0.0 (1)`
- Xcode result: `Upload succeeded`
- App Store Connect upload status: Complete
- export compliance: no proprietary or non-Apple standard encryption
- TestFlight build status: Ready to Submit, expires in 90 days
- internal group: `編織計算器內部測試`
- automatic distribution: disabled
- group build: `1.0.0 (1)`, Ready to Test
- internal tester: `lzz.1999@gmail.com` (`LonPhil`), Invited
- no external group was created
- the build was not submitted for beta review, App Review, or release

## Independent-project physical machine evidence — 2026-07-29

### Tested source and devices

- Source commit: `4f8e564e40bf3acfefd8a3ccdc0f6f7ab1b0524b`
- Branch: `codex/knitting-calculator-independent-project`
- Project/scheme: `KnittingCalculator.xcodeproj` / `KnittingCalculator`
- Bundle/version: `com.phillon.KnittingCalculator`, `1.0.0 (1)`
- iPhone: iPhone 17 Pro Max, iOS 26.5.2 (23F84),
  UDID `00008150-00042D6A3612401C`, CoreDevice
  `30C68657-A038-5548-A1C6-F9280C02D5FB`
- iPad: iPad Air (5th generation), iPadOS 26.5.2 (23F84),
  UDID `00008103-001934E41128A01E`, CoreDevice
  `39B75EBF-8028-5713-87AC-A3BDBF985270`

Both devices were discovered as available, paired, and connected by USB using
`xcrun xcdevice list` and `xcrun devicectl list devices`.

### Machine-verifiable gate

| Check | Status | Evidence |
| --- | --- | --- |
| iPhone signed Debug build from the independent project | PASS | `xcodebuild -project KnittingCalculator.xcodeproj -scheme KnittingCalculator -configuration Debug -destination 'id=00008150-00042D6A3612401C' -derivedDataPath /tmp/KnittingCalculatorPhysical-iPhone build` ended with `** BUILD SUCCEEDED **`. |
| iPhone signature integrity | PASS | `codesign --verify --deep --strict --verbose=2` reported valid on disk and satisfied the designated requirement. |
| iPhone install identity | PASS | `devicectl device install app` returned bundle ID `com.phillon.KnittingCalculator` and installation path `/private/var/containers/Bundle/Application/1846104F-B859-4B3F-B610-E076E45B4E0C/KnittingCalculator.app/`. A subsequent app query reported name `Knitting Calculator`, version/build `1.0.0 (1)`, and `Developer App=true`. |
| iPhone launch and process identity | PASS | `devicectl device process launch` reported launch of `com.phillon.KnittingCalculator`. A fresh process query found `/private/var/containers/Bundle/Application/1846104F-B859-4B3F-B610-E076E45B4E0C/KnittingCalculator.app/KnittingCalculator` running as PID `15500`. |
| iPad signed Debug build from the independent project | PASS | `xcodebuild -project KnittingCalculator.xcodeproj -scheme KnittingCalculator -configuration Debug -destination 'id=00008103-001934E41128A01E' -derivedDataPath /tmp/KnittingCalculatorPhysical-iPad build` ended with `** BUILD SUCCEEDED **`. |
| iPad signature integrity | PASS | `codesign --verify --deep --strict --verbose=2` reported valid on disk and satisfied the designated requirement. |
| iPad install/launch gate | PASS | After the user unlocked the device, `devicectl` installed bundle `com.phillon.KnittingCalculator` at `/private/var/containers/Bundle/Application/91316361-BBDA-4B52-A757-92F5915AC998/KnittingCalculator.app/` and launched it successfully. The app query reported `1.0.0 (1)` and the process query found the expected executable running as PID `2083`. |

Build artifacts:

- iPhone:
  `/tmp/KnittingCalculatorPhysical-iPhone/Build/Products/Debug-iphoneos/KnittingCalculator.app`
- iPhone executable SHA-256:
  `4c6603e512bcdc0cacc07e8575abe53bb6ad823a7b179d0ce6f745e21ee96e01`
- iPad:
  `/tmp/KnittingCalculatorPhysical-iPad/Build/Products/Debug-iphoneos/KnittingCalculator.app`
- iPad executable SHA-256:
  `68dea5a6f4ca263c78c95dac99bdbb74a1b908ed139ea5041d226cc1e5567b2d`
- Both built `Info.plist` files SHA-256:
  `e2550a6d7857eef4d977aacd8402633024cbe2d66fe5944fab313ccd4bef3756`

The machine evidence proves independent-project signing, installation, launch,
and exact running bundle-process identity on both devices. It does not prove
visible layout or behavior; the later user confirmations cover only their
explicitly listed scope. All broader observations remain gated below.

## Evidence boundary

- Recorded: 2026-07-29 (Asia/Taipei)
- Candidate source commit: `4f8e564e40bf3acfefd8a3ccdc0f6f7ab1b0524b`
- Expected app version/build: `1.0.0 (1)`
- Discovery method: `xcrun xcdevice list` and `xcrun devicectl list devices`
- Available physical iPhone: iPhone 17 Pro Max, iOS 26.5.2 (23F84)
- Available physical iPad: iPad Air (5th generation), iPadOS 26.5.2 (23F84)

The iPhone and iPad machine gates passed, but visible or functional rows remain
acceptance blockers until the user records the observation. Simulator or
source evidence must not replace either device observation.

### Independent-project iPhone equivalence confirmation

On 2026-07-29, after the independent-project candidate was installed and
launched, the user replied `iphone ok` to the requested checks. This confirms
the following scope for source commit
`4f8e564e40bf3acfefd8a3ccdc0f6f7ab1b0524b`:

| Check | Status | Evidence |
| --- | --- | --- |
| Home fills the complete screen with no black bars | PASS | User observation on the installed iPhone candidate. |
| Portrait and landscape fill the display | PASS | User observation on the installed iPhone candidate. |
| Background then foreground remains full screen | PASS | User observation on the installed iPhone candidate. |
| Density and increase/decrease tools perform normally | PASS | User observation on the installed iPhone candidate. |

This concise confirmation does not imply the unrequested accessibility,
permission, share-sheet, deep-link, reset, force-termination, or exhaustive
edge-case rows below have passed.

### Independent-project iPad equivalence confirmation

On 2026-07-29, after the independent-project candidate was installed and
launched, the user replied `ipad ok` to the requested checks. This confirms the
following scope for source commit
`4f8e564e40bf3acfefd8a3ccdc0f6f7ab1b0524b`:

| Check | Status | Evidence |
| --- | --- | --- |
| Portrait and landscape show no clipping | PASS | User observation on the installed iPad candidate. |
| Density and increase/decrease tools perform normally | PASS | User observation on the installed iPad candidate. |
| Half and narrow Split View keep fields and buttons visible | PASS | User observation on the installed iPad candidate. |
| No unexpected permission prompt | PASS | User observation on the installed iPad candidate. |

This concise confirmation does not imply the unrequested external-keyboard,
share-sheet, two-thirds Split View, accessibility, deep-link, or exhaustive
edge-case rows below have passed.

## iPhone acceptance

| Check | Status | Evidence / follow-up |
| --- | --- | --- |
| Clean install opens directly to the two-tool home | PASS | User confirmed the TestFlight build opens full-screen to the two-tool home with no unexpected permission prompt. |
| First unit follows device region | AWAITING USER | Verify with a known device-region setting. |
| Gauge exact/recommended results and unit conversion | PASS | User verified 10 cm / 20 stitches / 25 cm produces density 2 and exact/recommended 50; switching to inches preserved the result and converted length drafts. |
| Optional gauge row group | PASS | User verified 10 cm / 30 rows / 20 cm produces density 3 and exact/recommended 60 while the stitch result remains 50. |
| One-row increase/decrease and edge toggle | PASS | User verified 80→92 increases 12, 80→68 decreases 12, reserved edge steps appear when enabled, and disappear when disabled. |
| Across-rows increase/decrease, one/both sides | PASS | User verified 20 rows / 10 decreases schedules 10 single-side events every 2 rows and 5 both-side events every 4 rows; 20 rows / 6 single-side increases schedules rows 4, 7, 10, 14, 17, and 20. |
| Every specified failure | AWAITING USER | Verify invalid, unsupported-limit, edge, and interval failures. |
| Copy and share text | PASS | User pasted the copied across-rows result into Notes and confirmed the iOS share sheet presents and dismisses normally. |
| Portrait and landscape | PASS | User rotated the TestFlight home and calculator screens in both directions with no black bars, half-screen presentation, clipping, or lost controls. |
| Background, termination, and reopen persistence | PASS | User confirmed background/foreground and force-termination/reopen preserve drafts and selections and remain full-screen. |
| Reset confirmation and scope | PASS | User verified cancel preserves drafts, destructive confirmation clears both calculators, and the selected inch unit remains. |
| KnitNote installed launch | PASS | User tapped the KnitNote promotion on the calculator home and confirmed the installed KnitNote app opened successfully. |
| KnitNote uninstalled App Store fallback | AWAITING USER | Requires a separate uninstalled-state pass. |
| Maximum Dynamic Type | AWAITING USER | Inspect home, both calculators, settings, errors, and results. |
| VoiceOver | AWAITING USER | Manually traverse labels, values, errors, disclosures, copy/share. |
| High contrast, reduced motion, light/dark mode | AWAITING USER | Verify each system setting combination. |
| No unexpected permission prompt | PASS | User observed no camera, photo, file, or other unexpected permission prompt through the tested TestFlight flows. |

### TestFlight installation and core user acceptance — 2026-07-29

- Internal group: `編織計算器內部測試`
- Internal tester: `lzz.1999@gmail.com` (`LonPhil`)
- Tested build: `1.0.0 (1)`
- App Store Connect status after acceptance: `Installed 1.0.0 (1)`
- App Store Connect device: iPhone 17 Pro Max, iOS 26.5.2
- User-confirmed core flows: full-screen launch, gauge stitches and optional
  rows, centimeters-to-inches conversion, one-row increase/decrease with edge
  reservation on/off, across-rows single-side/both-side schedules, uneven
  interval distribution, odd symmetric-count validation, rotation,
  background/foreground, force-termination persistence, copy/share, installed
  KnitNote promotion routing, and confirmed draft reset.
- The odd both-side count error was explicitly verified with 20 rows and 9
  stitches. Other failure branches remain unverified and are not implied by
  this core acceptance.

## iPad acceptance

| Check | Status | Evidence / follow-up |
| --- | --- | --- |
| Entire iPhone functional matrix | AWAITING USER | Installation and launch passed; repeat the applicable iPhone rows. |
| Landscape and portrait | AWAITING USER | The scoped confirmation above covers no clipping; this broader row still requires cards, fields, results, and disclosures to be checked. |
| One-third Split View | AWAITING USER | The scoped confirmation above covers visible fields and buttons; this broader row still requires cards, results, and disclosures to be checked. |
| Half Split View | AWAITING USER | The scoped confirmation above covers visible fields and buttons; this broader row still requires cards, results, and disclosures to be checked. |
| Two-thirds Split View | AWAITING USER | Verify no clipped cards, fields, results, or disclosures. |
| External-keyboard numeric entry | AWAITING USER | Run only if a keyboard is available; record availability. |
| Share-sheet presentation and dismissal | AWAITING USER | Confirm it is correctly anchored and dismisses. |
| No unexpected permission prompt | PASS | User confirmed no unexpected permission prompt appeared during the requested checks. |

## Acceptance rule

Mark a row `PASS` only after recording the installed build, device model/OS, tested source
commit, and observed behavior. A `FAIL` on either physical device overrides all simulator,
build, archive, and static-audit evidence until fixed and rechecked.
