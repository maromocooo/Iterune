#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash changes before exporting the reviewed HEAD." >&2
  exit 1
fi
EXPORT_DIR=$(mktemp -d)
trap 'rm -rf "$EXPORT_DIR"' EXIT
mkdir -p dist
git archive HEAD | tar -x -C "$EXPORT_DIR"
python3 scripts/check-privacy.py --directory "$EXPORT_DIR"
git archive --format=zip --prefix=Attune/ -o dist/Attune-source.zip HEAD
echo "Created dist/Attune-source.zip (no Git history)"
