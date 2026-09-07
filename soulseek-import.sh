#!/usr/bin/env bash
# soulseek-import.sh — Import albums from the slskd downloads folder into the
# beets library using HARDLINKS, keeping the source files in place so they
# keep seeding on the Soulseek network.
#
# Usage:
#   ./soulseek-import.sh             # import all album folders in downloads/
#   ./soulseek-import.sh "Album Dir" # import one folder
#   ./soulseek-import.sh --force     # bypass the quality guard
#
# Notes:
#   - Uses `beet import -L` (hardlink): ~zero extra disk usage — the library
#     and the downloads folder point at the same files (same filesystem).
#   - Sources are NEVER removed: the downloads folder stays shared on Soulseek.
#   - Quality guard (quality-guard.sh): skips any album containing lossy files
#     (MP3/AAC/...) or lossless-looking files transcoded from a lossy source.
#     Sources are kept — skipped albums are just left in downloads/.
#   - Interactive: you pick the MusicBrainz match per album (like import.sh).
#   - MusicBrainz rate limiting (HTTP 503/429) is handled automatically:
#     mb-import-lib.sh waits out the rate window and retries the album.
#   - Preprocess (mislabeled FLAC fix) is NOT run — use import.sh + albums/
#     staging if you need that for a specific album.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/quality-guard.sh"
source "$SCRIPT_DIR/mb-import-lib.sh"

DOWNLOADS="/media/wdblue/share/soulseek/downloads"
LOGFILE="/media/wdblue/share/import/soulseek-import.log"
mb_logfile="$LOGFILE"

FORCE=false
case "${1:-}" in
  --force) FORCE=true ;;
esac

cd "$DOWNLOADS"

import_album() {
  local dir="$1"
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  $(basename "$dir")"
  echo "╚══════════════════════════════════════════════════╝"

  if [[ "$FORCE" != true ]] && ! check_album_quality "$dir"; then
    echo "  ⛔  Skipped by quality guard (files stay in $DOWNLOADS)."
    echo "      Re-run with --force to import anyway."
    return
  fi

  # Rate-limit-aware import (retries with backoff on MusicBrainz 503/429).
  beet_import_with_mb_retry "$dir" -L || true
}

if [[ $# -gt 0 ]]; then
  import_album "$DOWNLOADS/$1"
else
  shopt -s nullglob
  folders=("$DOWNLOADS"/*/)
  shopt -u nullglob
  if [[ ${#folders[@]} -eq 0 ]]; then
    echo "No album folders in $DOWNLOADS — nothing to import."
    exit 0
  fi
  for folder in "${folders[@]}"; do
    import_album "$folder"
  done
fi

echo ""
echo "✅ Done. Source files kept in $DOWNLOADS for Soulseek seeding."
