#!/usr/bin/env bash
# embed-lrc.sh — Embed existing .lrc sidecar lyrics into audio file tags
#
# Reads .lrc files alongside your audio files and writes the lyrics
# (timestamps preserved) into the file's embedded metadata tags,
# then updates the beets database.
#
# Usage:
#   ./embed-lrc.sh                    # scan and embed all .lrc files
#   ./embed-lrc.sh --dry-run          # preview only
#   ./embed-lrc.sh /path/to/album/    # specific folder only

set -euo pipefail

DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
  esac
done

LIBRARY="/media/wdblue/share/Music"
TARGET="${1:-$LIBRARY}"
FOUND=0
EMBEDDED=0
SKIPPED=0
ERRORS=0

# Write lyrics tag using metaflac (FLAC) or ffmpeg (others)
write_lyrics_tag() {
  local audio="$1"
  local lyrics_text="$2"

  case "$audio" in
    *.flac)
      # Remove any existing LYRICS tag first, then set new one
      metaflac --remove-tag=LYRICS "$audio" 2>/dev/null || true
      metaflac --set-tag=LYRICS="$lyrics_text" "$audio" 2>/dev/null
      return $?
      ;;
    *.m4a|*.mp4)
      # Use ffmpeg with temp file (mutagen path issues on this system)
      local tmp
      tmp="$(mktemp /tmp/lyrics_XXXXXX.m4a)"
      ffmpeg -y -i "$audio" -metadata lyrics="$lyrics_text" -c copy "$tmp" 2>/dev/null \
        && mv "$tmp" "$audio"
      return $?
      ;;
    *.mp3)
      local tmp
      tmp="$(mktemp /tmp/lyrics_XXXXXX.mp3)"
      ffmpeg -y -i "$audio" -metadata lyrics="$lyrics_text" -c copy "$tmp" 2>/dev/null \
        && mv "$tmp" "$audio"
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

# Check if lyrics already exist in file
has_lyrics_tag() {
  case "$1" in
    *.flac)
      metaflac --show-tag=LYRICS "$1" &>/dev/null
      return $?
      ;;
    *)
      return 1  # Don't know how to check, assume no
      ;;
  esac
}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  .lrc Lyrics Embedder                                        ║"
echo "║  Scanning: $TARGET"
echo "╚══════════════════════════════════════════════════════════════╝"

if $DRY_RUN; then
  echo "  DRY RUN MODE — no changes will be made"
  echo ""
fi

# Find all .lrc files
while IFS= read -r -d '' lrc_file; do
  FOUND=$((FOUND + 1))

  # Derive audio file path: strip .lrc extension, try common audio extensions
  base="${lrc_file%.lrc}"
  audio_file=""

  for ext in flac m4a mp3 mp4 ogg opus wav; do
    if [ -f "$base.$ext" ]; then
      audio_file="$base.$ext"
      break
    fi
  done

  if [ -z "$audio_file" ]; then
    echo "  ⚠  No matching audio file for: $(basename "$lrc_file")"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check if lyrics already embedded (FLAC only for now)
  if ! $FORCE && has_lyrics_tag "$audio_file"; then
    echo "  ✓  $(basename "$audio_file") — already has lyrics, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if $FORCE && has_lyrics_tag "$audio_file"; then
    echo "  🔄  $(basename "$audio_file") — replacing existing lyrics with .lrc content"
  fi

  # Read .lrc content
  lyrics_content="$(cat "$lrc_file")"

  if [ -z "$lyrics_content" ]; then
    echo "  ⚠  Empty .lrc file: $(basename "$lrc_file")"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if $DRY_RUN; then
    echo "  📝  Would embed: $(basename "$lrc_file") → $(basename "$audio_file")"
    EMBEDDED=$((EMBEDDED + 1))
    continue
  fi

  # Write the tag
  if write_lyrics_tag "$audio_file" "$lyrics_content"; then
    echo "  📝  Embedded: $(basename "$lrc_file") → $(basename "$audio_file")"
    EMBEDDED=$((EMBEDDED + 1))
  else
    echo "  ✗  Failed: $(basename "$lrc_file") → $(basename "$audio_file")"
    ERRORS=$((ERRORS + 1))
  fi

done < <(find "$TARGET" -name '*.lrc' -type f -print0)

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Summary"
echo "═══════════════════════════════════════════════════════════════"
echo "  .lrc files found:  $FOUND"
echo "  Embedded:          $EMBEDDED"
echo "  Skipped:           $SKIPPED"
echo "  Errors:            $ERRORS"

if ! $DRY_RUN && [[ $EMBEDDED -gt 0 ]]; then
  echo ""
  echo "  Now syncing beets database from file tags..."
  echo "  Running: beet update"
  beet update 2>&1 | tail -5
  echo ""
  echo "  ✅  Done — beets database updated with new lyrics tags."
  echo ""
  echo "  Next: set synced: true + keep_synced: true in beets config"
  echo "  Then run: beet lyrics"
fi
