#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

EXPECTED_BUNDLE="com.phillon.KnittingCalculator"
EXPECTED_VERSION="1.1.0"
EXPECTED_BUILD="4"
EXPECTED_APP_STORE_ID="6795877892"
EXPECTED_TEAM_IDENTIFIER="9CFPAUL5N5"
PROJECT_SPEC="KnittingCalculator/project.yml"
PROJECT_FILE="KnittingCalculator.xcodeproj"
SOURCE_CHECK="AppStore/Verification/knitting_calculator_release_source_check.py"
LOCALIZATION_CHECK="AppStore/Verification/knitting_calculator_localization_check.py"
METADATA_CHECK="AppStore/Verification/metadata_check.py"
CALCULATOR_METADATA="AppStore/KnittingCalculator/Metadata"
EXPECTED_APP_LOCALES=(en zh-Hant zh-Hans de fr ja ko nl nb sv fi da el)
APP_STORE_URL="https://apps.apple.com/app/id${EXPECTED_APP_STORE_ID}"
KNITNOTE_APP_STORE_URL="https://apps.apple.com/app/id6793023054"
STATIC_ONLY=0
ARCHIVE=""
IPA=""
TEMP_FILES=()
TEMP_DIRS=()

cleanup() {
  if [[ "${#TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${TEMP_FILES[@]}"
  fi
  if [[ "${#TEMP_DIRS[@]}" -gt 0 ]]; then
    rm -rf "${TEMP_DIRS[@]}"
  fi
}
trap cleanup EXIT

usage() {
  echo "usage: knitting_calculator_release_audit.sh [--static-only] [--archive PATH | --ipa PATH]" >&2
}

fail() {
  echo "KNITTING CALCULATOR RELEASE AUDIT: FAIL — $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

verify_free_privacy_manifest() {
  plutil -convert json -o - KnittingCalculator/PrivacyInfo.xcprivacy \
    | jq -e '
      .NSPrivacyTracking == false
      and (.NSPrivacyTrackingDomains | type == "array" and length == 0)
      and (.NSPrivacyCollectedDataTypes | type == "array" and length == 0)
      and .NSPrivacyAccessedAPITypes == [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
        "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]
      }]
    ' >/dev/null || fail "free-app privacy manifest must declare only UserDefaults CA92.1, no tracking, and no collection"
}

verify_production_dependency_boundaries() {
  local production_sources=(
    KnittingCalculator
    Packages/KnittingCalculatorCore/Sources
  )
  require_file "$SOURCE_CHECK"
  local unexpected_storekit_files
  unexpected_storekit_files="$(
    rg -l \
      '^[[:space:]]*import[[:space:]]+((class|enum|func|protocol|struct|typealias|var|let)[[:space:]]+)?StoreKit([.][A-Za-z_][A-Za-z0-9_]*)*[[:space:]]*$' \
      "${production_sources[@]}" --glob '*.swift' \
      | sort \
      | comm -23 - <(printf '%s\n' \
        KnittingCalculator/Model/RatingEligibility.swift \
        | sort) || true
  )"
  [[ -z "$unexpected_storekit_files" ]] \
    || fail "unexpected commerce dependency: $unexpected_storekit_files"

  local rating_source="KnittingCalculator/Model/RatingEligibility.swift"
  python3 "$SOURCE_CHECK" rating-storekit "$rating_source" \
    || fail "unexpected rating StoreKit surface; only import enum StoreKit.AppStore and AppStore.requestReview are allowed"

  if rg -n -i \
    '\b(RevenueCat|Adapty|Paddle|Product\.products|Transaction\.(all|currentEntitlements|latest|updates)|AppStore\.sync|purchase\(|subscription)\b' \
    "${production_sources[@]}" \
    --glob '*.swift' \
    --glob '!RatingEligibility.swift'; then
    fail "unexpected commerce dependency"
  fi

  if rg -n -i \
    '\b(FirebaseAnalytics|FirebaseCore|Mixpanel|Amplitude|Telemetry|Sentry|Adjust|AppsFlyer|tracking)\b|^[[:space:]]*import[[:space:]]+Segment[[:space:]]*$' \
    "${production_sources[@]}" --glob '*.swift'; then
    fail "unexpected analytics or tracking dependency"
  fi

  if rg -n \
    '\b(URLSession|NWConnection|Alamofire|AsyncHTTPClient)\b|^[[:space:]]*import[[:space:]]+Network[[:space:]]*$' \
    "${production_sources[@]}" --glob '*.swift'; then
    fail "unexpected networking dependency"
  fi

  local dependency_declarations=(
    "$PROJECT_SPEC"
    "$PROJECT_FILE/project.pbxproj"
    Packages/KnittingCalculatorCore/Package.swift
  )
  for resolved in \
    KnittingCalculator/Package.resolved \
    "$PROJECT_FILE/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"; do
    if [[ -f "$resolved" ]]; then
      dependency_declarations+=("$resolved")
    fi
  done

  if rg -n \
    'XCRemoteSwiftPackageReference|repositoryURL[[:space:]]*=|^[[:space:]]*url:|\.package\([[:space:]]*url:|"kind"[[:space:]]*:[[:space:]]*"remoteSourceControl"|"location"[[:space:]]*:[[:space:]]*"https?://' \
    "${dependency_declarations[@]}"; then
    fail "unexpected dynamic package dependency"
  fi

  local package_spec_json
  package_spec_json="$(
    mktemp "${TMPDIR:-/tmp}/knitting-calculator-package-spec.XXXXXX"
  )"
  TEMP_FILES+=("$package_spec_json")
  xcodegen dump \
    --spec "$PROJECT_SPEC" \
    --project-root "$ROOT" \
    --type parsed-json >"$package_spec_json"
  jq -e '
    (.packages | keys) == ["KnittingCalculatorCore"]
    and .packages.KnittingCalculatorCore.path
      == "Packages/KnittingCalculatorCore"
    and (
      [.targets.KnittingCalculator.dependencies[] | .package? // empty]
      | sort
    ) == ["KnittingCalculatorCore"]
    and (
      [.targets.KnittingCalculatorTests.dependencies[] | .package? // empty]
      | sort
    ) == ["KnittingCalculatorCore"]
  ' "$package_spec_json" >/dev/null \
    || fail "unexpected linked local package dependency"

  local generated_local_package_paths
  generated_local_package_paths="$(
    awk '
      /Begin XCLocalSwiftPackageReference section/ { inside = 1; next }
      /End XCLocalSwiftPackageReference section/ { inside = 0 }
      inside && /relativePath = / {
        sub(/^.*relativePath = /, "")
        sub(/;.*$/, "")
        print
      }
    ' "$PROJECT_FILE/project.pbxproj" | sort
  )"
  [[ "$generated_local_package_paths" == "Packages/KnittingCalculatorCore" ]] \
    || fail "unexpected linked local package dependency in generated project"

  local generated_package_products
  generated_package_products="$(
    awk '
      /Begin XCSwiftPackageProductDependency section/ { inside = 1; next }
      /End XCSwiftPackageProductDependency section/ { inside = 0 }
      inside && /productName = / {
        sub(/^.*productName = /, "")
        sub(/;.*$/, "")
        print
      }
    ' "$PROJECT_FILE/project.pbxproj" | sort
  )"
  [[ "$generated_package_products" == $'KnittingCalculatorCore\nKnittingCalculatorCore' ]] \
    || fail "unexpected package product dependency in generated project"

  if rg -n '\.package\(' Packages/KnittingCalculatorCore/Package.swift; then
    fail "unexpected linked local package dependency in calculator core package"
  fi
  python3 "$SOURCE_CHECK" package-manifest \
    Packages/KnittingCalculatorCore/Package.swift \
    || fail "unexpected dynamic library dependency"

  if rg -n -i '\.binaryTarget|\.xcframework\b|\.framework\b' \
    "${dependency_declarations[@]}"; then
    fail "unexpected binary framework dependency"
  fi
  local binary_framework
  binary_framework="$(
    find KnittingCalculator Packages/KnittingCalculatorCore/Sources \
      -type d \( -name '*.framework' -o -name '*.xcframework' \) \
      -print -quit
  )"
  [[ -z "$binary_framework" ]] \
    || fail "unexpected binary framework dependency: $binary_framework"

  local calculator_app_store_urls
  calculator_app_store_urls="$(
    rg -o --no-filename 'https://apps\.apple\.com/app/id[0-9]+' \
      KnittingCalculator/Model/CalculatorShareText.swift \
      | sort -u || true
  )"
  [[ "$calculator_app_store_urls" == "$APP_STORE_URL" ]] \
    || fail "calculator App Store ID is not $EXPECTED_APP_STORE_ID"

  if rg -n 'https?://' Packages/KnittingCalculatorCore/Sources --glob '*.swift'; then
    fail "linked calculator package must not contain literal URLs"
  fi

  local unexpected_url_files
  unexpected_url_files="$(rg -l 'https?://' KnittingCalculator --glob '*.swift' \
    | sort \
    | comm -23 - <(printf '%s\n' \
      KnittingCalculator/Model/CalculatorShareText.swift \
      KnittingCalculator/Model/KnitNoteLinkRouter.swift \
      KnittingCalculator/Settings/CalculatorSettingsView.swift \
      | sort) || true)"
  [[ -z "$unexpected_url_files" ]] || fail "literal URLs are only allowed in CalculatorProductLinks and Settings: $unexpected_url_files"

  local url
  while IFS= read -r url; do
    case "$url" in
      https://phillon77.github.io/KnitNote/knitting-calculator.html|\
      https://phillon77.github.io/KnitNote/knitting-calculator-privacy.html|\
      https://apps.apple.com/app/id6793023054|\
      https://apps.apple.com/app/id6795877892)
        ;;
      *)
        fail "unapproved literal URL in calculator source: $url"
        ;;
    esac
  done < <(rg -o --no-filename 'https?://[^"[:space:]]+' KnittingCalculator --glob '*.swift' || true)
}

