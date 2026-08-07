#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARCHIVES=""
EXPECTED_COMMIT=""
PROVENANCE=""
MODE=""
EXPECTED_LOCALES=(en zh-Hant zh-Hans de fr ja nb sv fi da ko el)
EXPECTED_LOCALES_JSON='["en","zh-Hant","zh-Hans","de","fr","ja","nb","sv","fi","da","ko","el"]'
PROJECT_FILE="${KNITNOTE_PROJECT_FILE:-KnitNote.xcodeproj/project.pbxproj}"
INFO_PLIST_CATALOG="${KNITNOTE_INFO_PLIST_CATALOG:-KnitNote/Localization/InfoPlist.xcstrings}"
MAIN_INFO_PLIST="${KNITNOTE_MAIN_INFO_PLIST:-KnitNote/Info.plist}"
WATCH_INFO_PLIST="${KNITNOTE_WATCH_INFO_PLIST:-KnitNoteWatch/Info.plist}"
SHARE_INFO_PLIST="${KNITNOTE_SHARE_INFO_PLIST:-KnitNoteShare/Info.plist}"
PROJECT_SCAN_ROOT="${KNITNOTE_PROJECT_SCAN_ROOT:-$ROOT}"
SOURCE_ROOT="${KNITNOTE_AUDIT_GIT_ROOT:-$ROOT}"
EXPECTED_TEAM="9CFPAUL5N5"
RELEASE_140_SOURCE_BASELINE="ca3014146f2b9156b71b5104f7fea7e5fbd02839"

