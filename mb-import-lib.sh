#!/usr/bin/env bash
# mb-import-lib.sh — MusicBrainz resilience handling for beets imports.
#
# Source this file from import scripts (import.sh, soulseek-import.sh). It
# provides beet_import_with_mb_retry(): runs `beet import` for ONE album
# folder and, when the run fails because MusicBrainz throttled us (HTTP 503
# "too many 503 error responses") or was too slow / unresponsive (request
# timeouts), waits for MB to recover and retries with backoff.
#
# Why this is needed: beets 2.12+ throttles to ≤1 MB request/sec and retries
# 6x, but the built-in retries use only ~30 s of total backoff and do NOT
# honor MusicBrainz's cooldown, so a throttled import still fails. MB blocks
# per IP ("all requests declined with 503 until the rate drops again") and
# since 2025-2026 also sheds load from AI-scraper pressure — API responses
# can take 5-30+ s or time out entirely even for compliant clients. Recovery
# needs the client to go quiet for a minute or two, which beets itself never
# does — a script-level wait-then-retry is the reliable fix.
#
# Visibility: beets prints nothing during autotag lookups (they are
# debug-level), so this wrapper announces each attempt up front and runs
# retries with `beet -v` to stream live MusicBrainz request logs. beets is
# also run with PYTHONUNBUFFERED so its output isn't block-buffered by the
# tee pipe.
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

# Matches the failure signatures worth waiting out and retrying:
#   - urllib3/requests failures beets logs after exhausting its retries:
#     "too many 503 error responses" / "too many 429 error responses"
#     (rate limiting), and "Max retries exceeded ... timed out" /
#     "ReadTimeoutError" / "ConnectionError" (MusicBrainz slow or flaky —
#     common under MB's 2025+ AI-scraper load, where responses can take
#     5-30+ s and occasionally exceed beets' 10 s timeout).
#   - the MusicBrainz error body ("exceeding the allowable rate limit").
# Everything else (user abort, local file errors, ...) is a genuine,
# non-retryable failure. Only runs with rc != 0 reach this check, so a clean
# exit is never re-run.
_mb_retryable_failure() {
  grep -Eiq "too many [0-9]+ error responses|exceeding the allowable rate limit|Max retries exceeded|timed out|ConnectionError|Connection refused" "$1"
}

beet_import_with_mb_retry() {
  local folder="$1"
  shift
  local attempt=1 rc runlog

  while :; do
    runlog="$(mktemp "${TMPDIR:-/tmp}/beet-import.XXXXXX")"

    echo ""
    echo "  ▶  Attempt ${attempt}/${MB_MAX_ATTEMPTS}: $(basename "$folder")" >&2
    echo "     (MusicBrainz can be slow under load — long gaps with no output are" >&2
    echo "      normal while it looks up the album. Retrying shows verbose logs.)" >&2
    {
      echo ""
      echo "== $(date '+%F %T') attempt ${attempt}/${MB_MAX_ATTEMPTS} — $(basename "$folder")"
    } >> "$runlog"

    # Attempts after the first run `beet -v` so the user sees live progress
    # (each MusicBrainz request is logged) instead of silence.
    local verbosity=()
    ((attempt > 1)) && verbosity=(-v)

    # PYTHONUNBUFFERED keeps beets' output streaming through the tee — when
    # stdout is a pipe Python otherwise block-buffers and nothing appears
    # until the buffer fills or the process exits. Prompts still work: beets
    # reads stdin (the terminal) directly.
    # Read PIPESTATUS immediately in both branches so the rc does not depend
    # on whether the caller enabled `pipefail`.
    if PYTHONUNBUFFERED=1 beet "${verbosity[@]}" import "$@" "$folder" 2>&1 | tee -a "$runlog"; then
      rc=${PIPESTATUS[0]}
    else
      rc=${PIPESTATUS[0]}
    fi

    # Persist the full transcript (retries included) for later inspection.
    cat "$runlog" >> "$mb_logfile" 2>/dev/null || true

    # Retry only when the run actually failed WITH a retryable MB signature.
    # A clean exit (e.g. user skipped the album) is never re-run.
    if [[ $rc -eq 0 ]] || ! _mb_retryable_failure "$runlog"; then
      break
    fi
    rm -f "$runlog"

    if (( attempt >= MB_MAX_ATTEMPTS )); then
      break
    fi

    local wait=$((MB_RETRY_DELAY * attempt))
    echo ""
    echo "  ⏳  MusicBrainz was unresponsive or rate-limited (HTTP 503/429, timeout)." >&2
    echo "      Waiting ${wait}s, then retrying with verbose logging" >&2
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