verify_static_assets() {
  local icon_contents="KnittingCalculator/Assets.xcassets/AppIcon.appiconset/Contents.json"
  require_file "KnittingCalculator/Assets.xcassets/Contents.json"
  require_file "$icon_contents"
  jq -e '.images | type == "array" and length > 0' "$icon_contents" >/dev/null \
    || fail "AppIcon asset catalog has no image entries"

  local filename
  while IFS= read -r filename; do
    require_file "KnittingCalculator/Assets.xcassets/AppIcon.appiconset/$filename"
  done < <(jq -er '.images[] | select(.filename != null) | .filename' "$icon_contents")
}

verify_static_metadata() {
  local spec_json
  spec_json="$(mktemp "${TMPDIR:-/tmp}/knitting-calculator-release-spec.XXXXXX")"
  TEMP_FILES+=("$spec_json")
  xcodegen dump \
    --spec "$PROJECT_SPEC" \
    --project-root "$ROOT" \
    --type parsed-json >"$spec_json"

  jq -e \
    --arg bundle "$EXPECTED_BUNDLE" \
    --arg version "$EXPECTED_VERSION" \
    --arg build "$EXPECTED_BUILD" '
      .targets.KnittingCalculator.settings
      | .PRODUCT_BUNDLE_IDENTIFIER == $bundle
      and .MARKETING_VERSION == $version
      and .CURRENT_PROJECT_VERSION == $build
    ' "$spec_json" >/dev/null \
    || fail "XcodeGen target identity/version/build does not match ${EXPECTED_BUNDLE} ${EXPECTED_VERSION} (${EXPECTED_BUILD})"
}

