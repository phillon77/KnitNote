#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARCHIVES=""
STATIC_ONLY=0
EXPECTED_LOCALES=(en zh-Hant zh-Hans de fr ja)
EXPECTED_LOCALES_JSON='["en","zh-Hant","zh-Hans","de","fr","ja"]'
PROJECT_FILE="${KNITNOTE_PROJECT_FILE:-KnitNote.xcodeproj/project.pbxproj}"
INFO_PLIST_CATALOG="${KNITNOTE_INFO_PLIST_CATALOG:-KnitNote/Localization/InfoPlist.xcstrings}"
MAIN_INFO_PLIST="${KNITNOTE_MAIN_INFO_PLIST:-KnitNote/Info.plist}"
WATCH_INFO_PLIST="${KNITNOTE_WATCH_INFO_PLIST:-KnitNoteWatch/Info.plist}"
SHARE_INFO_PLIST="${KNITNOTE_SHARE_INFO_PLIST:-KnitNoteShare/Info.plist}"

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

verify_project_regions() {
  python3 - "$PROJECT_FILE" "${EXPECTED_LOCALES[@]}" <<'PY'
import re
import sys

project_path, *expected = sys.argv[1:]
text = open(project_path, encoding="utf-8").read()
development = re.search(r"\bdevelopmentRegion\s*=\s*([^;]+);", text)
if development is None or development.group(1).strip().strip('"') != "en":
    raise SystemExit("release audit: project developmentRegion is not en")

known = re.search(r"\bknownRegions\s*=\s*\((.*?)\);", text, re.DOTALL)
if known is None:
    raise SystemExit("release audit: project knownRegions are missing")
regions = set()
for line in known.group(1).splitlines():
    token = line.split("/*", 1)[0].strip().rstrip(",").strip().strip('"')
    if token:
        regions.add(token)
localized_regions = regions - {"Base"}
if localized_regions != set(expected):
    actual = ",".join(sorted(localized_regions))
    wanted = ",".join(sorted(expected))
    raise SystemExit(
        f"release audit: project knownRegions do not match; found [{actual}], expected [{wanted}]"
    )
PY
}

verify_declared_localizations() {
  local label="$1" plist="$2"
  plutil -convert json -o - "$plist" \
    | jq -e --argjson expected "$EXPECTED_LOCALES_JSON" '
      (.CFBundleLocalizations | type == "array")
      and ((.CFBundleLocalizations | sort) == ($expected | sort))
    ' >/dev/null \
    || fail "$label CFBundleLocalizations do not match the six release locales"
}

verify_bundle_localizations() {
  local label="$1" plist="$2" resources="$3" locale
  for locale in "${EXPECTED_LOCALES[@]}"; do
    [[ -d "$resources/$locale.lproj" ]] \
      || fail "$label bundle is missing $locale.lproj"
  done
  python3 - "$label" "$resources" "${EXPECTED_LOCALES[@]}" <<'PY'
from pathlib import Path
import sys

label, resources, *expected = sys.argv[1:]
actual = {
    path.name.removesuffix(".lproj")
    for path in Path(resources).iterdir()
    if path.is_dir() and path.name.endswith(".lproj")
}
# Base.lproj contains Interface Builder base resources; it is not a release locale.
localized = actual - {"Base"}
if localized != set(expected):
    found = ",".join(sorted(localized))
    wanted = ",".join(sorted(expected))
    raise SystemExit(
        f"release audit: {label} bundle localization directories do not match; "
        f"found [{found}], expected [{wanted}] (optional Base.lproj allowed)"
    )
PY
  verify_declared_localizations "$label" "$plist"
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
verify_project_regions

plutil -lint \
  "$MAIN_INFO_PLIST" \
  "$WATCH_INFO_PLIST" \
  "$SHARE_INFO_PLIST" \
  KnitNote/PrivacyInfo.xcprivacy \
  KnitNoteWatch/PrivacyInfo.xcprivacy \
  KnitNoteShare/PrivacyInfo.xcprivacy \
  KnitNote/KnitNote-iOS.entitlements \
  KnitNoteShare/KnitNoteShare.entitlements >/dev/null

verify_declared_localizations "Main source" "$MAIN_INFO_PLIST"
verify_declared_localizations "Watch source" "$WATCH_INFO_PLIST"
verify_declared_localizations "Share source" "$SHARE_INFO_PLIST"

EXPECTED_VERSION="1.3.1"
EXPECTED_BUILD="7"
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

rg -q 'static let currentVersion = 12' \
  Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  || fail "project archive schema is not 12"
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
  "$INFO_PLIST_CATALOG" \
  KnitNoteWatch/Localizable.xcstrings \
  KnitNoteShare/Localizable.xcstrings; do
  jq -e --argjson expected "$EXPECTED_LOCALES_JSON" '
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
    .sourceLanguage as $source
    | ($source == "en")
    and (.strings | length) > 0
    and all(
      .strings | to_entries[];
      . as $entry
      | all(
          $expected[];
          . as $locale
          | if $locale == $source and ($entry.value.localizations[$locale] == null)
            then ($entry.key | type == "string" and length > 0)
            else ($entry.value.localizations[$locale] | localization_is_complete)
            end
        )
    )
  ' "$catalog" >/dev/null \
    || fail "$catalog has an incomplete six-locale variation"
  jq -e --argjson expected "$EXPECTED_LOCALES_JSON" '
    .sourceLanguage as $source
    | ($source == "en")
    and (.strings | length > 0)
    and all(
      .strings | to_entries[];
      . as $entry
      | (($entry.value.localizations // {}) | keys) as $actual
      | (($actual + (
          if ($actual | index($source)) == null
          then [$source]
          else []
          end
        )) | sort) == ($expected | sort)
    )
  ' "$catalog" >/dev/null \
    || fail "$catalog localization key domain does not match the six release locales"
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
  verify_bundle_localizations "iOS" "$IOS/Info.plist" "$IOS"
  verify_bundle_localizations "Watch" "$WATCH/Info.plist" "$WATCH"
  verify_bundle_localizations "Share" "$SHARE/Info.plist" "$SHARE"
  verify_bundle_localizations "macOS" "$MAC/Contents/Info.plist" "$MAC/Contents/Resources"
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
