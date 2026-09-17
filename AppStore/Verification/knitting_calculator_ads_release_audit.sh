#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec /usr/bin/python3 "$ROOT/AppStore/Verification/knitting_calculator_ads_release_audit.py" "$@"