verify_generated_project_metadata() {
  local generated_versions
  local generated_builds
  local generated_known_regions
  local expected_known_regions

  generated_versions="$(
    rg -o 'MARKETING_VERSION = [^;]+' "$PROJECT_FILE/project.pbxproj" \
      | sed 's/MARKETING_VERSION = //' | sort -u
  )"
  [[ "$generated_versions" == "$EXPECTED_VERSION" ]] \
    || fail "generated project marketing version is not $EXPECTED_VERSION"

  generated_builds="$(
    rg -o 'CURRENT_PROJECT_VERSION = [^;]+' "$PROJECT_FILE/project.pbxproj" \
      | sed 's/CURRENT_PROJECT_VERSION = //' | sort -u
  )"
  [[ "$generated_builds" == "$EXPECTED_BUILD" ]] \
    || fail "generated project build number is not $EXPECTED_BUILD"

  generated_known_regions="$(
    awk '
      /knownRegions = \(/ { inside = 1; next }
      inside && /\);/ { exit }
      inside {
        gsub(/^[[:space:]]+|,[[:space:]]*$/, "")
        gsub(/^\"|\"$/, "")
        print
      }
    ' "$PROJECT_FILE/project.pbxproj" | LC_ALL=C sort -u
  )"
  expected_known_regions="$(
    printf '%s\n' \
      Base "${EXPECTED_APP_LOCALES[@]}" \
      | LC_ALL=C sort
  )"
  [[ "$generated_known_regions" == "$expected_known_regions" ]] \
    || fail "generated project known regions do not match supported app locales"
}

