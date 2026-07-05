#!/usr/bin/env bash
# clean.sh — Remove processed album folders after a successful import.
set -euo pipefail

cd "$(dirname "$0")"

if [ -d albums ]; then
  echo "  Cleaning albums/..."
  rm -rf albums/*/
  # Remove empty folders too (leftover shell artifacts)
  find albums/ -mindepth 1 -type d -empty -delete 2>/dev/null || true
  # If albums/ itself is now empty, keep the directory
  echo "  ✅  Done"
else
  echo "  No albums/ directory found."
fi
