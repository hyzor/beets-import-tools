#!/usr/bin/env bash
# mb-import-lib.sh — MusicBrainz rate-limit handling for beets imports.
#
# Source this file from import scripts (import.sh, soulseek-import.sh). It
# provides beet_import_with_mb_retry(): runs `beet import` for ONE album
# folder and, when the run dies because MusicBrainz throttled us (HTTP 503
# "Max retries exceeded ... too many NNN error responses"), waits for the
# rate window to clear and retries with backoff.
#
# Why this is needed: beets 2.12+ throttles to ≤1 MB request/sec and retries
# 6x, but the built-in retries use only ~30 s of total backoff and do NOT
# honor MusicBrainz's cooldown, so a throttled import still fails. MB blocks
# per IP ("all requests declined with 503 until the rate drops again") and
# since 2025-2026 also sheds load from AI-scraper pressure. Both clear within
# a minute or two of the client going quiet, which beets itself never does —
# a script-level wait-then-retry is the reliable fix.
#
# Configuration (plain env vars, set before sourcing or before calling):
#   MB_MAX_ATTEMPTS  (default 3)   total import attempts per folder
#   MB_RETRY_DELAY   (default 60)  base seconds waited between attempts
#                                  (delay = MB_RETRY_DELAY x attempt number)
#   mb_logfile       (default <import dir>/mb-import.log) append target for
#                                  every import attempt's full output
#
# Usage:
#   source ./mb-import-lib.sh
#   beet_import_with_mb_retry "albums/Artist - Album/" [-L] [-A] ...
#     folder first, any extra `beet import` flags after.
#   Exit: 0 = folder imported, 1 = failed after all attempts.

MB_MAX_ATTEMPTS="${MB_MAX_ATTEMPTS:-3}"
MB_RETRY_DELAY="${MB_RETRY_DELAY:-60}"
: "${mb_logfile:="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mb-import.log"}"

# Matches the urllib3/requests failure beets logs after exhausting its retries
# ("too many 503 error responses", "too many 429 error responses") and the
# MusicBrainz error body ("Your requests are exceeding the allowable rate
# limit"). Everything else is treated as a genuine, non-retryable failure.
_mb_rate_limited() {
  grep -Eiq "too many [0-9]+ error responses|exceeding the allowable rate limit" "$1"
}

beet_import_with_mb_retry() {
  local folder="$1"
  shift
  local attempt=1 rc runlog

  while :; do
    runlog="$(mktemp "${TMPDIR:-/tmp}/beet-import.XXXXXX")"

    # Interactive: beets prompts on stdin (still the terminal); stdout is
    # piped through tee so the user sees everything live. Read PIPESTATUS
    # immediately in both branches so the rc does not depend on whether the
    # caller enabled `pipefail`.
    if beet import "$@" "$folder" 2>&1 | tee -a "$runlog"; then
      rc=${PIPESTATUS[0]}
    else
      rc=${PIPESTATUS[0]}
    fi

    # Persist the full transcript (retries included) for later inspection.
    cat "$runlog" >> "$mb_logfile" 2>/dev/null || true

    # Retry only when the run actually failed WITH the rate-limit signature.
    # A clean exit (e.g. user skipped the album) is never re-run.
    if [[ $rc -eq 0 ]] || ! _mb_rate_limited "$runlog"; then
      break
    fi
    rm -f "$runlog"

    if (( attempt >= MB_MAX_ATTEMPTS )); then
      break
    fi

    local wait=$((MB_RETRY_DELAY * attempt))
    echo ""
    echo "  ⏳  MusicBrainz rate-limited the request (HTTP 503/429)." >&2
    echo "      Waiting ${wait}s for the rate window to clear, then retrying" >&2
    echo "      (attempt $((attempt + 1))/${MB_MAX_ATTEMPTS})." >&2
    sleep "$wait"
    attempt=$((attempt + 1))
  done

  if [[ $rc -ne 0 ]]; then
    echo "  ⚠  Import failed for: $(basename "$folder") (exit $rc)." >&2
    echo "      Full output: $mb_logfile — folder left in place for a later re-run." >&2
  fi
  rm -f "$runlog"
  return "$rc"
}
