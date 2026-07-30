#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARCHIVES=""
STATIC_ONLY=0

usage() {
  echo "usage: release_audit.sh [--static-only] [--archives DIR]" >&2
}

fail() {
  echo "release audit: $*" >&2
  exit 1
}

verify_signed_app_group() {
  local bundle="$1"
  codesign -d --entitlements :- "$bundle" 2>/dev/null \
    | plutil -convert json -o - -- - \
    | jq -e '."com.apple.security.application-groups"
      == ["group.com.phillon.KnitNote"]' >/dev/null \
    || fail "$bundle signed entitlements do not contain only the production App Group"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only)
      STATIC_ONLY=1
      shift
      ;;
    --archives)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      ARCHIVES="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$STATIC_ONLY" -eq 0 ]]; then
  swift test --disable-sandbox
fi

SPEC_JSON="$(mktemp "${TMPDIR:-/tmp}/knitnote-release-spec.XXXXXX")"
trap 'rm -f "$SPEC_JSON"' EXIT
xcodegen dump --type parsed-json >"$SPEC_JSON"

plutil -lint \
  KnitNote/Info.plist \
  KnitNoteWatch/Info.plist \
  KnitNoteShare/Info.plist \
  KnitNote/PrivacyInfo.xcprivacy \
  KnitNoteWatch/PrivacyInfo.xcprivacy \
  KnitNoteShare/PrivacyInfo.xcprivacy \
  KnitNote/KnitNote-iOS.entitlements \
  KnitNoteShare/KnitNoteShare.entitlements >/dev/null

EXPECTED_VERSION="1.2.1"
EXPECTED_BUILD="4"
for target in KnitNote KnitNoteWatch KnitNoteShare; do
  version="$(jq -er --arg target "$target" \
    '.targets[$target].settings.MARKETING_VERSION' "$SPEC_JSON")"
  build="$(jq -er --arg target "$target" \
    '.targets[$target].settings.CURRENT_PROJECT_VERSION' "$SPEC_JSON")"
  [[ "$version" == "$EXPECTED_VERSION" ]] \
    || fail "$target marketing version is $version, expected $EXPECTED_VERSION"
  [[ "$build" == "$EXPECTED_BUILD" ]] \
    || fail "$target build is $build, expected $EXPECTED_BUILD"
done

rg -q 'static let currentVersion = 10' \
  Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  || fail "project archive schema is not 10"
rg -q 'static let currentFormatVersion = 2' \
  Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift \
  || fail "backup manifest format is not 2"

for entitlements in \
  KnitNote/KnitNote-iOS.entitlements \
  KnitNoteShare/KnitNoteShare.entitlements; do
  plutil -convert json -o - "$entitlements" \
    | jq -e '."com.apple.security.application-groups"
      == ["group.com.phillon.KnitNote"]' >/dev/null \
    || fail "$entitlements does not contain only the production App Group"
done

for manifest in \
  KnitNote/PrivacyInfo.xcprivacy \
  KnitNoteWatch/PrivacyInfo.xcprivacy \
  KnitNoteShare/PrivacyInfo.xcprivacy; do
  plutil -convert json -o - "$manifest" \
    | jq -e '
      .NSPrivacyTracking == false
      and (.NSPrivacyTrackingDomains | length) == 0
      and (.NSPrivacyCollectedDataTypes | length) == 0
    ' >/dev/null \
    || fail "$manifest declares tracking or collected data"
done

for catalog in \
  KnitNote/Localization/Localizable.xcstrings \
  KnitNoteWatch/Localizable.xcstrings \
  KnitNoteShare/Localizable.xcstrings; do
  jq -e '
    def localization_is_complete:
      type == "object"
      and length > 0
      and (
        if has("stringUnit") then
          (.stringUnit.value | type == "string" and length > 0)
        else
          all(.[]; localization_is_complete)
        end
      );
    (.strings | length) > 0
    and all(
      .strings[];
      (.localizations.en | localization_is_complete)
      and (.localizations."zh-Hant" | localization_is_complete)
    )
  ' "$catalog" >/dev/null \
    || fail "$catalog has an incomplete English or Traditional Chinese variation"
done

python3 AppStore/Verification/metadata_check.py AppStore/Metadata
python3 AppStore/Verification/commercial_release_check.py \
  --offline \
  --configuration \
  "${KNITNOTE_COMMERCIAL_CONFIGURATION:-AppStore/CommercialConfiguration.json}"
git diff --check

if rg -n "URLSession|NWConnection|Firebase|Analytics|Telemetry|tracking|https?://" \
  KnitNote KnitNoteWatch KnitNoteShare Sources/KnitNoteCore Package.swift project.yml \
  --glob '*.swift' --glob '*.yml' --glob 'Package.swift'; then
  echo "release audit: inspect unexpected network, analytics, or tracking source above" >&2
  exit 1
fi

if [[ -n "$ARCHIVES" ]]; then
  IOS="$ARCHIVES/KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
  MAC="$ARCHIVES/KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
  WATCH="$IOS/Watch/KnitNoteWatch.app"
  SHARE="$IOS/PlugIns/KnitNoteShare.appex"
  for path in "$IOS" "$WATCH" "$SHARE" "$MAC"; do
    [[ -d "$path" ]] || { echo "release audit: missing app bundle: $path" >&2; exit 1; }
  done
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$IOS/Info.plist")" == "com.phillon.KnitNote" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WATCH/Info.plist")" == "com.phillon.KnitNote.watch" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :WKCompanionAppBundleIdentifier' "$WATCH/Info.plist")" == "com.phillon.KnitNote" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SHARE/Info.plist")" == "com.phillon.KnitNote.share" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MAC/Contents/Info.plist")" == "com.phillon.KnitNote" ]]
  for plist in \
    "$IOS/Info.plist" \
    "$WATCH/Info.plist" \
    "$SHARE/Info.plist" \
    "$MAC/Contents/Info.plist"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$EXPECTED_VERSION" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$EXPECTED_BUILD" ]]
  done
  plutil -lint \
    "$IOS/PrivacyInfo.xcprivacy" \
    "$WATCH/PrivacyInfo.xcprivacy" \
    "$SHARE/PrivacyInfo.xcprivacy" \
    "$MAC/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
  codesign --verify --deep --strict "$IOS"
  codesign --verify --deep --strict "$MAC"
  verify_signed_app_group "$IOS"
  verify_signed_app_group "$SHARE"
fi

echo "RELEASE AUDIT: PASS"