usage() {
  echo "usage: release_audit.sh (--static-only | --archives DIR --expected-commit SHA --provenance FILE)" >&2
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

verify_privacy_manifest() {
  local manifest="$1"
  plutil -convert json -o - "$manifest" | jq -e '
    .NSPrivacyTracking == false
    and (.NSPrivacyTrackingDomains | length) == 0
    and (.NSPrivacyCollectedDataTypes | length) == 0
  ' >/dev/null || fail "$manifest declares tracking or collected data"
}

verify_privacy_matches_source() {
  local label="$1" archived="$2" source="$3" archived_json source_json
  verify_privacy_manifest "$archived"
  archived_json="$(plutil -convert json -o - "$archived" | jq -S .)"
  source_json="$(plutil -convert json -o - "$source" | jq -S .)"
  [[ "$archived_json" == "$source_json" ]] \
    || fail "$label archived privacy manifest differs semantically from source"
}

verify_signing_identity() {
  local label="$1" bundle="$2" profile="$3" bundle_id="$4" expected_group="$5" details cert_prefix profile_json
  codesign --verify --deep --strict "$bundle" || fail "$label signature verification failed"
  details="$(codesign -dvv "$bundle" 2>&1)"
  [[ "$details" == *"TeamIdentifier=$EXPECTED_TEAM"* ]] \
    || fail "$label signature team is not $EXPECTED_TEAM"
  [[ "$details" == *"Authority=Apple Distribution:"*"($EXPECTED_TEAM)"* ]] \
    || fail "$label is not signed by the expected Apple Distribution certificate"
  [[ -f "$profile" ]] || fail "$label embedded provisioning profile is missing"
  cert_prefix="$(mktemp "${TMPDIR:-/tmp}/knitnote-signing-cert.XXXXXX")"
  rm -f "$cert_prefix"
  profile_json="$(mktemp "${TMPDIR:-/tmp}/knitnote-profile.XXXXXX")"
  codesign -d --extract-certificates "$cert_prefix" "$bundle" 2>/dev/null \
    || { rm -f "$cert_prefix"* "$profile_json"; fail "$label signing certificate extraction failed"; }
  security cms -D -i "$profile" >"$profile_json"
  python3 - "$profile_json" "$EXPECTED_TEAM" "$bundle_id" "$expected_group" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json"; fail "$label provisioning profile is not App Store distribution for $EXPECTED_TEAM"; }
import plistlib
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
team, bundle, group = sys.argv[2:]
entitlements = profile.get("Entitlements", {})
identifier = entitlements.get("application-identifier", entitlements.get("com.apple.application-identifier"))
groups = entitlements.get("com.apple.security.application-groups", [])
valid = (
    profile.get("TeamIdentifier") == [team]
    and entitlements.get("get-task-allow") is False
    and identifier == f"{team}.{bundle}"
    and groups == ([group] if group else [])
    and "ProvisionedDevices" not in profile
    and "ProvisionsAllDevices" not in profile
)
raise SystemExit(0 if valid else 1)
PY
  python3 - "$profile_json" "${cert_prefix}0" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json"; fail "$label signing certificate is not present in its provisioning profile"; }
import plistlib
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
leaf = Path(sys.argv[2]).read_bytes()
certificates = profile.get("DeveloperCertificates", [])
raise SystemExit(0 if leaf in certificates else 1)
PY
  rm -f "$cert_prefix"* "$profile_json"
}

verify_project_inventory() {
  python3 - "$PROJECT_SCAN_ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
projects = sorted(
    path.name for path in root.glob("KnitNote*.xcodeproj")
    if (path / "project.pbxproj").is_file()
    or any((path / "xcshareddata" / "xcschemes").glob("*.xcscheme"))
)
if projects != ["KnitNote.xcodeproj"]:
    raise SystemExit(f"release audit: top-level shared buildable projects must be only KnitNote.xcodeproj; found {projects}")
PY
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
    || fail "$label CFBundleLocalizations do not match the twelve release locales"
}

verify_bundle_localizations() {
  local label="$1" plist="$2" resources="$3" locale
  for locale in "${EXPECTED_LOCALES[@]}"; do
    [[ -d "$resources/$locale.lproj" ]] \
      || fail "$label bundle is missing $locale.lproj"
    find "$resources/$locale.lproj" -type f -size +0c -print -quit | grep -q . \
      || fail "$label bundle $locale.lproj has no non-empty localized resource"
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
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE="static"
      shift
      ;;
    --archives)
      [[ -z "$MODE" && $# -ge 2 && -n "$2" && "$2" != --* ]] \
        || { usage; exit 2; }
      MODE="archives"
      ARCHIVES="$2"
      shift 2
      ;;
    --expected-commit)
      [[ $# -ge 2 && -z "$EXPECTED_COMMIT" ]] || { usage; exit 2; }
      EXPECTED_COMMIT="$2"
      shift 2
      ;;
    --provenance)
      [[ $# -ge 2 && -z "$PROVENANCE" ]] || { usage; exit 2; }
      PROVENANCE="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$MODE" ]] || { usage; exit 2; }
if [[ "$MODE" == "archives" ]]; then
  [[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ && -f "$PROVENANCE" ]] || { usage; exit 2; }
else
  [[ -z "$EXPECTED_COMMIT" && -z "$PROVENANCE" ]] || { usage; exit 2; }
fi

if [[ "$MODE" == "archives" ]]; then
  swift test --disable-sandbox
fi

SPEC_JSON="$(mktemp "${TMPDIR:-/tmp}/knitnote-release-spec.XXXXXX")"
trap 'rm -f "$SPEC_JSON"' EXIT
xcodegen dump --type parsed-json >"$SPEC_JSON"
verify_project_regions
verify_project_inventory
git merge-base --is-ancestor "$RELEASE_140_SOURCE_BASELINE" HEAD \
  || fail "candidate is not descended from the recorded 1.4.0 source baseline"

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

EXPECTED_VERSION="1.4.1"
EXPECTED_BUILD="8"
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
  verify_privacy_manifest "$manifest"
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
    || fail "$catalog has an incomplete twelve-locale variation"
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
    || fail "$catalog localization key domain does not match the twelve release locales"
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
  [[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] \
    || fail "expected source revision does not match repository HEAD"
  [[ -z "$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=normal)" ]] \
    || fail "source worktree is dirty"
  jq -e --arg commit "$EXPECTED_COMMIT" '
    .sourceCommit == $commit
    and (.artifacts | type == "object")
    and ((.artifacts | keys | sort) == (["ios", "macos", "share", "watch"] | sort))
    and all(.artifacts[]; (.path | type == "string" and length > 0) and (.sha256 | test("^[0-9a-f]{64}$")))
  ' "$PROVENANCE" >/dev/null \
    || fail "provenance manifest sourceCommit does not match"
  jq -e '
    .artifacts.ios.path == "KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app/KnitNote"
    and .artifacts.watch.path == "KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app/Watch/KnitNoteWatch.app/KnitNoteWatch"
    and .artifacts.share.path == "KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app/PlugIns/KnitNoteShare.appex/KnitNoteShare"
    and .artifacts.macos.path == "KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app/Contents/MacOS/KnitNote"
    and (([.artifacts[].path] | unique | length) == 4)
  ' "$PROVENANCE" >/dev/null || fail "provenance artifact paths do not match canonical release executables"
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
  for product in \
    "iOS|$IOS/Info.plist" \
    "Watch|$WATCH/Info.plist" \
    "Share|$SHARE/Info.plist" \
    "macOS|$MAC/Contents/Info.plist"; do
    label="${product%%|*}"
    plist="${product#*|}"
    product_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
    product_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    [[ "$product_version" == "$EXPECTED_VERSION" ]] \
      || fail "$label product version is $product_version, expected $EXPECTED_VERSION"
    [[ "$product_build" == "$EXPECTED_BUILD" ]] \
      || fail "$label product build is $product_build, expected $EXPECTED_BUILD"
    product_revision="$(/usr/libexec/PlistBuddy -c 'Print :KnitNoteSourceRevision' "$plist")"
    [[ "$product_revision" == "$EXPECTED_COMMIT" ]] \
      || fail "$label product source revision does not match expected commit"
  done
  plutil -lint \
    "$IOS/PrivacyInfo.xcprivacy" \
    "$WATCH/PrivacyInfo.xcprivacy" \
    "$SHARE/PrivacyInfo.xcprivacy" \
    "$MAC/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
  verify_privacy_matches_source "iOS" "$IOS/PrivacyInfo.xcprivacy" "KnitNote/PrivacyInfo.xcprivacy"
  verify_privacy_matches_source "Watch" "$WATCH/PrivacyInfo.xcprivacy" "KnitNoteWatch/PrivacyInfo.xcprivacy"
  verify_privacy_matches_source "Share" "$SHARE/PrivacyInfo.xcprivacy" "KnitNoteShare/PrivacyInfo.xcprivacy"
  verify_privacy_matches_source "macOS" "$MAC/Contents/Resources/PrivacyInfo.xcprivacy" "KnitNote/PrivacyInfo.xcprivacy"
  verify_signing_identity "iOS" "$IOS" "$IOS/embedded.mobileprovision" "com.phillon.KnitNote" "group.com.phillon.KnitNote"
  verify_signing_identity "Watch" "$WATCH" "$WATCH/embedded.mobileprovision" "com.phillon.KnitNote.watch" ""
  verify_signing_identity "Share" "$SHARE" "$SHARE/embedded.mobileprovision" "com.phillon.KnitNote.share" "group.com.phillon.KnitNote"
  verify_signing_identity "macOS" "$MAC" "$MAC/Contents/embedded.provisionprofile" "com.phillon.KnitNote" ""
  verify_signed_app_group "$IOS"
  verify_signed_app_group "$SHARE"
  while IFS=$'\t' read -r artifact relative expected_hash; do
    file="$ARCHIVES/$relative"
    [[ -f "$file" ]] || fail "provenance artifact $artifact is missing: $relative"
    actual_hash="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || fail "provenance hash mismatch for $artifact"
  done < <(jq -r '.artifacts | to_entries[] | [.key, .value.path, .value.sha256] | @tsv' "$PROVENANCE")
fi

if [[ "$MODE" == "archives" ]]; then
  echo "RELEASE AUDIT: PASS"
else
  echo "STATIC RELEASE AUDIT: PASS"
fi
