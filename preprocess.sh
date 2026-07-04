#!/usr/bin/env bash
# preprocess.sh — Prepare album folders for beets import
#
# Fixes common issues:
#   1. Cleans folder names  (strips [quality] [FLAC] [16B-44.1kHz] etc.)
#   2. Validates audio files are actually what their extension claims
#   3. Re-wraps mislabeled MP4-with-FLAC files into proper FLAC
#   4. Tags files from folder name (Artist - Album) and filenames (NN. Title)
#
# Usage:  cd /media/wdblue/share/import && ./preprocess.sh
#         ./preprocess.sh              # process all folders
#         ./preprocess.sh --dry-run    # preview only, no changes
#         ./preprocess.sh "Folder Name"  # process specific folder only

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  shift
fi

IMPORT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_FIXED=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0

# ─── Color helpers ────────────────────────────────────────────────
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red()    { echo -e "\033[31m$1\033[0m"; }
blue()   { echo -e "\033[34m$1\033[0m"; }

# ─── Clean folder name: "Artist - Album [tags...]" → "Artist - Album" ──
clean_folder_name() {
  local dirbase
  dirbase="$(basename "$1")"
  # Strip trailing [...][...] quality tags
  local cleaned
  cleaned="$(echo "$dirbase" | sed -E 's/\s*\[[^]]*\](\.?)$//g' | sed -E 's/[[:space:]]+$//')"
  if [[ "$cleaned" != "$dirbase" ]]; then
    echo "$(dirname "$1")/$cleaned"
  else
    echo "$1"
  fi
}

