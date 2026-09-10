#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"

ARCHIVES=""
EXPECTED_COMMIT=""
PROVENANCE=""
MODE=""
TEST_ONLY=0
EXPECTED_LOCALES=(en zh-Hant zh-Hans de fr ja nb sv fi da ko el nl)
EXPECTED_LOCALES_JSON='["en","zh-Hant","zh-Hans","de","fr","ja","nb","sv","fi","da","ko","el","nl"]'
IOS_INFO_PLIST_KEYS_JSON='["CFBundleDisplayName","CFBundleName","KnitNote Backup","NSCameraUsageDescription"]'
MAC_INFO_PLIST_KEYS_JSON='["CFBundleDisplayName","CFBundleName","KnitNote Backup","NSCameraUsageDescription"]'
PROJECT_FILE="KnitNote.xcodeproj/project.pbxproj"
INFO_PLIST_CATALOG="KnitNote/Localization/InfoPlist.xcstrings"
MAIN_INFO_PLIST="KnitNote/Info.plist"
WATCH_INFO_PLIST="KnitNoteWatch/Info.plist"
SHARE_INFO_PLIST="KnitNoteShare/Info.plist"
IOS_ENTITLEMENTS="KnitNote/KnitNote-iOS.entitlements"
MAC_ENTITLEMENTS="KnitNote/KnitNote-macOS.entitlements"
SHARE_ENTITLEMENTS="KnitNoteShare/KnitNoteShare.entitlements"
PROJECT_ARCHIVE_SCHEMA_SOURCE="Sources/KnitNoteCore/Projects/ProjectArchiveSchema.swift"
PROJECT_SCAN_ROOT="$ROOT"
NETWORK_SCAN_ROOT="$ROOT"
GIT=/usr/bin/git
CODESIGN=/usr/bin/codesign
SECURITY=/usr/bin/security
PLUTIL=/usr/bin/plutil
SWIFT=/usr/bin/swift
DITTO=/usr/bin/ditto
PKGUTIL=/usr/sbin/pkgutil
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

verify_project_archive_schema() {
  python3 - "$PROJECT_ARCHIVE_SCHEMA_SOURCE" <<'PY' \
    || fail "project archive schema source is not canonical schema 14"
from pathlib import Path
import sys

expected = (
    b"extension ProjectArchive {\n"
    b"    public static let currentVersion = 14\n"
    b"}\n"
)
try:
    actual = Path(sys.argv[1]).read_bytes()
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if actual == expected else 1)
PY
}

verify_distribution_inventory() {
  local archives="$1"
  python3 - "$archives" <<'PY' || fail "Distribution inventory contains an unexpected or credential-bearing file"
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1]).resolve(strict=True)
expected = {
    "Distribution/iOS/KnitNote.ipa",
    "Distribution/iOS/DistributionSummary.plist",
    "Distribution/iOS/ExportOptions.plist",
    "Distribution/macOS/KnitNote.pkg",
    "Distribution/macOS/DistributionSummary.plist",
    "Distribution/macOS/ExportOptions.plist",
}
actual = set()
for path in (root / "Distribution").rglob("*"):
    relative = path.relative_to(root).as_posix()
    mode = path.lstat().st_mode
    if stat.S_ISDIR(mode):
        continue
    if path.is_symlink() or not stat.S_ISREG(mode):
        raise SystemExit(1)
    actual.add(relative)
raise SystemExit(0 if actual == expected else 1)
PY
}

