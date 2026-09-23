#!/bin/bash
# Fresh fixture-only build. Never uses open(1), PATH app lookup, or existing app bundles.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/gui-smoke.py "$@"
