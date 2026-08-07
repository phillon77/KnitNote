#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"

ARCHIVES=""
EXPECTED_COMMIT=""
PROVENANCE=""
MODE=""
TEST_ONLY=0
EXPECTED_LOCALES=(en zh-Hant zh-Hans de fr ja nb sv fi da ko el)
EXPECTED_LOCALES_JSON='["en","zh-Hant","zh-Hans","de","fr","ja","nb","sv","fi","da","ko","el"]'
IOS_INFO_PLIST_KEYS_JSON='["CFBundleDisplayName","CFBundleName","KnitNote Backup","NSCameraUsageDescription"]'
MAC_INFO_PLIST_KEYS_JSON='["CFBundleDisplayName","CFBundleName","KnitNote Backup","NSCameraUsageDescription"]'
PROJECT_FILE="KnitNote.xcodeproj/project.pbxproj"
INFO_PLIST_CATALOG="KnitNote/Localization/InfoPlist.xcstrings"
MAIN_INFO_PLIST="KnitNote/Info.plist"
WATCH_INFO_PLIST="KnitNoteWatch/Info.plist"
SHARE_INFO_PLIST="KnitNoteShare/Info.plist"
MAC_ENTITLEMENTS="KnitNote/KnitNote-macOS.entitlements"
PROJECT_SCAN_ROOT="$ROOT"
GIT=/usr/bin/git
CODESIGN=/usr/bin/codesign
SECURITY=/usr/bin/security
PLUTIL=/usr/bin/plutil
SWIFT=/usr/bin/swift
XCODEGEN=/opt/homebrew/bin/xcodegen
EXPECTED_TEAM="9CFPAUL5N5"
RELEASE_140_SOURCE_BASELINE="ca3014146f2b9156b71b5104f7fea7e5fbd02839"

usage() {
  echo "usage: release_audit.sh [--test-only] (--static-only | --archives DIR --expected-commit SHA --provenance FILE)" >&2
}

fail() {
  echo "release audit: $*" >&2
  exit 1
}

verify_mac_security_entitlements() {
  local label="$1" plist="$2" mode="${3:-source}"
  "$PLUTIL" -convert json -o - "$plist" \
    | jq -e --arg mode "$mode" '
      def production_security: {
        "com.apple.security.app-sandbox": true,
        "com.apple.security.files.user-selected.read-write": true,
        "com.apple.security.network.client": true
      };
      if $mode == "source" then
        . == production_security
      else
        (with_entries(select(.key | startswith("com.apple.security."))) == production_security)
        and ((keys - [
          "application-identifier",
          "com.apple.application-identifier",
          "com.apple.developer.team-identifier",
          "get-task-allow",
          "com.apple.security.app-sandbox",
          "com.apple.security.files.user-selected.read-write",
          "com.apple.security.network.client"
        ]) | length == 0)
      end
    ' >/dev/null \
    || fail "$label entitlements do not match the production security contract"
}

verify_signed_app_group() {
  local bundle="$1"
  "$CODESIGN" -d --entitlements :- "$bundle" 2>/dev/null \
    | "$PLUTIL" -convert json -o - -- - \
    | jq -e '."com.apple.security.application-groups"
      == ["group.com.phillon.KnitNote"]' >/dev/null \
    || fail "$bundle signed entitlements do not contain only the production App Group"
}

verify_privacy_manifest() {
  local manifest="$1"
  "$PLUTIL" -convert json -o - "$manifest" | jq -e '
    .NSPrivacyTracking == false
    and (.NSPrivacyTrackingDomains | length) == 0
    and (.NSPrivacyCollectedDataTypes | length) == 0
  ' >/dev/null || fail "$manifest declares tracking or collected data"
}

verify_privacy_matches_source() {
  local label="$1" archived="$2" source="$3" archived_json source_json
  verify_privacy_manifest "$archived"
  archived_json="$("$PLUTIL" -convert json -o - "$archived" | jq -S .)"
  source_json="$("$PLUTIL" -convert json -o - "$source" | jq -S .)"
  [[ "$archived_json" == "$source_json" ]] \
    || fail "$label archived privacy manifest differs semantically from source"
}