verify_mac_package_signature() {
  local package="$1" signature
  signature="$("$PKGUTIL" --check-signature "$package" 2>&1)" \
    || fail "macOS pkg is not signed by the required trusted Apple installer distribution"
  python3 - "$EXPECTED_TEAM" "$signature" <<'PY' || fail "macOS pkg is not signed by the required trusted Apple installer distribution"
import re
import sys

team, output = sys.argv[1:]
lines = [line.strip() for line in output.splitlines()]
installer_leaf = re.compile(
    r"1\.\s+3rd Party Mac Developer Installer:.+ \(" + re.escape(team) + r"\)",
)
accepted_statuses = {
    "Status: signed by a certificate trusted by macOS",
    "Status: signed by a developer certificate issued by Apple (Development)",
}
status_lines = [line for line in lines if line.startswith("Status:")]
chain_headers = [index for index, line in enumerate(lines) if line == "Certificate Chain:"]
numbered_entries = []
if len(chain_headers) == 1:
    numbered_entries = [
        line
        for line in lines[chain_headers[0] + 1:]
        if re.match(r"^\d+\.\s+", line)
    ]
valid = (
    len(status_lines) == 1
    and status_lines[0] in accepted_statuses
    and len(chain_headers) == 1
    and len(numbered_entries) == 3
    and installer_leaf.fullmatch(numbered_entries[0])
    and numbered_entries[1] == "2. Apple Worldwide Developer Relations Certification Authority"
    and numbered_entries[2] == "3. Apple Root CA"
)
raise SystemExit(0 if valid else 1)
PY
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
      def source_cloudkit: {
        "com.apple.developer.icloud-container-identifiers": ["$(KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER)"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.aps-environment": "development"
      };
      if $mode == "source" then
        . == (production_security + source_cloudkit)
      else
        (with_entries(select(.key | startswith("com.apple.security."))) == production_security)
        and (."com.apple.developer.icloud-container-identifiers" == ["iCloud.com.phillon.KnitNote"])
        and (."com.apple.developer.icloud-services" == ["CloudKit"])
        and (."com.apple.developer.icloud-container-environment" == "Production")
        and (."com.apple.developer.aps-environment" == "production")
        and ((keys - [
          "com.apple.application-identifier",
          "com.apple.developer.team-identifier",
          "get-task-allow",
          "com.apple.developer.aps-environment",
          "com.apple.developer.icloud-container-environment",
          "com.apple.developer.icloud-container-identifiers",
          "com.apple.developer.icloud-services",
          "com.apple.security.app-sandbox",
          "com.apple.security.files.user-selected.read-write",
          "com.apple.security.network.client"
        ]) | length == 0)
      end
    ' >/dev/null \
    || fail "$label entitlements do not match the production security contract"
}

verify_signed_product_cloud_entitlements() {
  local label="$1" plist="$2"
  case "$label" in
    iOS)
      "$PLUTIL" -convert json -o - "$plist" \
        | jq -e '
          ."com.apple.developer.icloud-container-identifiers" == ["iCloud.com.phillon.KnitNote"]
          and ."com.apple.developer.icloud-services" == ["CloudKit"]
          and ."com.apple.developer.icloud-container-environment" == "Production"
          and ."aps-environment" == "production"
          and has("com.apple.developer.aps-environment") == false
          and ((keys - [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "get-task-allow",
            "com.apple.security.application-groups",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-environment",
            "aps-environment"
          ]) | length == 0)
        ' >/dev/null \
        || fail "$label signed entitlements do not match the exact CloudKit and APS contract"
      ;;
    macOS)
      verify_mac_security_entitlements "macOS signed" "$plist" signed
      ;;
    Watch)
      "$PLUTIL" -convert json -o - "$plist" \
        | jq -e '
          (keys | sort) == ([
            "application-identifier",
            "com.apple.developer.team-identifier",
            "get-task-allow"
          ] | sort)
        ' >/dev/null \
        || fail "$label signed entitlements do not match the CloudKit-free contract"
      ;;
    Share)
      "$PLUTIL" -convert json -o - "$plist" \
        | jq -e '
          (keys | sort) == ([
            "application-identifier",
            "com.apple.developer.team-identifier",
            "get-task-allow",
            "com.apple.security.application-groups"
          ] | sort)
        ' >/dev/null \
        || fail "$label signed entitlements do not match the CloudKit-free contract"
      ;;
  esac
}