verify_independent_project_scope() {
  local project_listing
  require_file "$PROJECT_SPEC"
  require_file "$PROJECT_FILE/project.pbxproj"
  project_listing="$(mktemp "${TMPDIR:-/tmp}/knitting-calculator-project-list.XXXXXX")"
  TEMP_FILES+=("$project_listing")

  xcodebuild -list -json -project "$PROJECT_FILE" >"$project_listing"
  jq -e '
    (.project.targets | sort) == [
      "KnittingCalculator",
      "KnittingCalculatorTests"
    ]
    and (.project.schemes | index("KnittingCalculator") != null)
  ' "$project_listing" >/dev/null \
    || fail "independent project must contain only KnittingCalculator and KnittingCalculatorTests targets"
}

verify_archive_entitlements() {
  local app="$1"
  codesign -d --entitlements :- "$app" 2>/dev/null \
    | plutil -convert json -o - -- - \
    | jq -e '
      . as $entitlements
      | [
        "com.apple.security.application-groups",
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-services",
        "aps-environment",
        "com.apple.developer.aps-environment"
      ] as $forbidden
      | all($forbidden[]; . as $key | $entitlements | has($key) | not)
      and (($entitlements["get-task-allow"] // false) == false)
    ' >/dev/null \
    || fail "release archive contains a prohibited capability or development-only get-task-allow entitlement"
}

verify_app_store_profile() {
  local app="$1"
  local profile="$app/embedded.mobileprovision"
  local profile_plist
  local app_identifier
  local profile_team_identifier
  local entitlement_team_identifier
  local get_task_allow
  local beta_reports_active
  require_file "$profile"
  profile_plist="$(mktemp "${TMPDIR:-/tmp}/knitting-calculator-profile.XXXXXX")"
  TEMP_FILES+=("$profile_plist")

  security cms -D -i "$profile" >"$profile_plist" 2>/dev/null \
    || fail "cannot decode embedded provisioning profile"

  app_identifier="$(
    plist_value "$profile_plist" "Entitlements:application-identifier" 2>/dev/null
  )" || fail "embedded profile is missing application-identifier"
  profile_team_identifier="$(
    plist_value "$profile_plist" "TeamIdentifier:0" 2>/dev/null
  )" || fail "embedded profile is missing TeamIdentifier"
  entitlement_team_identifier="$(
    plist_value "$profile_plist" "Entitlements:com.apple.developer.team-identifier" 2>/dev/null
  )" || fail "embedded profile is missing team entitlement"
  get_task_allow="$(
    plist_value "$profile_plist" "Entitlements:get-task-allow" 2>/dev/null
  )" || fail "embedded profile is missing get-task-allow"
  beta_reports_active="$(
    plist_value "$profile_plist" "Entitlements:beta-reports-active" 2>/dev/null
  )" || fail "embedded profile is missing beta-reports-active"

  [[ "$app_identifier" == "$EXPECTED_TEAM_IDENTIFIER.$EXPECTED_BUNDLE" ]] \
    || fail "embedded profile application-identifier is not ${EXPECTED_TEAM_IDENTIFIER}.${EXPECTED_BUNDLE}"
  [[ "$profile_team_identifier" == "$EXPECTED_TEAM_IDENTIFIER" ]] \
    || fail "embedded profile TeamIdentifier is not $EXPECTED_TEAM_IDENTIFIER"
  if plist_value "$profile_plist" "TeamIdentifier:1" >/dev/null 2>&1; then
    fail "embedded profile contains more than one TeamIdentifier"
  fi
  [[ "$entitlement_team_identifier" == "$EXPECTED_TEAM_IDENTIFIER" ]] \
    || fail "embedded profile team entitlement is not $EXPECTED_TEAM_IDENTIFIER"
  [[ "$get_task_allow" == "false" ]] \
    || fail "embedded profile get-task-allow is not false"
  [[ "$beta_reports_active" == "true" ]] \
    || fail "embedded profile beta-reports-active is not true"
  if plist_value "$profile_plist" "ProvisionedDevices" >/dev/null 2>&1; then
    fail "embedded profile contains ProvisionedDevices and is not App Store distribution"
  fi
  if plist_value "$profile_plist" "ProvisionsAllDevices" >/dev/null 2>&1; then
    fail "embedded profile contains ProvisionsAllDevices and is not App Store distribution"
  fi
}

