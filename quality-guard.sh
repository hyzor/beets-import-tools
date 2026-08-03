#!/usr/bin/env bash
# quality-guard.sh — Lossless-only quality gate for downloaded music.
#
# Verifies an album folder contains ONLY genuine lossless audio, and that the
# audio isn't a lossy source transcoded into a lossless container (the classic
# "128 kbps MP3 upconverted to FLAC" scam).
#
# Usage:
#   check_album_quality <folder>     # prints a report; exit 0 = pass, 1 = fail
#
# Source this file from other scripts (soulseek-import.sh, preprocess.sh).
#
# Overridable thresholds (set before sourcing):
#   MIN_SAMPLE_RATE  (default 44100)
#   MIN_BIT_DEPTH    (default 16)
#   MIN_AVG_BITRATE  (default 500)  # kbps album average — transcode detector
#   SHORT_FILE_SECS  (default 15)   # files shorter than this are excluded from
#                                   # the bitrate average (intros, silence, cues)
#
# Exit codes: 0 = all files pass, 1 = at least one check failed.

# ─── Config ────────────────────────────────────────────────────────
MIN_SAMPLE_RATE="${MIN_SAMPLE_RATE:-44100}"
MIN_BIT_DEPTH="${MIN_BIT_DEPTH:-16}"
MIN_AVG_BITRATE="${MIN_AVG_BITRATE:-500}"
SHORT_FILE_SECS="${SHORT_FILE_SECS:-15}"

# ffprobe codec names that are genuinely lossless
LOSSLESS_CODECS="flac alac pcm_s16le pcm_s24le pcm_s32le pcm_f32le pcm_f64le pcm_s16be pcm_s24be pcm_s32be wavpack ape dsd_lsbf dsd_msbf dsd_lsb dsd_msb"

# ─── Helpers ───────────────────────────────────────────────────────
is_lossless_codec() {
  local codec="$1"
  [[ " $LOSSLESS_CODECS " == *" $codec "* ]]
}

# probe_file <file> — fills globals: PROBE_CODEC, PROBE_SAMPLE_RATE,
# PROBE_BIT_DEPTH, PROBE_BITRATE, PROBE_DURATION
probe_file() {
  local info
  info=$(ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name,sample_rate,bits_per_raw_sample,bits_per_sample,bit_rate:format=bit_rate,duration \
    -of default=nw=1 "$1" 2>/dev/null)

  PROBE_CODEC=$(printf '%s\n' "$info" | sed -n 's/^codec_name=//p' | head -1)
  PROBE_SAMPLE_RATE=$(printf '%s\n' "$info" | sed -n 's/^sample_rate=//p' | head -1)
  PROBE_BIT_DEPTH=$(printf '%s\n' "$info" | sed -n 's/^bits_per_raw_sample=//p' | head -1)
  # PCM/WAV/DSD report bits_per_sample instead of bits_per_raw_sample
  if [[ -z "$PROBE_BIT_DEPTH" ]]; then
    PROBE_BIT_DEPTH=$(printf '%s\n' "$info" | sed -n 's/^bits_per_sample=//p' | head -1)
  fi
  # bit_rate: stream-level is N/A for FLAC; the format-level value (last line)
  # is the whole-file average we want. Use tail -1 to prefer format level.
  PROBE_BITRATE=$(printf '%s\n' "$info" | sed -n 's/^bit_rate=//p' | tail -1)
  [[ "$PROBE_BITRATE" == "N/A" ]] && PROBE_BITRATE=""
  PROBE_DURATION=$(printf '%s\n' "$info" | sed -n 's/^duration=//p' | tail -1)
  [[ "$PROBE_DURATION" == "N/A" ]] && PROBE_DURATION=""
}

# ─── The guard ─────────────────────────────────────────────────────
# check_album_quality <folder>
# Prints a per-file report + verdict. Returns 0 if the folder passes.
check_album_quality() {
  local folder="$1"
  local -a files=()
  local -a audio_exts=(flac wav aiff aif m4a mp4 ape wv dsf dff mp3 ogg opus oga wma aac)
  local ext f codec reason
  local total=0 failed=0 total_bitrate=0 avg_files=0 avg_bitrate=0

  shopt -s nullglob
  for ext in "${audio_exts[@]}"; do
    for f in "$folder"/*."$ext"; do
      files+=("$f")
    done
  done
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "  ⛔  No audio files found in: $folder"
    return 1
  fi

  echo "  ── Quality guard ────────────────────────────────"
  for f in "${files[@]}"; do
    total=$((total + 1))
    local fname
    fname="$(basename "$f")"

    probe_file "$f"

    if [[ -z "$PROBE_CODEC" ]]; then
      echo "  ✗  $fname — unreadable/corrupt (ffprobe failed)"
      failed=$((failed + 1))
      continue
    fi

    if ! is_lossless_codec "$PROBE_CODEC"; then
      echo "  ✗  $fname — lossy codec: $PROBE_CODEC"
      failed=$((failed + 1))
      continue
    fi

    if [[ -n "$PROBE_SAMPLE_RATE" ]] && (( PROBE_SAMPLE_RATE < MIN_SAMPLE_RATE )); then
      echo "  ✗  $fname — low sample rate: ${PROBE_SAMPLE_RATE} Hz (min ${MIN_SAMPLE_RATE})"
      failed=$((failed + 1))
      continue
    fi

    if [[ -n "$PROBE_BIT_DEPTH" ]] && (( PROBE_BIT_DEPTH < MIN_BIT_DEPTH )); then
      echo "  ✗  $fname — low bit depth: ${PROBE_BIT_DEPTH}-bit (min ${MIN_BIT_DEPTH})"
      failed=$((failed + 1))
      continue
    fi

    # Exclude very short files (intros, silence, cues) from the bitrate average
    local is_short=0
    if [[ -n "$PROBE_DURATION" ]]; then
      local dur_int="${PROBE_DURATION%.*}"  # truncate float: 60.5 -> 60
      (( dur_int < SHORT_FILE_SECS )) && is_short=1
    fi

    if [[ -n "$PROBE_BITRATE" ]] && (( is_short == 0 )); then
      avg_files=$((avg_files + 1))
      total_bitrate=$((total_bitrate + PROBE_BITRATE))
    fi

    echo "  ✓  $fname — ${PROBE_CODEC}, ${PROBE_BIT_DEPTH:-?}-bit, $((PROBE_SAMPLE_RATE / 1000)) kHz, $((PROBE_BITRATE / 1000)) kbps"
  done

  echo "  ──────────────────────────────────────────────────"

  if (( failed > 0 )); then
    echo "  ⛔  FAIL: $failed of $total file(s) are lossy or low quality."
    return 1
  fi

  # Album-level transcode detection: genuine CD FLAC averages 700–1100 kbps.
  if (( avg_files > 0 )); then
    avg_bitrate=$((total_bitrate / avg_files / 1000))
    echo "  ℹ   Average bitrate: ${avg_bitrate} kbps over ${avg_files} file(s)"
    if (( avg_bitrate < MIN_AVG_BITRATE )); then
      echo "  ⛔  FAIL: average ${avg_bitrate} kbps < ${MIN_AVG_BITRATE} — likely lossy source transcoded to lossless."
      return 1
    fi
  fi

  echo "  ✅  PASS: ${total} file(s), all lossless."
  return 0
}