verify_signing_identity() {
  local label="$1" bundle="$2" profile="$3" bundle_id="$4" expected_group="$5" details cert_prefix profile_json signed_json
  "$CODESIGN" --verify --deep --strict "$bundle" || fail "$label signature verification failed"
  details="$("$CODESIGN" -dvv "$bundle" 2>&1)"
  [[ "$details" == *"TeamIdentifier=$EXPECTED_TEAM"* ]] \
    || fail "$label signature team is not $EXPECTED_TEAM"
  [[ "$details" == *"Authority=Apple Distribution:"*"($EXPECTED_TEAM)"* ]] \
    || fail "$label is not signed by the expected Apple Distribution certificate"
  [[ -f "$profile" ]] || fail "$label embedded provisioning profile is missing"
  cert_prefix="$(mktemp "${TMPDIR:-/tmp}/knitnote-signing-cert.XXXXXX")"
  rm -f "$cert_prefix"
  profile_json="$(mktemp "${TMPDIR:-/tmp}/knitnote-profile.XXXXXX")"
  signed_json="$(mktemp "${TMPDIR:-/tmp}/knitnote-signed-entitlements.XXXXXX")"
  "$CODESIGN" -d "--extract-certificates=$cert_prefix" "$bundle" 2>/dev/null \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label signing certificate extraction failed"; }
  "$SECURITY" cms -D -i "$profile" >"$profile_json" \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label provisioning profile decode failed"; }
  python3 - "$profile_json" "$EXPECTED_TEAM" "$bundle_id" "$expected_group" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label provisioning profile is expired or is not App Store distribution for $EXPECTED_TEAM"; }
import plistlib
import datetime
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
team, bundle, group = sys.argv[2:]
entitlements = profile.get("Entitlements", {})
identifier = entitlements.get("application-identifier", entitlements.get("com.apple.application-identifier"))
groups = entitlements.get("com.apple.security.application-groups", [])
expiration = profile.get("ExpirationDate")
if isinstance(expiration, datetime.datetime) and expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
valid = (
    profile.get("TeamIdentifier") == [team]
    and entitlements.get("get-task-allow") is False
    and identifier == f"{team}.{bundle}"
    and groups == ([group] if group else [])
    and "ProvisionedDevices" not in profile
    and "ProvisionsAllDevices" not in profile
    and isinstance(expiration, datetime.datetime)
    and expiration > datetime.datetime.now(datetime.timezone.utc)
)
raise SystemExit(0 if valid else 1)
PY
  python3 - "$profile_json" "${cert_prefix}0" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label signing certificate is not present in its provisioning profile"; }
import plistlib
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
leaf = Path(sys.argv[2]).read_bytes()
certificates = profile.get("DeveloperCertificates", [])
raise SystemExit(0 if leaf in certificates else 1)
PY
  "$CODESIGN" -d --entitlements :- "$bundle" 2>/dev/null \
    | "$PLUTIL" -convert binary1 -o "$signed_json" -- - \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label signed entitlement decode failed"; }
  python3 - "$profile_json" "$signed_json" "$EXPECTED_TEAM" "$bundle_id" "$expected_group" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label signed entitlements do not match its provisioning profile"; }
import plistlib
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes()).get("Entitlements", {})
signed = plistlib.loads(Path(sys.argv[2]).read_bytes())
team, bundle, group = sys.argv[3:]
def app_id(value):
    return value.get("application-identifier", value.get("com.apple.application-identifier"))
expected_id = f"{team}.{bundle}"
expected_groups = [group] if group else []
valid = (
    app_id(profile) == expected_id
    and app_id(signed) == expected_id
    and signed.get("com.apple.developer.team-identifier") == team
    and signed.get("get-task-allow", False) is False
    and profile.get("com.apple.security.application-groups", []) == expected_groups
    and signed.get("com.apple.security.application-groups", []) == expected_groups
)
raise SystemExit(0 if valid else 1)
PY
  if [[ "$label" == "macOS" ]]; then
    verify_mac_security_entitlements "macOS signed" "$signed_json" signed
  fi
  rm -f "$cert_prefix"* "$profile_json" "$signed_json"
}