verify_apple_distribution_identity() {
  local app="$1"
  local signing_info
  local leaf_authority

  signing_info="$(codesign -d --verbose=4 "$app" 2>&1)" \
    || fail "cannot decode archive signing authority"
  leaf_authority="$(
    printf '%s\n' "$signing_info" \
      | awk '/^Authority=/{sub(/^Authority=/, ""); print; exit}'
  )"

  [[ "$leaf_authority" == "Apple Distribution: "* ]] \
    || fail "leaf signing authority is not Apple Distribution: ${leaf_authority:-missing}"
}

verify_archive_no_permission_descriptions() {
  local info="$1"
  plutil -convert json -o - "$info" \
    | jq -e '
      . as $info
      | [
        "NSCameraUsageDescription",
        "NSPhotoLibraryUsageDescription",
        "NSPhotoLibraryAddUsageDescription",
        "CFBundleDocumentTypes",
        "UTExportedTypeDeclarations",
        "UTImportedTypeDeclarations",
        "LSSupportsOpeningDocumentsInPlace",
        "UISupportsDocumentBrowser"
      ] as $forbidden
      | all($forbidden[]; . as $key | $info | has($key) | not)
    ' >/dev/null \
    || fail "archive declares prohibited camera, photo, or file-access capability"
}

verify_artifact_app_store_identity() {
  local app="$1"
  local info="$app/Info.plist"
  local executable_name
  local executable
  local artifact_app_store_urls
  executable_name="$(
    plist_value "$info" CFBundleExecutable 2>/dev/null
  )" || fail "artifact is missing CFBundleExecutable"
  executable="$app/$executable_name"
  require_file "$executable"

  rg -a -q "$APP_STORE_URL([^0-9A-Za-z]|$)" "$executable" \
    || fail "artifact App Store ID is not $EXPECTED_APP_STORE_ID"
  artifact_app_store_urls="$(
    rg -a -o --no-filename 'https://apps\.apple\.com/app/id[0-9]+' \
      "$executable" | sort -u || true
  )"
  local url
  while IFS= read -r url; do
    case "$url" in
      "$APP_STORE_URL"|"$KNITNOTE_APP_STORE_URL")
        ;;
      *)
        fail "artifact contains an unapproved App Store URL: $url"
        ;;
    esac
  done <<<"$artifact_app_store_urls"
}