verify_generated_entitlement_bindings() {
  python3 - "$PROJECT_FILE" <<'PY'
import sys
from pathlib import Path

class OpenStepError(Exception):
    pass

class OpenStepDictionary:
    def __init__(self, entries):
        self.entries = entries

class OpenStepScanner:
    punctuation = set("{}()=;,")

    def __init__(self, source):
        self.source = source
        self.index = 0

    def error(self, message):
        raise OpenStepError(f"{message} at byte {self.index}")

    def skip_ignored(self):
        while self.index < len(self.source):
            if self.source[self.index].isspace():
                self.index += 1
            elif self.source.startswith("//", self.index):
                newline = self.source.find("\n", self.index + 2)
                self.index = len(self.source) if newline < 0 else newline + 1
            elif self.source.startswith("/*", self.index):
                end = self.source.find("*/", self.index + 2)
                if end < 0:
                    self.error("unterminated comment")
                self.index = end + 2
            else:
                return

    def token(self):
        self.skip_ignored()
        if self.index >= len(self.source):
            return ("eof", "")
        character = self.source[self.index]
        if character in self.punctuation:
            self.index += 1
            return (character, character)
        if character == '"':
            return ("scalar", self.quoted())
        start = self.index
        while self.index < len(self.source):
            character = self.source[self.index]
            if character.isspace() or character in self.punctuation or character == '"':
                break
            if self.source.startswith("//", self.index) or self.source.startswith("/*", self.index):
                break
            self.index += 1
        if self.index == start:
            self.error("unexpected character")
        return ("scalar", self.source[start:self.index])

    def quoted(self):
        self.index += 1
        result = []
        simple = {
            'a': '\a', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r',
            't': '\t', 'v': '\v', '\\': '\\', '"': '"', "'": "'",
        }
        while self.index < len(self.source):
            character = self.source[self.index]
            self.index += 1
            if character == '"':
                return "".join(result)
            if character != '\\':
                result.append(character)
                continue
            if self.index >= len(self.source):
                self.error("unterminated escape")
            escape = self.source[self.index]
            self.index += 1
            if escape in simple:
                result.append(simple[escape])
            elif escape in ('U', 'u'):
                digits = self.source[self.index:self.index + 4]
                if len(digits) != 4 or any(c not in "0123456789abcdefABCDEF" for c in digits):
                    self.error("invalid Unicode escape")
                result.append(chr(int(digits, 16)))
                self.index += 4
            elif escape in "01234567":
                digits = escape
                while len(digits) < 3 and self.index < len(self.source) and self.source[self.index] in "01234567":
                    digits += self.source[self.index]
                    self.index += 1
                result.append(chr(int(digits, 8)))
            elif escape == '\n':
                pass
            else:
                self.error("unsupported escape")
        self.error("unterminated quoted string")

class OpenStepParser:
    def __init__(self, source):
        self.scanner = OpenStepScanner(source)
        self.lookahead = self.scanner.token()

    def take(self, kind):
        if self.lookahead[0] != kind:
            raise OpenStepError(f"expected {kind}, found {self.lookahead[0]}")
        value = self.lookahead[1]
        self.lookahead = self.scanner.token()
        return value

    def parse(self):
        value = self.value()
        self.take("eof")
        return value

    def value(self):
        if self.lookahead[0] == "{":
            return self.dictionary()
        if self.lookahead[0] == "(":
            return self.array()
        return self.take("scalar")

    def dictionary(self):
        self.take("{")
        entries = []
        while self.lookahead[0] != "}":
            key = self.take("scalar")
            self.take("=")
            entries.append((key, self.value()))
            self.take(";")
        self.take("}")
        return OpenStepDictionary(entries)

    def array(self):
        self.take("(")
        values = []
        while self.lookahead[0] != ")":
            values.append(self.value())
            if self.lookahead[0] == ",":
                self.take(",")
            elif self.lookahead[0] != ")":
                raise OpenStepError("expected comma or closing parenthesis")
        self.take(")")
        return values

def dictionary(value, error):
    if not isinstance(value, OpenStepDictionary):
        raise SystemExit(error)
    result = {}
    for key, item in value.entries:
        if key in result:
            raise SystemExit(f"release audit: duplicate OpenStep key {key!r} in {error}")
        result[key] = item
    return result

def scalar(value, error):
    if not isinstance(value, str):
        raise SystemExit(error)
    return value

def array(value, error):
    if not isinstance(value, list):
        raise SystemExit(error)
    return value

expected = {
    "KnitNote": {
        "CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]": "KnitNote/KnitNote-iOS.entitlements",
        "CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]": "KnitNote/KnitNote-iOS.entitlements",
        "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "KnitNote/KnitNote-macOS.entitlements",
    },
    "KnitNoteWatch": {},
    "KnitNoteShare": {
        "CODE_SIGN_ENTITLEMENTS": "KnitNoteShare/KnitNoteShare.entitlements",
    },
}
expected_info = {
    "KnitNote": {"INFOPLIST_FILE": "KnitNote/Info.plist"},
    "KnitNoteWatch": {"INFOPLIST_FILE": "KnitNoteWatch/Info.plist"},
    "KnitNoteShare": {"INFOPLIST_FILE": "KnitNoteShare/Info.plist"},
}
labels = {"KnitNote": "iOS/macOS", "KnitNoteWatch": "Watch", "KnitNoteShare": "Share"}
products = {
    "KnitNote": ("KnitNote", "com.apple.product-type.application", "KnitNote.app"),
    "KnitNoteWatch": ("KnitNoteWatch", "com.apple.product-type.application", "KnitNoteWatch.app"),
    "KnitNoteShare": ("KnitNoteShare", "com.apple.product-type.app-extension", "KnitNoteShare.appex"),
}

try:
    parsed = OpenStepParser(Path(sys.argv[1]).read_text(encoding="utf-8")).parse()
    project = dictionary(parsed, "generated project root dictionary")
    objects = dictionary(project["objects"], "generated project objects dictionary")
    root_reference = scalar(project["rootObject"], "release audit: generated project rootObject is invalid")
except (KeyError, OSError, UnicodeError, OpenStepError) as error:
    raise SystemExit(f"release audit: generated project is not a valid OpenStep property list: {error}")

def referenced_object(reference, error):
    reference = scalar(reference, error)
    try:
        value = objects[reference]
    except KeyError:
        raise SystemExit(error)
    return dictionary(value, error)

root = referenced_object(root_reference, "release audit: generated project object graph is invalid")
if root.get("isa") != "PBXProject":
    raise SystemExit("release audit: generated project object graph is invalid")

def configurations(owner, error):
    try:
        listing = referenced_object(owner["buildConfigurationList"], error)
        references = array(listing["buildConfigurations"], error)
    except KeyError:
        raise SystemExit(error)
    if listing.get("isa") != "XCConfigurationList":
        raise SystemExit(error)
    result = {}
    for reference in references:
        configuration = referenced_object(reference, error)
        if configuration.get("isa") != "XCBuildConfiguration":
            raise SystemExit(error)
        try:
            name = scalar(configuration["name"], error)
        except KeyError:
            raise SystemExit(error)
        if name in result:
            raise SystemExit(error)
        result[name] = configuration
    required = {"Debug", "Release"}
    if set(result) != required:
        raise SystemExit(error)
    return {name: result[name] for name in required}

project_error = "release audit: project CODE_SIGN_ENTITLEMENTS configuration is missing"
for configuration in configurations(root, project_error).values():
    if "baseConfigurationReference" in configuration:
        raise SystemExit("release audit: relevant project baseConfigurationReference is forbidden")
    try:
        settings = dictionary(configuration["buildSettings"], project_error)
    except KeyError:
        raise SystemExit(project_error)
    if any(key.startswith("CODE_SIGN_ENTITLEMENTS") for key in settings):
        raise SystemExit("release audit: project CODE_SIGN_ENTITLEMENTS must not be inherited")

targets = {}
try:
    target_references = array(root["targets"], "release audit: generated project target graph is invalid")
except KeyError:
    raise SystemExit("release audit: generated project target graph is invalid")
for reference in target_references:
    target = referenced_object(reference, "release audit: generated project target graph is invalid")
    name = target.get("name")
    if name in expected:
        if target.get("isa") != "PBXNativeTarget":
            raise SystemExit(f"release audit: source {labels[name]} target graph is invalid")
        if name in targets:
            raise SystemExit(f"release audit: source {labels[name]} target is ambiguous")
        product_name, product_type, product_path = products[name]
        if target.get("productName") != product_name or target.get("productType") != product_type:
            raise SystemExit(f"release audit: source {labels[name]} target product mapping is invalid")
        try:
            product = referenced_object(target["productReference"], f"release audit: source {labels[name]} target product mapping is invalid")
        except KeyError:
            raise SystemExit(f"release audit: source {labels[name]} target product mapping is invalid")
        if product.get("isa") != "PBXFileReference" or product.get("path") != product_path:
            raise SystemExit(f"release audit: source {labels[name]} target product mapping is invalid")
        targets[name] = target
if set(targets) != set(expected):
    raise SystemExit("release audit: relevant generated project target is missing")

for target_name, wanted in expected.items():
    error = f"release audit: source {labels[target_name]} CODE_SIGN_ENTITLEMENTS configuration is missing"
    for configuration in configurations(targets[target_name], error).values():
        if "baseConfigurationReference" in configuration:
            raise SystemExit(
                f"release audit: source {labels[target_name]} baseConfigurationReference is forbidden"
            )
        try:
            settings = dictionary(configuration["buildSettings"], error)
        except KeyError:
            raise SystemExit(error)
        actual = {
            key: value
            for key, value in settings.items()
            if key.startswith("CODE_SIGN_ENTITLEMENTS")
        }
        if actual != wanted:
            raise SystemExit(
                f"release audit: source {labels[target_name]} CODE_SIGN_ENTITLEMENTS does not match canonical paths"
            )
        info_actual = {
            key: value
            for key, value in settings.items()
            if key.startswith("INFOPLIST_FILE")
        }
        if info_actual != expected_info[target_name]:
            raise SystemExit(
                f"release audit: source {labels[target_name]} INFOPLIST_FILE does not match canonical path"
            )
PY
}

