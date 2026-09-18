#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
GIT=/usr/bin/git
SECURITY=/usr/bin/security
XCODEBUILD=/usr/bin/xcodebuild
PYTHON=python3
MKTEMP=mktemp
EXPECTED_TEAM=9CFPAUL5N5
TEST_ONLY=0
if [[ "${1:-}" == "--test-only" ]]; then
  TEST_ONLY=1
  shift
fi
if [[ "$TEST_ONLY" == 1 ]]; then
  ROOT="${KNITNOTE_CREATOR_ROOT:-$ROOT}"
  GIT="${KNITNOTE_CREATOR_GIT:-$GIT}"
  SECURITY="${KNITNOTE_CREATOR_SECURITY:-$SECURITY}"
  XCODEBUILD="${KNITNOTE_CREATOR_XCODEBUILD:-$XCODEBUILD}"
  PYTHON="${KNITNOTE_CREATOR_PYTHON:-$PYTHON}"
  MKTEMP="${KNITNOTE_CREATOR_MKTEMP:-$MKTEMP}"
else
  for variable in ${!KNITNOTE_@}; do
    echo "release candidate creation rejects override $variable" >&2
    exit 1
  done
fi
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH
OUTPUT="${1:-}"
[[ -n "$OUTPUT" && $# -eq 1 ]] || { echo "usage: $0 [--test-only] OUTPUT_DIRECTORY" >&2; exit 2; }
[[ ! -e "$OUTPUT" ]] || { echo "candidate output already exists: $OUTPUT" >&2; exit 1; }
[[ "$($GIT -C "$ROOT" rev-parse --show-toplevel)" == "$ROOT" ]] || { echo "repository root mismatch" >&2; exit 1; }
COMMIT="$($GIT -C "$ROOT" rev-parse HEAD)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "HEAD is not a full commit identifier" >&2; exit 1; }
[[ -z "$($GIT -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || { echo "candidate worktree is dirty" >&2; exit 1; }
if ! "$SECURITY" find-identity -v -p codesigning | /usr/bin/grep -Eq "Apple Distribution:.*\($EXPECTED_TEAM\)"; then
  echo "missing local Apple Distribution signing identity for team $EXPECTED_TEAM" >&2
  exit 1
fi

PARENT="$(cd "$(dirname "$OUTPUT")" && pwd -P)"
FINAL="$PARENT/$(basename "$OUTPUT")"
case "$FINAL/" in
  "$ROOT/"*) echo "candidate output must be outside the source checkout" >&2; exit 1 ;;
esac
ARTIFACTS=""
WORKROOT=""
WORKTREE=""
PUBLISHER=""
cleanup() {
  [[ -z "$WORKTREE" ]] || "$GIT" -C "$ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  [[ -z "$WORKROOT" ]] || rm -rf "$WORKROOT"
  [[ -z "$ARTIFACTS" ]] || rm -rf "$ARTIFACTS"
}
trap cleanup EXIT
ARTIFACTS="$("$MKTEMP" -d "$PARENT/.KnitNote-1.7.1.staging.XXXXXX")"
WORKROOT="$("$MKTEMP" -d "$PARENT/.KnitNote-1.7.1.worktree.XXXXXX")"
WORKTREE="$WORKROOT/source"
PUBLISHER="$WORKROOT/atomic_publish.py"

"$GIT" -C "$ROOT" worktree add --detach "$WORKTREE" "$COMMIT"
umask 022
(cd "$WORKTREE" && AppStore/Verification/release_audit.sh --static-only)
(cd "$WORKTREE" && "$XCODEBUILD" -project KnitNote.xcodeproj -scheme KnitNote -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARTIFACTS/KnitNote-iOS-Privacy.xcarchive" \
  KNITNOTE_SOURCE_REVISION="$COMMIT" archive)
(cd "$WORKTREE" && "$XCODEBUILD" -project KnitNote.xcodeproj -scheme KnitNote -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARTIFACTS/KnitNote-macOS-Privacy.xcarchive" \
  KNITNOTE_SOURCE_REVISION="$COMMIT" archive)
mkdir "$ARTIFACTS/Distribution"
(cd "$WORKTREE" && "$XCODEBUILD" -exportArchive \
  -archivePath "$ARTIFACTS/KnitNote-iOS-Privacy.xcarchive" \
  -exportPath "$ARTIFACTS/Distribution/iOS" \
  -exportOptionsPlist "$WORKTREE/AppStore/Verification/ExportOptions-AppStore.plist")
(cd "$WORKTREE" && "$XCODEBUILD" -exportArchive \
  -archivePath "$ARTIFACTS/KnitNote-macOS-Privacy.xcarchive" \
  -exportPath "$ARTIFACTS/Distribution/macOS" \
  -exportOptionsPlist "$WORKTREE/AppStore/Verification/ExportOptions-AppStore.plist")
rm -f "$ARTIFACTS/Distribution/iOS/Packaging.log" "$ARTIFACTS/Distribution/macOS/Packaging.log"
if find "$ARTIFACTS/Distribution" -type f -name Packaging.log -print -quit | /usr/bin/grep -q .; then
  echo "unexpected credential-bearing Packaging.log remains after export" >&2
  exit 1
fi
if [[ "$TEST_ONLY" == 1 ]]; then
  : > "$ARTIFACTS/.TEST_FIXTURE_NOT_FOR_RELEASE"
fi
"$PYTHON" "$WORKTREE/AppStore/Verification/release_archive_manifest.py" create \
  --archives "$ARTIFACTS" --source-commit "$COMMIT" --output "$ARTIFACTS/provenance.json"
(cd "$WORKTREE" && AppStore/Verification/release_audit.sh --archives "$ARTIFACTS" \
  --expected-commit "$COMMIT" --provenance "$ARTIFACTS/provenance.json")
[[ "$($GIT -C "$ROOT" rev-parse HEAD)" == "$COMMIT" ]] || { echo "source HEAD changed during archive creation" >&2; exit 1; }
[[ -z "$($GIT -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || { echo "source worktree changed during archive creation" >&2; exit 1; }
if [[ "$TEST_ONLY" == 1 && -n "${KNITNOTE_CREATOR_TEST_BEFORE_PUBLISH:-}" ]]; then
  "$KNITNOTE_CREATOR_TEST_BEFORE_PUBLISH" "$FINAL"
fi
cp "$WORKTREE/AppStore/Verification/atomic_publish.py" "$PUBLISHER"
chmod 700 "$PUBLISHER"
"$GIT" -C "$ROOT" worktree remove "$WORKTREE"
chmod 700 "$ARTIFACTS"
if [[ "$TEST_ONLY" == 1 ]]; then
  SUCCESS_MESSAGE="TEST ONLY: release candidate fixture created at $FINAL for $COMMIT"
else
  SUCCESS_MESSAGE="Release candidate created at $FINAL for $COMMIT"
fi
"$PYTHON" "$PUBLISHER" --cleanup-dir "$WORKROOT" "$ARTIFACTS" "$FINAL"
trap - EXIT || :
printf '%s\n' "$SUCCESS_MESSAGE" || :