verify_app_bundle() {
  local app="$1"
  local info="$app/Info.plist"
  local resources="$app"
  [[ -d "$app" ]] || fail "missing application bundle: $app"
  require_file "$info"

  [[ "$(plist_value "$info" CFBundleIdentifier)" == "$EXPECTED_BUNDLE" ]] \
    || fail "archive bundle identifier is not $EXPECTED_BUNDLE"
  [[ "$(plist_value "$info" CFBundleShortVersionString)" == "$EXPECTED_VERSION" ]] \
    || fail "archive marketing version is not $EXPECTED_VERSION"
  [[ "$(plist_value "$info" CFBundleVersion)" == "$EXPECTED_BUILD" ]] \
    || fail "archive build number is not $EXPECTED_BUILD"
  verify_artifact_app_store_identity "$app"

  require_file "$resources/PrivacyInfo.xcprivacy"
  plutil -lint "$resources/PrivacyInfo.xcprivacy" >/dev/null \
    || fail "archive privacy manifest is invalid"
  require_file "$resources/Assets.car"
  for locale in "${EXPECTED_APP_LOCALES[@]}"; do
    require_file "$resources/$locale.lproj/Localizable.strings"
    require_file "$resources/$locale.lproj/InfoPlist.strings"
  done

  verify_archive_no_permission_descriptions "$info"
}

verify_archive() {
  local archive="$1"
  verify_app_bundle "$archive/Products/Applications/KnittingCalculator.app"
}

verify_archive_release_signing() {
  local archive="$1"
  local app="$archive/Products/Applications/KnittingCalculator.app"

  verify_release_signing "$app"
}

verify_release_signing() {
  local app="$1"

  verify_app_store_profile "$app"
  verify_archive_entitlements "$app"
  verify_apple_distribution_identity "$app"
  codesign --verify --deep --strict "$app" \
    || fail "release codesign verification failed"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only)
      STATIC_ONLY=1
      shift
      ;;
    --archive)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHIVE="$2"
      shift 2
      ;;
    --ipa)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      IPA="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ "$STATIC_ONLY" -eq 0 || ( -z "$ARCHIVE" && -z "$IPA" ) ]] \
  || fail "--static-only cannot be combined with --archive or --ipa"
[[ -z "$ARCHIVE" || -z "$IPA" ]] \
  || fail "--archive and --ipa cannot be combined"

plutil -lint KnittingCalculator/Info.plist KnittingCalculator/PrivacyInfo.xcprivacy >/dev/null
verify_independent_project_scope
verify_static_metadata
verify_generated_project_metadata
verify_free_privacy_manifest
require_file "$LOCALIZATION_CHECK"
python3 "$LOCALIZATION_CHECK" \
  KnittingCalculator/Localization/Localizable.xcstrings \
  KnittingCalculator/Localization/InfoPlist.xcstrings \
  || fail "source localization catalog contract failed"
require_file "$METADATA_CHECK"
python3 "$METADATA_CHECK" "$CALCULATOR_METADATA" \
  || fail "calculator metadata contract failed"
verify_static_assets
verify_production_dependency_boundaries
git diff --check -- \
  KnittingCalculator \
  KnittingCalculatorTests \
  Packages/KnittingCalculatorCore \
  AppStore/Verification/knitting_calculator_release_audit.sh \
  AppStore/Verification/knitting_calculator_release_source_check.py \
  AppStore/Verification/KnittingCalculatorPhysicalVerification.md

echo "KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS"

if [[ -n "$ARCHIVE" ]]; then
  verify_archive "$ARCHIVE"
  echo "KNITTING CALCULATOR RELEASE AUDIT: ARCHIVE STRUCTURE PASS"
  verify_archive_release_signing "$ARCHIVE"
  echo "KNITTING CALCULATOR RELEASE AUDIT: ARCHIVE RELEASE SIGNING PASS"
fi

if [[ -n "$IPA" ]]; then
  require_file "$IPA"
  IPA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/knitting-calculator-ipa.XXXXXX")"
  TEMP_DIRS+=("$IPA_DIR")
  unzip -q "$IPA" -d "$IPA_DIR" \
    || fail "cannot extract IPA"
  IPA_APP="$IPA_DIR/Payload/KnittingCalculator.app"
  verify_app_bundle "$IPA_APP"
  echo "KNITTING CALCULATOR RELEASE AUDIT: IPA STRUCTURE PASS"
  verify_release_signing "$IPA_APP"
  echo "KNITTING CALCULATOR RELEASE AUDIT: IPA RELEASE SIGNING PASS"
fi

echo "KNITTING CALCULATOR RELEASE AUDIT: PASS"
