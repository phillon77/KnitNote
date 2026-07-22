#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

ARCHIVES=""
if [[ "${1:-}" == "--archives" ]]; then
  ARCHIVES="${2:?missing archive directory}"
elif [[ $# -ne 0 ]]; then
  echo "usage: release_audit.sh [--archives DIR]" >&2
  exit 2
fi

swift test --disable-sandbox
xcodegen dump --type parsed-yaml >/dev/null
plutil -lint KnitNote/Info.plist KnitNoteWatch/Info.plist \
  KnitNote/PrivacyInfo.xcprivacy KnitNoteWatch/PrivacyInfo.xcprivacy >/dev/null
python3 AppStore/Verification/metadata_check.py AppStore/Metadata
git diff --check

if rg -n "URLSession|NWConnection|Firebase|Analytics|Telemetry|tracking|https?://" \
  KnitNote KnitNoteWatch Sources/KnitNoteCore Package.swift project.yml \
  --glob '*.swift' --glob '*.yml' --glob 'Package.swift'; then
  echo "release audit: inspect unexpected network, analytics, or tracking source above" >&2
  exit 1
fi

if [[ -n "$ARCHIVES" ]]; then
  IOS="$ARCHIVES/KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
  MAC="$ARCHIVES/KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
  WATCH="$IOS/Watch/KnitNoteWatch.app"
  for path in "$IOS" "$WATCH" "$MAC"; do
    [[ -d "$path" ]] || { echo "release audit: missing app bundle: $path" >&2; exit 1; }
  done
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$IOS/Info.plist")" == "com.phillon.KnitNote" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WATCH/Info.plist")" == "com.phillon.KnitNote.watch" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :WKCompanionAppBundleIdentifier' "$WATCH/Info.plist")" == "com.phillon.KnitNote" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MAC/Contents/Info.plist")" == "com.phillon.KnitNote" ]]
  for plist in "$IOS/Info.plist" "$WATCH/Info.plist" "$MAC/Contents/Info.plist"; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "1.0.0" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "2" ]]
  done
  plutil -lint "$IOS/PrivacyInfo.xcprivacy" "$WATCH/PrivacyInfo.xcprivacy" \
    "$MAC/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null
  codesign --verify --deep --strict "$IOS"
  codesign --verify --deep --strict "$MAC"
fi

echo "RELEASE AUDIT: PASS"