verify_source_product_cloud_entitlements() {
  verify_generated_entitlement_bindings
  "$PLUTIL" -convert json -o - "$MAIN_INFO_PLIST" \
    | jq -e '.UIBackgroundModes == ["remote-notification"]' >/dev/null \
    || fail "source main UIBackgroundModes must contain only remote-notification"

  jq -e '
    .targets.KnitNote.info.path == "KnitNote/Info.plist"
    and .targets.KnitNote.info.properties.UIBackgroundModes == ["remote-notification"]
  ' "$SPEC_JSON" >/dev/null \
    || fail "source main target UIBackgroundModes must contain only remote-notification"

  "$PLUTIL" -convert json -o - "$IOS_ENTITLEMENTS" \
    | jq -e '. == {
      "com.apple.security.application-groups": ["group.com.phillon.KnitNote"],
      "com.apple.developer.icloud-container-identifiers": ["$(KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER)"],
      "com.apple.developer.icloud-services": ["CloudKit"],
      "aps-environment": "development"
    }' >/dev/null \
    || fail "source iOS entitlements do not match the exact CloudKit, APS, and App Group contract"

  "$PLUTIL" -convert json -o - "$SHARE_ENTITLEMENTS" \
    | jq -e '. == {
      "com.apple.security.application-groups": ["group.com.phillon.KnitNote"]
    }' >/dev/null \
    || fail "source Share entitlements do not match the exact App Group-only contract"

  [[ -z "$(find KnitNoteWatch -type f -name '*.entitlements' -print -quit)" ]] \
    || fail "source Watch must not have an entitlement file"
  for plist in "$WATCH_INFO_PLIST" "$SHARE_INFO_PLIST"; do
    "$PLUTIL" -convert json -o - "$plist" \
      | jq -e '
        has("com.apple.developer.icloud-container-identifiers") == false
        and has("com.apple.developer.icloud-services") == false
        and has("com.apple.developer.icloud-container-environment") == false
        and has("aps-environment") == false
        and has("com.apple.developer.aps-environment") == false
        and ((.UIBackgroundModes // []) | index("remote-notification") == null)
      ' >/dev/null \
      || fail "$plist contains a forbidden CloudKit or remote-notification configuration"
  done

  jq -e '
    [.targets.KnitNoteWatch, .targets.KnitNoteShare]
    | tostring
    | test("CloudKit|icloud-container|aps-environment|remote-notification|KNITNOTE_ICLOUD_CONTAINER_IDENTIFIER")
    | not
  ' "$SPEC_JSON" >/dev/null \
    || fail "source Watch or Share target configuration contains CloudKit or remote-notification capability"
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
  python3 - "$profile_json" "$EXPECTED_TEAM" "$bundle_id" "$expected_group" "$label" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label provisioning profile is expired or is not App Store distribution for $EXPECTED_TEAM"; }
import plistlib
import datetime
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
team, bundle, group, label = sys.argv[2:]
entitlements = profile.get("Entitlements", {})
identifier_key = "com.apple.application-identifier" if label == "macOS" else "application-identifier"
alternate_identifier_key = "application-identifier" if label == "macOS" else "com.apple.application-identifier"
identifier = entitlements.get(identifier_key)
groups = entitlements.get("com.apple.security.application-groups", [])
expiration = profile.get("ExpirationDate")
if isinstance(expiration, datetime.datetime) and expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=datetime.timezone.utc)
valid = (
    profile.get("TeamIdentifier") == [team]
    and entitlements.get("get-task-allow", False) is False
    and identifier == f"{team}.{bundle}"
    and alternate_identifier_key not in entitlements
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
  python3 - "$profile_json" "$signed_json" "$EXPECTED_TEAM" "$bundle_id" "$expected_group" "$label" <<'PY' \
    || { rm -f "$cert_prefix"* "$profile_json" "$signed_json"; fail "$label signed entitlements do not match its provisioning profile"; }
import plistlib
from pathlib import Path
import sys

profile = plistlib.loads(Path(sys.argv[1]).read_bytes()).get("Entitlements", {})
signed = plistlib.loads(Path(sys.argv[2]).read_bytes())
team, bundle, group, label = sys.argv[3:]
signed_key = "com.apple.application-identifier" if label == "macOS" else "application-identifier"
alternate_signed_key = "application-identifier" if label == "macOS" else "com.apple.application-identifier"
expected_id = f"{team}.{bundle}"
expected_groups = [group] if group else []
valid = (
    profile.get(signed_key) == expected_id
    and alternate_signed_key not in profile
    and signed.get(signed_key) == expected_id
    and alternate_signed_key not in signed
    and signed.get("com.apple.developer.team-identifier") == team
    and signed.get("get-task-allow", False) is False
    and profile.get("com.apple.security.application-groups", []) == expected_groups
    and signed.get("com.apple.security.application-groups", []) == expected_groups
)
raise SystemExit(0 if valid else 1)
PY
  verify_signed_product_cloud_entitlements "$label" "$signed_json"
  rm -f "$cert_prefix"* "$profile_json" "$signed_json"
}

require_safe_directory() {
  local label="$1" root="$2" candidate="$3"
  python3 - "$label" "$root" "$candidate" <<'PY'
from pathlib import Path
import stat
import sys

label, root_arg, candidate_arg = sys.argv[1:]
root = Path(root_arg)
candidate = Path(candidate_arg)
try:
    lexical_root = root.absolute()
    lexical_candidate = candidate.absolute()
    lexical_relative = lexical_candidate.relative_to(lexical_root)
except ValueError:
    raise SystemExit(f"release audit: {label} is missing or escapes its extraction root")
current = lexical_root
for part in lexical_relative.parts:
    current = current / part
    try:
        mode = current.lstat().st_mode
    except FileNotFoundError:
        raise SystemExit(f"release audit: {label} is missing or escapes its extraction root")
    if stat.S_ISLNK(mode):
        raise SystemExit(f"release audit: {label} contains an unsafe symlink")
try:
    root_resolved = root.resolve(strict=True)
    candidate_resolved = candidate.resolve(strict=True)
    candidate_resolved.relative_to(root_resolved)
except (FileNotFoundError, ValueError):
    raise SystemExit(f"release audit: {label} is missing or escapes its extraction root")
if not candidate.is_dir() or candidate.is_symlink():
    raise SystemExit(f"release audit: {label} is not a real directory")
print(lexical_candidate)
PY
}

find_unique_mac_app() {
  local root="$1"
  python3 - "$root" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
try:
    resolved_root = root.resolve(strict=True)
except FileNotFoundError:
    raise SystemExit("release audit: exported macOS app root is missing")
candidates = []
for directory, names, _ in os.walk(resolved_root, followlinks=False):
    base = Path(directory)
    for name in names:
        path = base / name
        if name == "KnitNote.app" and path.parent.name == "Payload":
            if path.is_symlink():
                raise SystemExit("release audit: exported macOS app root contains an unsafe symlink")
            candidates.append(path)
if len(candidates) != 1:
    raise SystemExit(
        f"release audit: expected exactly one exported macOS app root, found {len(candidates)}"
    )
candidate = candidates[0].resolve(strict=True)
try:
    candidate.relative_to(resolved_root)
except ValueError:
    raise SystemExit("release audit: exported macOS app root escapes its extraction root")
print(candidate)
PY
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

verify_expected_app_store_update_network_surface() {
  python3 - "$NETWORK_SCAN_ROOT" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

root = Path(sys.argv[1])
sentinel_relative = Path(
    "Sources/KnitNoteCore/App/AppStoreUpdateLiveNetworkContract.swift"
)
factory_relative = Path("KnitNote/App/AppUpdateReminderLiveFactory.swift")
expected_sentinel_sha256 = "e98d217256ad5a1b15ee64d61f44b75c9f6c981b50088ca2fe7f199382ed21c4"
expected_factory_sha256 = "dcae917c3d5f301e6d79ea3901b4c8a55f37277a55d76efc8d0bc656ad255bb7"
risk = re.compile(
    r"URLSession|URLRequest\s*\(|\bloader\s*\(|NWConnection|"
    r"AppStoreUpdateLookup\s*\(\s*fetcher\s*:|"
    r"\btestLookup\b|"
    r"Firebase|Analytics|Telemetry|tracking|https?://"
)


def fail(message):
    raise SystemExit(f"release audit: {message}")


sentinel = root / sentinel_relative
if not sentinel.is_file() or sentinel.is_symlink():
    fail(f"required live-network sentinel is missing or unsafe: {sentinel_relative}")
try:
    sentinel_bytes = sentinel.read_bytes()
except OSError:
    fail(f"required live-network sentinel is unreadable: {sentinel_relative}")
actual_sentinel_sha256 = hashlib.sha256(sentinel_bytes).hexdigest()
if actual_sentinel_sha256 != expected_sentinel_sha256:
    fail(
        "App Store update live-network sentinel is not canonical; "
        f"found sha256 {actual_sentinel_sha256}"
    )

factory = root / factory_relative
if not factory.is_file() or factory.is_symlink():
    fail(f"required production update-reminder factory is missing or unsafe: {factory_relative}")
try:
    factory_bytes = factory.read_bytes()
except OSError:
    fail(f"required production update-reminder factory is unreadable: {factory_relative}")
actual_factory_sha256 = hashlib.sha256(factory_bytes).hexdigest()
if actual_factory_sha256 != expected_factory_sha256:
    fail(
        "production update-reminder factory is not canonical; "
        f"found sha256 {actual_factory_sha256}"
    )

scan_roots = [
    root / "KnitNote",
    root / "KnitNoteWatch",
    root / "KnitNoteShare",
    root / "Sources/KnitNoteCore",
]
candidates = []
for scan_root in scan_roots:
    if scan_root.exists():
        for path in scan_root.rglob("*"):
            if path.is_symlink():
                fail(f"network scan source is an unsafe symlink: {path.relative_to(root)}")
            if path.is_file():
                candidates.append(path)
for relative in [Path("Package.swift"), Path("project.yml")]:
    path = root / relative
    if path.is_file():
        candidates.append(path)

for path in sorted(set(candidates)):
    relative = path.relative_to(root)
    if path.suffix not in {".swift", ".yml"} and path.name != "Package.swift":
        continue
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        fail(f"network scan source is unreadable: {relative}")
    if relative == sentinel_relative:
        continue
    match = risk.search(source)
    if match:
        line = source.count("\n", 0, match.start()) + 1
        fail(f"unexpected network, analytics, or tracking source: {relative}:{line}")
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
    || fail "$label CFBundleLocalizations do not match the thirteen release locales"
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
  PROJECT_ARCHIVE_SCHEMA_SOURCE="${KNITNOTE_PROJECT_ARCHIVE_SCHEMA_SOURCE:-$PROJECT_ARCHIVE_SCHEMA_SOURCE}"
  PROJECT_SCAN_ROOT="${KNITNOTE_PROJECT_SCAN_ROOT:-$PROJECT_SCAN_ROOT}"
  NETWORK_SCAN_ROOT="${KNITNOTE_NETWORK_SCAN_ROOT:-$NETWORK_SCAN_ROOT}"
  GIT="${KNITNOTE_GIT:-$GIT}"
  XCODEGEN="${KNITNOTE_XCODEGEN:-$XCODEGEN}"
  CODESIGN="${KNITNOTE_CODESIGN:-$CODESIGN}"
  SECURITY="${KNITNOTE_SECURITY:-$SECURITY}"
  SWIFT="${KNITNOTE_SWIFT:-$SWIFT}"
  DITTO="${KNITNOTE_DITTO:-$DITTO}"
  PKGUTIL="${KNITNOTE_PKGUTIL:-$PKGUTIL}"
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
EXTRACTION_ROOT=""
cleanup_release_audit() {
  rm -f "$SPEC_JSON"
  if [[ -n "$EXTRACTION_ROOT" ]]; then
    rm -rf "$EXTRACTION_ROOT"
  fi
}
trap cleanup_release_audit EXIT
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

EXPECTED_VERSION="1.6.1"
EXPECTED_BUILD="13"
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

verify_project_archive_schema
/usr/bin/grep -q 'static let currentFormatVersion = 2' \
  Sources/KnitNoteCore/Backup/KnitNoteBackupManifest.swift \
  || fail "backup manifest format is not 2"

verify_source_product_cloud_entitlements
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
    || fail "$catalog has an incomplete thirteen-locale variation"
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
    || fail "$catalog localization key domain does not match the thirteen release locales"
done

python3 AppStore/Verification/metadata_check.py AppStore/Metadata
python3 AppStore/Verification/commercial_release_check.py \
  --offline \
  --configuration \
  "AppStore/CommercialConfiguration.json"
"$GIT" diff --check

verify_expected_app_store_update_network_surface

if [[ -n "$ARCHIVES" ]]; then
  [[ "$("$GIT" -C "$ROOT" rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] \
    || fail "expected source revision does not match repository HEAD"
  [[ -z "$("$GIT" -C "$ROOT" status --porcelain --untracked-files=normal)" ]] \
    || fail "source worktree is dirty"
  [[ "$PROVENANCE" == "$ARCHIVES/provenance.json" && -f "$PROVENANCE" && ! -L "$PROVENANCE" ]] \
    || fail "provenance must be the canonical candidate-root provenance.json"
  [[ ! -e "$ARCHIVES/.TEST_FIXTURE_NOT_FOR_RELEASE" ]] \
    || fail "candidate contains the test fixture sentinel"
  python3 AppStore/Verification/release_archive_manifest.py verify \
    --archives "$ARCHIVES" --source-commit "$EXPECTED_COMMIT" --input "$PROVENANCE" \
    || fail "provenance sourceCommit or deterministic archive inventory mismatch"
  verify_distribution_inventory "$ARCHIVES"
  IPA="$ARCHIVES/Distribution/iOS/KnitNote.ipa"
  PKG="$ARCHIVES/Distribution/macOS/KnitNote.pkg"
  [[ -f "$IPA" && ! -L "$IPA" ]] || fail "exported iOS IPA is missing or unsafe"
  [[ -f "$PKG" && ! -L "$PKG" ]] || fail "exported macOS pkg is missing or unsafe"
  verify_mac_package_signature "$PKG"
  EXTRACTION_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/knitnote-release-products.XXXXXX")"
  IOS_EXTRACT="$EXTRACTION_ROOT/ios"
  MAC_EXTRACT="$EXTRACTION_ROOT/mac"
  mkdir "$IOS_EXTRACT"
  [[ ! -e "$MAC_EXTRACT" ]] || fail "macOS pkg expansion destination already exists"
  "$DITTO" -x -k "$IPA" "$IOS_EXTRACT" || fail "iOS IPA extraction failed"
  "$PKGUTIL" --expand-full "$PKG" "$MAC_EXTRACT" || fail "macOS pkg expansion failed"
  IOS="$(require_safe_directory "exported iOS app root" "$IOS_EXTRACT" "$IOS_EXTRACT/Payload/KnitNote.app")" \
    || fail "exported iOS app root is missing or unsafe"
  MAC="$(find_unique_mac_app "$MAC_EXTRACT")" \
    || fail "expected exactly one exported macOS app root"
  unreadable_file="$(find "$MAC" -type f ! -perm -0004 -print -quit)"
  [[ -z "$unreadable_file" ]] \
    || fail "macOS package app contains a file that is not world-readable: $unreadable_file"
  unsearchable_directory="$(find "$MAC" -type d ! -perm -0001 -print -quit)"
  [[ -z "$unsearchable_directory" ]] \
    || fail "macOS package app contains a directory that is not world-searchable: $unsearchable_directory"
  WATCH="$IOS/Watch/KnitNoteWatch.app"
  SHARE="$IOS/PlugIns/KnitNoteShare.appex"
  WATCH="$(require_safe_directory "exported Watch app root" "$IOS_EXTRACT" "$WATCH")" \
    || fail "exported Watch app root is missing or unsafe"
  SHARE="$(require_safe_directory "exported Share extension root" "$IOS_EXTRACT" "$SHARE")" \
    || fail "exported Share extension root is missing or unsafe"
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
