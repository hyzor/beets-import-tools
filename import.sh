#!/usr/bin/env bash
# import.sh — Run preprocessor then import with beets (MusicBrainz autotagging).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source ./mb-import-lib.sh

# Does the album folder still contain audio files? With `import.move: yes`
# beets moves files into the library, leaving an empty (or cover-art-only)
# shell behind after a successful import. Those shells must not re-enter the
# import loop on a re-run — beets would otherwise prompt about them again.
_has_audio() {
  [[ -n "$(find "$1" -maxdepth 1 -type f \( \
    -iname '*.flac' -o -iname '*.wav' -o -iname '*.ape' -o -iname '*.wv' \
    -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.opus' \
    -o -iname '*.aac' -o -iname '*.dsf' -o -iname '*.dff' \
  \) -print -quit)" ]]
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Step 1: Preprocess                                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
./preprocess.sh

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Step 2: Import with beets                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"

shopt -s nullglob
folders=(albums/*/)
shopt -u nullglob

if [[ ${#folders[@]} -eq 0 ]]; then
  echo "No album folders in albums/ — nothing to import."
  echo "Drop album folders into albums/ and re-run ./import.sh."
  exit 0
fi

# Import one album folder at a time (beet_import_with_mb_retry adds the
# MusicBrainz rate-limit backoff; see mb-import-lib.sh). Per-folder isolation
# means a throttled or failed album doesn't abort the rest of the batch, and
# a retry never re-touches folders that already imported.
processed=0
failed=0
shells=0
for folder in "${folders[@]}"; do
  if ! _has_audio "$folder"; then
    shells=$((shells + 1))
    echo ""
    echo "  ↪  $(basename "$folder") — no audio files (already imported?); skipped."
    continue
  fi

  processed=$((processed + 1))
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  $(basename "$folder")"
  echo "╚══════════════════════════════════════════════╝"

  if ! beet_import_with_mb_retry "$folder"; then
    failed=$((failed + 1))
  fi
done

if [[ $failed -gt 0 ]]; then
  echo ""
  echo "⚠  $failed of $processed album folder(s) failed to import (see mb-import.log)." >&2
  echo "    Their files are still in albums/ — re-run ./import.sh later;" >&2
  echo "    already-imported folders are skipped automatically." >&2
  exit 1
fi

echo ""
if [[ $shells -gt 0 ]]; then
  echo "✅  $processed album folder(s) processed. $shells empty leftover folder(s) skipped."
  echo "    Run ./clean.sh to purge the leftover folders from albums/."
else
  echo "✅  $processed album folder(s) processed. Run ./clean.sh to clean up albums/."
fi