verify_project_inventory() {
  python3 - "$PROJECT_SCAN_ROOT" <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET
import sys
root = Path(sys.argv[1])
projects = sorted(path for path in root.glob("*.xcodeproj") if path.is_dir())
schemes = {
    project.name: sorted(path.name for path in (project / "xcshareddata" / "xcschemes").glob("*.xcscheme"))
    for project in projects
}
expected_schemes = ["KnitNote.xcscheme", "KnitNoteShare.xcscheme", "KnitNoteWatch.xcscheme"]
shipping_products = set()
for project in projects:
    for scheme in (project / "xcshareddata" / "xcschemes").glob("*.xcscheme"):
        try:
            tree = ET.parse(scheme)
        except ET.ParseError:
            continue
        for reference in tree.iter("BuildableReference"):
            product = reference.attrib.get("BuildableName", "")
            if product in {"KnitNote.app", "KnitNoteWatch.app", "KnitNoteShare.appex"}:
                shipping_products.add((project.name, scheme.name, product))
valid = (
    [project.name for project in projects] == ["KnitNote.xcodeproj"]
    and schemes.get("KnitNote.xcodeproj") == expected_schemes
    and {product for _, _, product in shipping_products}
        == {"KnitNote.app", "KnitNoteWatch.app", "KnitNoteShare.appex"}
    and all(project == "KnitNote.xcodeproj" for project, _, _ in shipping_products)
)
if not valid:
    raise SystemExit(
        "release audit: top-level Xcode project and shared scheme inventory is not canonical; "
        f"projects={[project.name for project in projects]}, schemes={schemes}, products={sorted(shipping_products)}"
    )
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
  local label="$1" plist="$2" resources="$3" catalog="$4" locale
  for locale in "${EXPECTED_LOCALES[@]}"; do
    [[ -d "$resources/$locale.lproj" ]] \
      || fail "$label bundle is missing $locale.lproj"
  done
  python3 - "$label" "$resources" "$catalog" "$PLUTIL" "${EXPECTED_LOCALES[@]}" <<'PY'
import json
import plistlib
import subprocess
from pathlib import Path
import sys

label, resources, catalog, plutil, *expected = sys.argv[1:]
resources = Path(resources)
actual = {
    path.name.removesuffix(".lproj")
    for path in resources.iterdir()
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
expected_keys = set(json.loads(Path(catalog).read_text(encoding="utf-8"))["strings"])
if not expected_keys:
    raise SystemExit(f"release audit: {label} source localization key domain is empty")
for locale in expected:
    directory = resources / f"{locale}.lproj"
    tables = [directory / "Localizable.strings", directory / "Localizable.stringsdict"]
    found = set()
    parsed_any = False
    for table in tables:
        if not table.exists():
            continue
        try:
            conversion = subprocess.run(
                [plutil, "-convert", "binary1", "-o", "-", "--", str(table)],
                check=True,
                capture_output=True,
            )
            value = plistlib.loads(conversion.stdout)
        except Exception as error:
            raise SystemExit(f"release audit: {label} {locale} {table.name} is not a valid compiled localization table: {error}")
        if not isinstance(value, dict) or not value:
            raise SystemExit(f"release audit: {label} {locale} {table.name} is empty")
        parsed_any = True
        found.update(value)
    if not parsed_any:
        raise SystemExit(f"release audit: {label} bundle {locale}.lproj has no compiled localization table")
    if found != expected_keys:
        missing = sorted(expected_keys - found)[:5]
        extra = sorted(found - expected_keys)[:5]
        raise SystemExit(
            f"release audit: {label} {locale} compiled localization key domain differs from source; "
            f"missing={missing}, extra={extra}"
        )
PY
  verify_declared_localizations "$label" "$plist"
}

verify_info_plist_localizations() {
  local label="$1" plist="$2" resources="$3" expected_keys_json="$4"
  python3 - "$label" "$plist" "$resources" "$INFO_PLIST_CATALOG" "$PLUTIL" \
    "$expected_keys_json" "${EXPECTED_LOCALES[@]}" <<'PY'
import json
import plistlib
import subprocess
from pathlib import Path
import sys

label, plist_path, resources_path, catalog_path, plutil, expected_keys_json, *locales = sys.argv[1:]
plist = plistlib.loads(Path(plist_path).read_bytes())
resources = Path(resources_path)
catalog = json.loads(Path(catalog_path).read_text(encoding="utf-8"))
source = catalog.get("sourceLanguage")
entries = catalog.get("strings", {})
expected_keys = set(json.loads(expected_keys_json))
if source != "en" or set(entries) != expected_keys:
    raise SystemExit(
        f"release audit: {label} InfoPlist source key domain differs from its product contract"
    )

def catalog_source_value(key):
    localization = (entries[key].get("localizations") or {}).get(source)
    if localization is None:
        return key
    unit = localization.get("stringUnit")
    value = unit.get("value") if isinstance(unit, dict) else None
    if not isinstance(value, str) or not value:
        raise SystemExit(
            f"release audit: {label} InfoPlist English source value is invalid for {key!r}"
        )
    return value

base_values = {}
for key in sorted(expected_keys - {"KnitNote Backup"}):
    value = plist.get(key)
    if not isinstance(value, str) or value != catalog_source_value(key):
        raise SystemExit(
            f"release audit: {label} Info.plist has no English source fallback at the required path for {key!r}"
        )
    base_values[key] = value

declarations = plist.get("UTExportedTypeDeclarations")
backup_declarations = [
    declaration
    for declaration in declarations if isinstance(declaration, dict)
    and declaration.get("UTTypeIdentifier") == "com.phillon.KnitNote.backup"
] if isinstance(declarations, list) else []
if (
    len(backup_declarations) != 1
    or backup_declarations[0].get("UTTypeDescription") != catalog_source_value("KnitNote Backup")
):
    raise SystemExit(
        f"release audit: {label} Info.plist has no English source fallback at the required path for 'KnitNote Backup'"
    )
base_values["KnitNote Backup"] = backup_declarations[0]["UTTypeDescription"]

for locale in locales:
    table = resources / f"{locale}.lproj" / "InfoPlist.strings"
    if not table.is_file():
        raise SystemExit(
            f"release audit: {label} bundle is missing {locale}.lproj/InfoPlist.strings"
        )
    try:
        conversion = subprocess.run(
            [plutil, "-convert", "binary1", "-o", "-", "--", str(table)],
            check=True,
            capture_output=True,
        )
        compiled = plistlib.loads(conversion.stdout)
    except Exception as error:
        raise SystemExit(
            f"release audit: {label} {locale} InfoPlist.strings is not a valid compiled localization table: {error}"
        )
    if not isinstance(compiled, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in compiled.items()):
        raise SystemExit(
            f"release audit: {label} {locale} InfoPlist.strings is not a string dictionary"
        )
    if not set(compiled).issubset(expected_keys):
        extra = sorted(set(compiled) - expected_keys)
        raise SystemExit(
            f"release audit: {label} {locale} InfoPlist compiled key domain differs from source; extra={extra[:5]}"
        )
    for key in sorted(expected_keys):
        localization = (entries[key].get("localizations") or {}).get(locale)
        if localization is None:
            if locale != source:
                raise SystemExit(
                    f"release audit: {label} {locale} InfoPlist source localization is missing for {key!r}"
                )
            expected = key
        else:
            unit = localization.get("stringUnit")
            expected = unit.get("value") if isinstance(unit, dict) else None
            if not isinstance(expected, str) or not expected:
                raise SystemExit(
                    f"release audit: {label} {locale} InfoPlist source value is invalid for {key!r}"
                )
        effective = compiled[key] if key in compiled else base_values[key]
        if effective != expected:
            raise SystemExit(
                f"release audit: {label} {locale} InfoPlist effective value differs for {key!r}"
            )
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-only)
      [[ "$TEST_ONLY" == 0 ]] || { usage; exit 2; }
      TEST_ONLY=1
      shift
      ;;
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

if [[ "$TEST_ONLY" == 1 ]]; then
  PROJECT_FILE="${KNITNOTE_PROJECT_FILE:-$PROJECT_FILE}"
  INFO_PLIST_CATALOG="${KNITNOTE_INFO_PLIST_CATALOG:-$INFO_PLIST_CATALOG}"
  MAIN_INFO_PLIST="${KNITNOTE_MAIN_INFO_PLIST:-$MAIN_INFO_PLIST}"
  WATCH_INFO_PLIST="${KNITNOTE_WATCH_INFO_PLIST:-$WATCH_INFO_PLIST}"
  SHARE_INFO_PLIST="${KNITNOTE_SHARE_INFO_PLIST:-$SHARE_INFO_PLIST}"
  MAC_ENTITLEMENTS="${KNITNOTE_MAC_ENTITLEMENTS:-$MAC_ENTITLEMENTS}"
  PROJECT_SCAN_ROOT="${KNITNOTE_PROJECT_SCAN_ROOT:-$PROJECT_SCAN_ROOT}"
  GIT="${KNITNOTE_GIT:-$GIT}"
  CODESIGN="${KNITNOTE_CODESIGN:-$CODESIGN}"
  SECURITY="${KNITNOTE_SECURITY:-$SECURITY}"
  SWIFT="${KNITNOTE_SWIFT:-$SWIFT}"
else
  for variable in ${!KNITNOTE_@}; do
    fail "production audit rejects override $variable; use --test-only only for fixtures"
  done
  PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
  export PATH
  [[ "$($GIT -C "$ROOT" rev-parse --show-toplevel)" == "$ROOT" ]] \
    || fail "audit script is not running from the canonical repository root"
fi

[[ -n "$MODE" ]] || { usage; exit 2; }
if [[ "$MODE" == "archives" ]]; then
  [[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ && -f "$PROVENANCE" ]] || { usage; exit 2; }
else
  [[ -z "$EXPECTED_COMMIT" && -z "$PROVENANCE" ]] || { usage; exit 2; }
fi

if [[ "$MODE" == "archives" ]]; then
  "$SWIFT" test --disable-sandbox
fi

SPEC_JSON="$(mktemp "${TMPDIR:-/tmp}/knitnote-release-spec.XXXXXX")"
trap 'rm -f "$SPEC_JSON"' EXIT
"$XCODEGEN" dump --type parsed-json >"$SPEC_JSON"
verify_project_regions
verify_project_inventory
"$GIT" merge-base --is-ancestor "$RELEASE_140_SOURCE_BASELINE" HEAD \
  || fail "candidate is not descended from the recorded 1.4.0 source baseline"

"$PLUTIL" -lint \
  "$MAIN_INFO_PLIST" \
  "$WATCH_INFO_PLIST" \
  "$SHARE_INFO_PLIST" \
  KnitNote/PrivacyInfo.xcprivacy \
  KnitNoteWatch/PrivacyInfo.xcprivacy \
  KnitNoteShare/PrivacyInfo.xcprivacy \
  KnitNote/KnitNote-iOS.entitlements \
  "$MAC_ENTITLEMENTS" \
  KnitNoteShare/KnitNoteShare.entitlements >/dev/null

verify_declared_localizations "Main source" "$MAIN_INFO_PLIST"
verify_declared_localizations "Watch source" "$WATCH_INFO_PLIST"
verify_declared_localizations "Share source" "$SHARE_INFO_PLIST"

EXPECTED_VERSION="1.4.1"
EXPECTED_BUILD="8"
for target in KnitNote KnitNoteWatch KnitNoteShare; do
  version="$(jq -er --arg target "$target" \
    '.targets[$target].settings.MARKETING_VERSION // .targets[$target].settings.base.MARKETING_VERSION' "$SPEC_JSON")"
  build="$(jq -er --arg target "$target" \
    '.targets[$target].settings.CURRENT_PROJECT_VERSION // .targets[$target].settings.base.CURRENT_PROJECT_VERSION' "$SPEC_JSON")"
  [[ "$version" == "$EXPECTED_VERSION" ]] \
    || fail "$target marketing version is $version, expected $EXPECTED_VERSION"
  [[ "$build" == "$EXPECTED_BUILD" ]] \
    || fail "$target build is $build, expected $EXPECTED_BUILD"
done

/usr/bin/grep -q 'static let currentVersion = 12' \
  Sources/KnitNoteCore/Projects/JSONProjectStore.swift \
  || fail "project archive schema is not 12"
/usr/bin/grep -q 'static let currentFormatVersion = 2' \
  Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift \
  || fail "backup manifest format is not 2"

for entitlements in \
  KnitNote/KnitNote-iOS.entitlements \
  KnitNoteShare/KnitNoteShare.entitlements; do
  "$PLUTIL" -convert json -o - "$entitlements" \
    | jq -e '."com.apple.security.application-groups"
      == ["group.com.phillon.KnitNote"]' >/dev/null \
    || fail "$entitlements does not contain only the production App Group"
done

verify_mac_security_entitlements "source Mac" "$MAC_ENTITLEMENTS" source

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
  "AppStore/CommercialConfiguration.json"
"$GIT" diff --check

if /usr/bin/grep -RInE --include='*.swift' --include='*.yml' --include='Package.swift' \
  "URLSession|NWConnection|Firebase|Analytics|Telemetry|tracking|https?://" \
  KnitNote KnitNoteWatch KnitNoteShare Sources/KnitNoteCore Package.swift project.yml; then
  echo "release audit: inspect unexpected network, analytics, or tracking source above" >&2
  exit 1
fi

if [[ -n "$ARCHIVES" ]]; then
  [[ "$("$GIT" -C "$ROOT" rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] \
    || fail "expected source revision does not match repository HEAD"
  [[ -z "$("$GIT" -C "$ROOT" status --porcelain --untracked-files=normal)" ]] \
    || fail "source worktree is dirty"
  python3 AppStore/Verification/release_archive_manifest.py verify \
    --archives "$ARCHIVES" --source-commit "$EXPECTED_COMMIT" --input "$PROVENANCE" \
    || fail "provenance sourceCommit or deterministic archive inventory mismatch"
  IOS="$ARCHIVES/KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
  MAC="$ARCHIVES/KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
  WATCH="$IOS/Watch/KnitNoteWatch.app"
  SHARE="$IOS/PlugIns/KnitNoteShare.appex"
  for path in "$IOS" "$WATCH" "$SHARE" "$MAC"; do
    [[ -d "$path" ]] || { echo "release audit: missing app bundle: $path" >&2; exit 1; }
  done
  verify_bundle_localizations "iOS" "$IOS/Info.plist" "$IOS" "KnitNote/Localization/Localizable.xcstrings"
  verify_bundle_localizations "Watch" "$WATCH/Info.plist" "$WATCH" "KnitNoteWatch/Localizable.xcstrings"
  verify_bundle_localizations "Share" "$SHARE/Info.plist" "$SHARE" "KnitNoteShare/Localizable.xcstrings"
  verify_bundle_localizations "macOS" "$MAC/Contents/Info.plist" "$MAC/Contents/Resources" "KnitNote/Localization/Localizable.xcstrings"
  verify_info_plist_localizations "iOS" "$IOS/Info.plist" "$IOS" "$IOS_INFO_PLIST_KEYS_JSON"
  verify_info_plist_localizations "macOS" "$MAC/Contents/Info.plist" "$MAC/Contents/Resources" "$MAC_INFO_PLIST_KEYS_JSON"
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
  "$PLUTIL" -lint \
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
fi

if [[ "$MODE" == "archives" ]]; then
  [[ "$TEST_ONLY" == 0 ]] && echo "RELEASE AUDIT: PASS" || echo "TEST FIXTURE ARCHIVE AUDIT: PASS"
else
  [[ "$TEST_ONLY" == 0 ]] && echo "STATIC RELEASE AUDIT: PASS" || echo "TEST FIXTURE STATIC AUDIT: PASS"
fi
