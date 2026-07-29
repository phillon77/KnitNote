#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

EXPECTED_BUNDLE="com.phillon.KnittingCalculator"
EXPECTED_VERSION="1.0.0"
EXPECTED_BUILD="1"
PROJECT_SPEC="KnittingCalculator/project.yml"
PROJECT_FILE="KnittingCalculator.xcodeproj"
APP_STORE_URL_PATTERN='apps.apple.com/app/id[0-9]+'
STATIC_ONLY=0
ARCHIVE=""
TEMP_FILES=()

cleanup() {
  if [[ "${#TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${TEMP_FILES[@]}"
  fi
}
trap cleanup EXIT

usage() {
  echo "usage: knitting_calculator_release_audit.sh [--static-only] [--archive PATH]" >&2
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

verify_string_catalog() {
  local catalog="$1"
  jq -e '
    def complete:
      type == "object"
      and length > 0
      and (
        if has("stringUnit") then
          (.stringUnit.value | type == "string" and length > 0)
        else
          all(.[]; complete)
        end
      );
    (.strings | length) > 0
    and all(
      .strings[];
      (.localizations.en | complete)
      and (.localizations."zh-Hant" | complete)
    )
  ' "$catalog" >/dev/null || fail "$catalog has an incomplete English or Traditional Chinese translation"
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

verify_static_network_boundary() {
  if rg -n -i '\b(URLSession|NWConnection|Firebase|Analytics|Telemetry|Mixpanel|Amplitude|Segment|Sentry|Adjust|AppsFlyer|tracking)\b' \
    KnittingCalculator --glob '*.swift'; then
    fail "unexpected network client, analytics SDK, or tracking source"
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
      https://apps.apple.com/app/id6793023054)
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

verify_archive() {
  local archive="$1"
  local app="$archive/Products/Applications/KnittingCalculator.app"
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

  require_file "$resources/PrivacyInfo.xcprivacy"
  plutil -lint "$resources/PrivacyInfo.xcprivacy" >/dev/null \
    || fail "archive privacy manifest is invalid"
  require_file "$resources/Assets.car"
  for locale in en 'zh-Hant'; do
    require_file "$resources/$locale.lproj/Localizable.strings"
    require_file "$resources/$locale.lproj/InfoPlist.strings"
  done

  verify_archive_no_permission_descriptions "$info"
}

verify_archive_release_signing() {
  local archive="$1"
  local app="$archive/Products/Applications/KnittingCalculator.app"

  verify_archive_entitlements "$app"
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
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -z "$ARCHIVE" || "$STATIC_ONLY" -eq 0 ]] \
  || fail "--static-only cannot be combined with --archive"

plutil -lint KnittingCalculator/Info.plist KnittingCalculator/PrivacyInfo.xcprivacy >/dev/null
verify_independent_project_scope
verify_static_metadata
verify_free_privacy_manifest
verify_string_catalog KnittingCalculator/Localization/InfoPlist.xcstrings
verify_string_catalog KnittingCalculator/Localization/Localizable.xcstrings
verify_static_assets
verify_static_network_boundary
git diff --check -- \
  KnittingCalculator \
  KnittingCalculatorTests \
  Packages/KnittingCalculatorCore \
  AppStore/Verification/knitting_calculator_release_audit.sh \
  AppStore/Verification/KnittingCalculatorPhysicalVerification.md

echo "KNITTING CALCULATOR RELEASE AUDIT: STATIC PRODUCT SCOPE PASS"

APP_STORE_URL_MISSING=0
if ! rg -q "$APP_STORE_URL_PATTERN" KnittingCalculator/Model/CalculatorShareText.swift; then
  APP_STORE_URL_MISSING=1
fi

if [[ -n "$ARCHIVE" ]]; then
  verify_archive "$ARCHIVE"
  echo "KNITTING CALCULATOR RELEASE AUDIT: ARCHIVE STRUCTURE PASS"
  verify_archive_release_signing "$ARCHIVE"
  echo "KNITTING CALCULATOR RELEASE AUDIT: ARCHIVE RELEASE SIGNING PASS"
fi

if [[ "$APP_STORE_URL_MISSING" -eq 1 ]]; then
  fail "free-app App Store URL is still the development landing page; App Store Connect must assign a real numeric App Store ID before this audit can pass"
fi

echo "KNITTING CALCULATOR RELEASE AUDIT: PASS"
