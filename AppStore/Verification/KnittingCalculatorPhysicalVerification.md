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

### Audit results and remaining blockers

Static-only command:

```bash
AppStore/Verification/knitting_calculator_release_audit.sh --static-only
```

Result:

```text
KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS
KNITTING CALCULATOR RELEASE AUDIT: FAIL — free-app App Store URL is still the development landing page; App Store Connect must assign a real numeric App Store ID before this audit can pass
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

The existing numeric URL `https://apps.apple.com/app/id6793023054` is the
KnitNote promotion destination and is intentionally not accepted as the free
calculator App Store URL. Remaining release blockers are:

1. App Store Connect must assign the free calculator its own numeric App Store
   ID, then `CalculatorShareText.swift` must replace the development landing
   page.
2. A usable App Store distribution provisioning profile/signing path must
   produce an archive whose decoded embedded profile has the single exact team
   `9CFPAUL5N5`, exact application identifier
   `9CFPAUL5N5.com.phillon.KnittingCalculator`,
   `get-task-allow=false`, `beta-reports-active=true`, no
   `ProvisionedDevices`, and no `ProvisionsAllDevices`.
3. The leaf signing identity must begin with `Apple Distribution:` and strict
   `codesign` verification must pass. This separately rejects Apple
   Development; the profile rules above reject Ad Hoc and Enterprise
   provisioning even when those builds also use an Apple Distribution
   certificate.

These blockers do not invalidate the independent project topology or archive
structure, but the overall release audit remains `FAIL`.

## Evidence boundary

- Recorded: 2026-07-28 (Asia/Taipei)
- Candidate source commit: `aecc1db251a717a8b39102ee3e2042ec85579b23`
- Expected app version/build: `1.0.0 (1)`
- Discovery method: `xcrun xcdevice list` and `xcrun devicectl list devices`
- Available physical iPhone: iPhone 17 Pro Max, iOS 26.5.2 (23F84)
- Available physical iPad: iPad Air (5th generation), iPadOS 26.5.2 (23F84)

Discovery only proves that paired devices were visible. No Knitting Calculator build has
been signed, installed, or launched on either device in this record. Every `PENDING`
row below remains an acceptance blocker; simulator or source evidence must not replace it.

## iPhone acceptance

| Check | Status | Evidence / follow-up |
| --- | --- | --- |
| Clean install opens directly to the two-tool home | PENDING | Requires signed install and manual launch. |
| First unit follows device region | PENDING | Verify with a known device-region setting. |
| Gauge exact/recommended results and unit conversion | PENDING | Check known values, nearest recommendation, and preserved counts. |
| Optional gauge row group | PENDING | Exercise empty, complete, and partial row inputs. |
| One-row increase/decrease and edge toggle | PENDING | Check increase and decrease with edge reservation on/off. |
| Across-rows increase/decrease, one/both sides | PENDING | Check valid schedules and all error branches. |
| Every specified failure | PENDING | Verify invalid, unsupported-limit, edge, and interval failures. |
| Copy and share text | PENDING | Verify clipboard and share sheet payload. |
| Portrait and landscape | PENDING | Inspect no clipping or lost result/action controls. |
| Background, termination, and reopen persistence | PENDING | Verify last drafts and unit persistence after a force termination. |
| Reset confirmation and scope | PENDING | Confirm drafts clear while unit/counters remain. |
| KnitNote installed launch | PENDING | Requires KnitNote installed and a manual link tap. |
| KnitNote uninstalled App Store fallback | PENDING | Requires a separate uninstalled-state pass. |
| Maximum Dynamic Type | PENDING | Inspect home, both calculators, settings, errors, and results. |
| VoiceOver | PENDING | Manually traverse labels, values, errors, disclosures, copy/share. |
| High contrast, reduced motion, light/dark mode | PENDING | Verify each system setting combination. |
| No unexpected permission prompt | PENDING | Observe clean install through both calculators and settings. |

## iPad acceptance

| Check | Status | Evidence / follow-up |
| --- | --- | --- |
| Entire iPhone functional matrix | PENDING | Repeat every iPhone row on iPad Air (5th generation). |
| Landscape and portrait | PENDING | Inspect cards, fields, disclosures, errors, and results. |
| One-third Split View | PENDING | Verify no clipped cards, fields, results, or disclosures. |
| Half Split View | PENDING | Verify no clipped cards, fields, results, or disclosures. |
| Two-thirds Split View | PENDING | Verify no clipped cards, fields, results, or disclosures. |
| External-keyboard numeric entry | PENDING | Run only if a keyboard is available; record availability. |
| Share-sheet presentation and dismissal | PENDING | Confirm it is correctly anchored and dismisses. |
| No unexpected permission prompt | PENDING | Observe clean install through all accessible screens. |

## Acceptance rule

Mark a row `PASS` only after recording the installed build, device model/OS, tested source
commit, and observed behavior. A `FAIL` on either physical device overrides all simulator,
build, archive, and static-audit evidence until fixed and rechecked.
