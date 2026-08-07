#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
GIT=/usr/bin/git
for variable in ${!KNITNOTE_@}; do
  echo "release candidate creation rejects override $variable" >&2
  exit 1
done
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
export PATH
OUTPUT="${1:-}"
[[ -n "$OUTPUT" && $# -eq 1 ]] || { echo "usage: $0 OUTPUT_DIRECTORY" >&2; exit 2; }
[[ ! -e "$OUTPUT" ]] || { echo "candidate output already exists: $OUTPUT" >&2; exit 1; }
[[ "$($GIT -C "$ROOT" rev-parse --show-toplevel)" == "$ROOT" ]] || { echo "repository root mismatch" >&2; exit 1; }
COMMIT="$($GIT -C "$ROOT" rev-parse HEAD)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "HEAD is not a full commit identifier" >&2; exit 1; }
[[ -z "$($GIT -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || { echo "candidate worktree is dirty" >&2; exit 1; }

PARENT="$(cd "$(dirname "$OUTPUT")" && pwd -P)"
FINAL="$PARENT/$(basename "$OUTPUT")"
case "$FINAL/" in
  "$ROOT/"*) echo "candidate output must be outside the source checkout" >&2; exit 1 ;;
esac
STAGING="$(mktemp -d "$PARENT/.KnitNote-1.4.1.staging.XXXXXX")"
WORKTREE="$STAGING/source"
ARTIFACTS="$STAGING/artifacts"
cleanup() {
  "$GIT" -C "$ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$STAGING"
}
trap cleanup EXIT

"$GIT" -C "$ROOT" worktree add --detach "$WORKTREE" "$COMMIT"
mkdir "$ARTIFACTS"
(cd "$WORKTREE" && AppStore/Verification/release_audit.sh --static-only)
(cd "$WORKTREE" && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARTIFACTS/KnitNote-iOS-Privacy.xcarchive" \
  KNITNOTE_SOURCE_REVISION="$COMMIT" archive)
(cd "$WORKTREE" && xcodebuild -project KnitNote.xcodeproj -scheme KnitNote -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARTIFACTS/KnitNote-macOS-Privacy.xcarchive" \
  KNITNOTE_SOURCE_REVISION="$COMMIT" archive)
python3 "$WORKTREE/AppStore/Verification/release_archive_manifest.py" create \
  --archives "$ARTIFACTS" --source-commit "$COMMIT" --output "$ARTIFACTS/provenance.json"
(cd "$WORKTREE" && AppStore/Verification/release_audit.sh --archives "$ARTIFACTS" \
  --expected-commit "$COMMIT" --provenance "$ARTIFACTS/provenance.json")
[[ "$($GIT -C "$ROOT" rev-parse HEAD)" == "$COMMIT" ]] || { echo "source HEAD changed during archive creation" >&2; exit 1; }
[[ -z "$($GIT -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || { echo "source worktree changed during archive creation" >&2; exit 1; }
"$GIT" -C "$ROOT" worktree remove "$WORKTREE"
mv "$ARTIFACTS" "$FINAL"
rm -rf "$STAGING"
trap - EXIT
echo "Release candidate created at $FINAL for $COMMIT"
