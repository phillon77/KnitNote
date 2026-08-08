#!/bin/bash
set -euo pipefail

probe_screenshot_python() {
  [[ "$("$1" -c 'from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps; from PIL import __version__; print(__version__)' 2>/dev/null)" == "11.3.0" ]]
}

select_screenshot_python() {
  local candidate
  for candidate in "$@"; do
    [[ -x "$candidate" ]] || continue
    if probe_screenshot_python "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

screenshot_python_candidates() {
  printf '%s\n' \
    /opt/homebrew/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.9/bin/python3 \
    /usr/local/bin/python3 \
    /usr/bin/python3
}

main() {
  local candidates=()
  while IFS= read -r candidate; do candidates+=("$candidate"); done < <(screenshot_python_candidates)
  local selected
  selected="$(select_screenshot_python "${candidates[@]}")" || {
    echo "KnitNote screenshot tools require a local Python 3 runtime with Pillow; see AppStore/Screenshots/requirements.txt" >&2
    exit 69
  }
  exec "$selected" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
