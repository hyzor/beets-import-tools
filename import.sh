#!/usr/bin/env bash
# import.sh — Run preprocessor then import with beets (MusicBrainz autotagging).
set -euo pipefail

cd "$(dirname "$0")"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Step 1: Preprocess                                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
./preprocess.sh

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Step 2: Import with beets                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
beet import .