# ─── Parse artist & album from folder name "Artist - Album" ───────
parse_artist_album() {
  local clean
  clean="$(basename "$1" | sed -E 's/\s*\[[^]]*\]//g' | sed -E 's/[[:space:]]+$//')"
  if [[ "$clean" =~ ^(.+)\ -\ (.+)$ ]]; then
    ARTIST="${BASH_REMATCH[1]}"
    ALBUM="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# ─── Count audio files in a folder ────────────────────────────────
count_audio_files() {
  local count=0
  for ext in flac m4a mp3 ogg opus wav aiff wma; do
    shopt -s nullglob
    local files=("$1"/*."$ext")
    count=$((count + ${#files[@]}))
    shopt -u nullglob
  done
  echo "$count"
}

# ─── Check if a file is a proper FLAC ─────────────────────────────
is_proper_flac() {
  metaflac --show-tag=ARTIST "$1" &>/dev/null
}

# ─── Check if file is MP4 container (ISO Media) with FLAC stream ──
is_mp4_with_flac() {
  local ftype
  ftype="$(file -b "$1")"
  # ISO Media / MP4 container check
  if [[ "$ftype" == *"ISO Media"* ]] || [[ "$ftype" == *"MP4"* ]]; then
    # ffprobe -v error suppresses banners, gives clean stream info
    if ffprobe -v error -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>&1 | grep -q "flac"; then
      return 0
    fi
  fi
  return 1
}

# ─── Get total track count from folder ────────────────────────────
get_total_tracks() {
  local count=0
  for f in "$1"/*.flac "$1"/*.m4a "$1"/*.mp3; do
    [ -f "$f" ] && count=$((count + 1))
  done
  echo "$count"
}

# ─── Process one album folder ─────────────────────────────────────
process_folder() {
  local folder="$1"
  local foldername
  foldername="$(basename "$folder")"

  echo ""
  blue "═══════════════════════════════════════════════════════════════"
  blue "  Processing: $foldername"
  blue "═══════════════════════════════════════════════════════════════"

  # 1. Check if folder has audio files
  local audio_count
  audio_count=$(count_audio_files "$folder")
  if [[ "$audio_count" -eq 0 ]]; then
    yellow "  ⚠  No audio files found — skipping"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    return
  fi
  echo "  Files: $audio_count audio file(s)"

  # 2. Validate audio files
  local needs_fix=false
  local all_proper=true

  shopt -s nullglob
  for f in "$folder"/*.flac; do
    if is_proper_flac "$f"; then
      :  # already proper
    elif is_mp4_with_flac "$f"; then
      echo "  ⚠  Mislabeled: $(basename "$f") — MP4 container, needs re-wrap"
      needs_fix=true
      all_proper=false
    else
      echo "  ✗  Unrecognized: $(basename "$f") — cannot process"
      all_proper=false
    fi
  done
  shopt -u nullglob

  if $needs_fix || ! $all_proper; then
    # Parse artist/album from folder name
    if ! parse_artist_album "$folder"; then
      red "  ✗  Cannot parse artist/album from folder name"
      red "     Expected format: \"Artist - Album\""
      TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
      return
    fi
    echo "  Artist: $ARTIST"
    echo "  Album:  $ALBUM"

    local total_tracks
    total_tracks=$(get_total_tracks "$folder")
    echo "  Tracks: $total_tracks"

    # Clean folder name
    local new_folder
    new_folder="$(clean_folder_name "$folder")"

    if [[ "$new_folder" != "$folder" ]]; then
      echo "  Renaming: $(basename "$folder") → $(basename "$new_folder")"
    fi

    local output_dir="$new_folder"

    if $DRY_RUN; then
      green "  [DRY RUN] Would create: $(basename "$output_dir")"
      for f in "$folder"/*.flac; do
        local fname
        fname="$(basename "$f")"
        if [[ "$fname" =~ ^([0-9]+)\.\ (.+)\.flac$ ]]; then
          local track=$((10#${BASH_REMATCH[1]}))
          local title="${BASH_REMATCH[2]}"
          echo "           $(printf '%02d' "$track"). $title.flac ← tagged"
        fi
      done
      TOTAL_FIXED=$((TOTAL_FIXED + 1))
      return
    fi

    # 3. Create clean output folder and process files
    mkdir -p "$output_dir"
    local processed=0

    for f in "$folder"/*.flac; do
      [ -f "$f" ] || continue
      local fname
      fname="$(basename "$f")"

      # Already proper FLAC — copy as-is
      if is_proper_flac "$f"; then
        echo "  ✓  $fname — already proper FLAC, copying"
        cp "$f" "$output_dir/"
        continue
      fi

      # Mislabeled MP4-with-FLAC — re-wrap
      if is_mp4_with_flac "$f"; then
        if [[ "$fname" =~ ^([0-9]+)\.\ (.+)\.flac$ ]]; then
          local track=$((10#${BASH_REMATCH[1]}))
          local title="${BASH_REMATCH[2]}"
          local outfile="$output_dir/$(printf '%02d' "$track"). $title.flac"

          echo "  🔄  $fname → re-wrapping to proper FLAC"
          ffmpeg -y -i "$f" \
            -c:a flac -compression_level 8 \
            -metadata artist="$ARTIST" \
            -metadata album="$ALBUM" \
            -metadata title="$title" \
            -metadata track="$track/$total_tracks" \
            -map_metadata -1 \
            "$outfile" 2>/dev/null

          processed=$((processed + 1))

          # Verify
          if is_proper_flac "$outfile"; then
            green "    ✓  Verified: $(basename "$outfile")"
          else
            red "    ✗  Failed to create proper FLAC"
            TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
          fi
        else
          yellow "  ⚠  Cannot parse track info from filename: $fname — skipping"
        fi
      else
        yellow "  ⚠  Skipping unrecognized file: $fname"
      fi
    done

    # Copy any non-FLAC audio files as-is (m4a, mp3, etc.)
    for ext in m4a mp3 ogg opus wav aiff wma; do
      for f in "$folder"/*."$ext"; do
        [ -f "$f" ] || continue
        if [[ "$output_dir" != "$folder" ]]; then
          echo "  Copying: $(basename "$f") (non-FLAC)"
          cp "$f" "$output_dir/"
        fi
      done
    done

    # Copy cover art
    for cover in folder.jpg cover.jpg front.jpg Folder.jpg cover.png; do
      [ -f "$folder/$cover" ] && cp "$folder/$cover" "$output_dir/" 2>/dev/null && echo "  Cover: $cover"
    done

    # 4. Rename original folder if name changed
    if [[ "$new_folder" != "$folder" ]] && [ -d "$output_dir" ]; then
      echo "  Renaming original: $(basename "$folder") → $(basename "$new_folder")"
      mv "$folder" "${folder}_orig" 2>/dev/null || true
      # output_dir = new_folder already, which is the desired name — good
      rmdir "${folder}_orig" 2>/dev/null || true
    fi

    TOTAL_FIXED=$((TOTAL_FIXED + 1))
    green "  ✅  Done — processed $processed file(s)"

  else
    # All files are proper — just clean folder name
    local new_folder
    new_folder="$(clean_folder_name "$folder")"
    if [[ "$new_folder" != "$folder" ]]; then
      echo "  📁  Renamed: $(basename "$folder") → $(basename "$new_folder")"
      if ! $DRY_RUN; then
        mv "$folder" "$new_folder"
      fi
      TOTAL_FIXED=$((TOTAL_FIXED + 1))
    else
      green "  ✅  No fixes needed"
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    fi
  fi
}

# ─── Main ─────────────────────────────────────────────────────────
echo ""
blue "╔══════════════════════════════════════════════════════════════╗"
blue "║  Beets Import Preprocessor                                   ║"
blue "║  $IMPORT_DIR"
blue "╚══════════════════════════════════════════════════════════════╝"

if $DRY_RUN; then
  yellow "  DRY RUN MODE — no changes will be made"
  echo ""
fi

if [[ $# -gt 0 ]]; then
  # Process specific folder
  target="$IMPORT_DIR/$1"
  if [ -d "$target" ]; then
    process_folder "$target"
  else
    red "Folder not found: $1"
    exit 1
  fi
else
  # Scan all folders in import directory
  shopt -s nullglob
  folders=("$IMPORT_DIR"/*/)
  shopt -u nullglob

  if [[ ${#folders[@]} -eq 0 ]]; then
    yellow "  No folders found in $IMPORT_DIR"
    exit 0
  fi

  for folder in "${folders[@]}"; do
    fb="$(basename "$folder")"
    # Skip hidden dirs and our own scripts
    [[ "$fb" == scripts ]] && continue
    process_folder "$folder"
  done
fi

# ─── Summary ──────────────────────────────────────────────────────
echo ""
blue "═══════════════════════════════════════════════════════════════"
blue "  Summary"
blue "═══════════════════════════════════════════════════════════════"
echo "  Processed:  $TOTAL_FIXED folder(s)"
echo "  Skipped:    $TOTAL_SKIPPED folder(s)"
echo "  Errors:     $TOTAL_ERRORS folder(s)"

if $DRY_RUN; then
  echo ""
  yellow "  DRY RUN — no changes were made"
  echo "  Run without --dry-run to apply."
fi

echo ""
if [[ $TOTAL_FIXED -gt 0 ]] && ! $DRY_RUN; then
  green "  Ready! Now run:  beet import -A $IMPORT_DIR/*/"
fi
