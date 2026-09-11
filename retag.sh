#!/usr/bin/env bash
# retag.sh — find and re-tag library albums that were never matched against
# MusicBrainz (imported as-is / skipped), one album at a time.
#
# Why this exists: answering "Use as-is" (or importing with `-A`, or skipping a
# failed lookup) puts files into the library with whatever tags they already
# had and NO MusicBrainz IDs — beets never fills in year/genre/label/track ids,
# and the album is invisible to MusicBrainz-based tooling. Those albums are
# exactly the ones without an `mb_albumid`. This script lists them and re-runs a
# MusicBrainz import against the *library* copies, so the files that are already
# in place get the real tags.
#
# Usage:
#   ./retag.sh                            list albums with no MusicBrainz ID
#   ./retag.sh --pick 4                   re-tag album #4 via MusicBrainz search
#   ./retag.sh --pick 4 --id <mbid>       re-tag album #4 using an exact release
#   ./retag.sh --album "Chimaira" --id <mbid>
#                                         same, selecting by album name
#   ./retag.sh --find-id --pick 4         search MusicBrainz for album #4 and
#                                         print candidate release IDs + commands
#   ./retag.sh --find-id "Artist - Album" free-text MusicBrainz search
#   ./retag.sh --all [--limit N]          walk every listed album
#
# Options:
#   --id <mbid>    MusicBrainz release ID to match exactly (repeatable). Maps to
#                  `beet import -S`, i.e. the command-line route — the prompt's
#                  `enter Id` / `Enter search` options are broken on beets
#                  2.14.x (upstream #7000: the lookup result is discarded).
#   --in-place     write tags without renaming or moving anything (`beet import
#                  -M -C`). Paths — and therefore Navidrome's album/track
#                  identity, stars, play counts and scrobbles — are kept. Without
#                  it, beets re-formats paths to its path format (import.move:
#                  yes here), and Navidrome indexes the result as a NEW album.
#   --dry-run      print the beet command instead of running it
#   --yes          skip the per-album confirmation
#   --limit N      with --all, stop after N albums
#   --list         only list (default when no album is selected)
#   -h, --help     this text
#
# What happens when you apply a match:
#   beets sees the album is already in the library and asks what to do —
#   choose R (Remove old and replace with new) to update the existing entries.
#   Tags are rewritten in place (no re-encode). Unless --in-place is given, the
#   files and album folder are then renamed to beets' path format (this setup
#   has import.move: yes) — Navidrome watches the folder and treats a renamed
#   album as a new one, leaving the previous row (and its stars/play counts)
#   behind as "missing". Playlists are unaffected by this setup (there are none),
#   but stars and play counts for the retagged album do reset.
#
# Env knobs are inherited from mb-import-lib.sh: MB_MAX_ATTEMPTS, MB_RETRY_DELAY.
# Transcripts of every attempt land in retag.log (next to this script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Override the wrapper's log before sourcing it, so re-tagging keeps its own
# transcript instead of appending to the import history.
mb_logfile="${mb_logfile:-$SCRIPT_DIR/retag.log}"
# shellcheck source=mb-import-lib.sh
source ./mb-import-lib.sh

# ---------------------------------------------------------------- helpers ---

die()  { printf '  ✗  %s\n' "$*" >&2; exit 1; }
info() { printf '  •  %s\n' "$*"; }
warn() { printf '  ⚠  %s\n' "$*" >&2; }
ok()   { printf '  ✅ %s\n' "$*"; }

usage() { sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

# Album data, one entry per album without a MusicBrainz album id.
declare -a A_ALBUM=() A_ARTIST=() A_YEAR=() A_DIR=() A_TRACKS=() A_NOTE=()
declare -A _A_INDEX=()
LOOSE_TRACKS=0

# One pass over the library in *item* mode: item rows give real per-album track
# counts and file paths (album mode returns the album directory and no count),
# and grouping here avoids querying by album name — names in this library
# contain [..] / (..), which beets' regex queries would mangle.
load_albums() {
  A_ALBUM=(); A_ARTIST=(); A_YEAR=(); A_DIR=(); A_TRACKS=(); A_NOTE=()
  _A_INDEX=()
  LOOSE_TRACKS=0
  local mbid album artist year path key idx dir
  while IFS='|' read -r mbid album artist year path; do
    [[ -z "$path" ]] && continue
    if [[ -z "$album" ]]; then
      LOOSE_TRACKS=$((LOOSE_TRACKS + 1))   # singleton / untagged single file
      continue
    fi
    [[ -n "$mbid" ]] && continue           # already MusicBrainz-tagged
    key="${album}"$'\x1f'"${artist}"
    dir="$(dirname "$path")"
    if [[ -n "${_A_INDEX[$key]:-}" ]]; then
      idx="${_A_INDEX[$key]}"
      A_TRACKS[$idx]=$(( ${A_TRACKS[$idx]} + 1 ))
      [[ "${A_DIR[$idx]}" != "$dir" ]] && A_NOTE[$idx]="also in $(basename "$dir")"
      continue
    fi
    A_ALBUM+=("$album"); A_ARTIST+=("$artist"); A_YEAR+=("$year")
    A_DIR+=("$dir"); A_TRACKS+=(1); A_NOTE+=("")
    _A_INDEX[$key]=$(( ${#A_ALBUM[@]} - 1 ))
  done < <(beet ls -f '$mb_albumid|$album|$albumartist|$year|$path' 2>/dev/null || true)
}

# Indices sorted by artist, then album.
sorted_indices() {
  local i
  for (( i = 0; i < ${#A_ALBUM[@]}; i++ )); do
    printf '%s\x1f%s\x1f%s\n' "${A_ARTIST[$i]}" "${A_ALBUM[$i]}" "$i"
  done | sort | while IFS=$'\x1f' read -r _ _ idx; do printf '%s\n' "$idx"; done
}

total_albums() { beet ls -a 2>/dev/null | wc -l | tr -d ' '; }

print_list() {
  local n i len=${#A_ALBUM[@]}
  if (( len == 0 )); then
    ok "No untagged albums — every album in the library has a MusicBrainz id."
    return 0
  fi
  printf '\n'
  printf '  %3s  %-42s %-24s %-6s %-4s %s\n' '#' 'Album' 'Artist' 'Year' 'Trk' 'Folder'
  printf '  %3s  %-42s %-24s %-6s %-4s %s\n' '---' '------------------------------------------' '------------------------' '------' '---' '------'
  n=0
  while IFS= read -r i; do
    n=$((n + 1))
    printf '  %3d  %-42.42s %-24.24s %-6.6s %-4s %s%s\n' \
      "$n" "${A_ALBUM[$i]}" "${A_ARTIST[$i]}" "${A_YEAR[$i]:-?}" "${A_TRACKS[$i]}" \
      "${A_DIR[$i]}" "${A_NOTE[$i]:+  ⚠ ${A_NOTE[$i]}}"
  done < <(sorted_indices)
  printf '\n  %d album(s) without a MusicBrainz id (of %s albums in the library).\n' \
    "$len" "$(total_albums)"
  if (( LOOSE_TRACKS > 0 )); then
    printf '  %d file(s) have no album tag at all (singles) — not covered here;\n' "$LOOSE_TRACKS"
    printf '  see `beet ls -f "%%path" album::^$` and import those with `beet import -s`.\n'
  fi
  printf '\n'
  printf '  Re-tag one:   ./retag.sh --pick <#>\n'
  printf '  Find an ID:   ./retag.sh --find-id --pick <#>      (search MusicBrainz)\n'
  printf '  Re-tag all:   ./retag.sh --all\n\n'
}

# Resolve --pick N / --album NAME to an index in A_*.
_RETA_ORDER=()

resolve_selection() {
  local pick="$1" name="$2" i n=0 hit=-1
  if [[ -n "$pick" ]]; then
    [[ "$pick" =~ ^[0-9]+$ ]] || die "--pick expects a number (see the listing)"
    while IFS= read -r i; do
      n=$((n + 1))
      if (( n == pick )); then hit="$i"; break; fi
    done < <(sorted_indices)
    (( hit >= 0 )) || die "no album #$pick (run ./retag.sh to list)"
    printf '%s\n' "$hit"
    return 0
  fi
  # Literal match on album name (exact first, then unique substring).
  local idx exact=() loose=()
  for (( idx = 0; idx < ${#A_ALBUM[@]}; idx++ )); do
    [[ "${A_ALBUM[$idx]}" == "$name" ]] && exact+=("$idx")
    [[ "${A_ALBUM[$idx]}" == *"$name"* ]] && loose+=("$idx")
  done
  if (( ${#exact[@]} == 1 )); then printf '%s\n' "${exact[0]}"; return 0; fi
  if (( ${#exact[@]} > 1 )); then die "album name '$name' is ambiguous — use --pick"; fi
  if (( ${#loose[@]} == 1 )); then printf '%s\n' "${loose[0]}"; return 0; fi
  if (( ${#loose[@]} > 1 )); then
    warn "'$name' matches ${#loose[@]} albums — use --pick:"
    for i in "${loose[@]}"; do printf '       %s — %s\n' "${A_ARTIST[$i]}" "${A_ALBUM[$i]}" >&2; done
    exit 1
  fi
  die "no untagged album matching '$name' (run ./retag.sh to list)"
}

# ------------------------------------------------------------------- modes ---

retag_one() {
  local idx="$1"; shift
  local dir="${A_DIR[$idx]}" album="${A_ALBUM[$idx]}" artist="${A_ARTIST[$idx]}"
  [[ -d "$dir" ]] || die "folder not found: $dir"

  local mode_desc="MusicBrainz search"
  (( $# > 0 )) && mode_desc="release ID ($*)"
  (( IN_PLACE )) && mode_desc+=", in place (files keep their paths)"

  printf '\n'
  printf '  ── %s — %s (%s tracks)\n' "$artist" "$album" "${A_TRACKS[$idx]}"
  printf '     folder: %s\n' "$dir"
  printf '     using : %s\n' "$mode_desc"

  if (( DRY_RUN )); then
    printf '     would run: beet import %s"%s/"\n' \
      "$( (( $# > 0 )) && printf '%s ' "$@" || true )" "$dir"
    return 0
  fi

  if (( ! IN_PLACE )); then
    printf '     note: files will be renamed to beets'\'' path format → Navidrome indexes\n'
    printf '     this album as new (its stars/play counts reset). --in-place avoids that.\n'
  fi
  if (( ! ASSUME_YES )); then
    printf '     beets may ask about the album already being in the library — if it does,\n'
    printf '     choose R (Remove old and replace with new) to update the existing entries.\n'
    local ans
    read -r -p "     Proceed? [y/N] " ans || true
    [[ "${ans:-n}" =~ ^[Yy] ]] || { info "skipped"; return 2; }
  fi

  local rc=0
  beet_import_with_mb_retry "$dir/" "$@" || rc=$?
  if (( rc != 0 )); then
    warn "re-tag failed for '$album' (exit $rc) — transcript: $mb_logfile"
    return 1
  fi

  # Verify: with -S we can check the exact release id, otherwise re-list and see
  # whether the album disappeared from the untagged set.
  local i
  if (( $# > 0 )); then
    for i in "$@"; do
      [[ "$i" == "-S" ]] && continue
      if [[ -n "$(beet ls -a "mb_albumid:$i" 2>/dev/null | head -1)" ]]; then
        ok "tagged: $album → mb_albumid=$i"
        return 0
      fi
    done
    warn "import finished but mb_albumid=$* is not in the library — check $mb_logfile"
    return 1
  fi
  load_albums
  for (( i = 0; i < ${#A_ALBUM[@]}; i++ )); do
    [[ "${A_ALBUM[$i]}" == "$album" && "${A_ARTIST[$i]}" == "$artist" ]] && {
      warn "still no MusicBrainz id — the match was probably applied as-is"
      return 1
    }
  done
  ok "tagged: $album (no longer in the untagged list)"
}

find_ids() {
  local query="$1" idx="${2:-}"
  [[ -n "$query" ]] || die "--find-id needs a query, or use it with --pick/--album"

  local next_cmd_hint
  if [[ -n "$idx" ]]; then
    next_cmd_hint="./retag.sh --pick $(pick_number_for "$idx") --id"
  else
    next_cmd_hint="./retag.sh --album \"<album>\" --id"
  fi

  printf '\n  MusicBrainz release search for: %s\n\n' "$query"
  python3 - "$query" <<'PY'
import json, sys, time, urllib.parse, urllib.request

query = sys.argv[1]
UA = "retag.sh/1.0 ( beets-import-tools )"
url = ("https://musicbrainz.org/ws/2/release?limit=8&fmt=json&query="
       + urllib.parse.quote(query))

data, err = None, None
for attempt in range(6):
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
        break
    except Exception as exc:                      # 503 throttling is routine now
        err = exc
        time.sleep(1.5 * (attempt + 1))
if data is None:
    print(f"  MusicBrainz search unavailable after 6 tries ({err})")
    print("  The website usually still works — search there and pass the ID:")
    print("  https://musicbrainz.org/search?type=release&query="
          + urllib.parse.quote(query))
    sys.exit(1)

releases = data.get("releases", [])
if not releases:
    print("  No releases found. Try a simpler query (drop [..] / (..) suffixes)")
    print("  https://musicbrainz.org/search?type=release&query="
          + urllib.parse.quote(query))
    sys.exit(1)

def artist_name(rel):
    parts = []
    for ac in rel.get("artist-credit", []):
        if isinstance(ac, dict):
            parts.append(ac.get("name") or ac.get("artist", {}).get("name", ""))
        else:
            parts.append(str(ac))
    return "".join(parts)

for i, rel in enumerate(releases, 1):
    tracks = sum(m.get("track-count", 0) for m in rel.get("media", []))
    bits = [f"{tracks}trk" if tracks else None, rel.get("country"),
            (rel.get("date") or "")[:10], rel.get("status"),
            ", ".join(m.get("format", "?") for m in rel.get("media", []))]
    print(f"  {i:2d}  {rel['id']}  {artist_name(rel)} — {rel.get('title')}")
    print(f"      {' | '.join(b for b in bits if b)}")

print()
print("  Browse: https://musicbrainz.org/search?type=release&query="
      + urllib.parse.quote(query))
PY
  printf '\n  Apply one of the ids above, e.g.:\n    %s <release-mbid>\n\n' "$next_cmd_hint"
}

pick_number_for() {
  local want="$1" i n=0
  while IFS= read -r i; do
    n=$((n + 1))
    [[ "$i" == "$want" ]] && { printf '%s\n' "$n"; return 0; }
  done < <(sorted_indices)
  printf '?\n'
}

# -------------------------------------------------------------------- main ---

DRY_RUN=0
ASSUME_YES=0
IN_PLACE=0
LIMIT=0
PICK=""
ALBUM_Q=""
FIND_ID=0
FIND_QUERY=""
declare -a IDS=()

while (( $# )); do
  case "$1" in
    --list)     ;;
    --pick)     PICK="${2:-}"; shift ;;
    --album)    ALBUM_Q="${2:-}"; shift ;;
    --id)       IDS+=("${2:-}"); shift ;;
    --find-id)  FIND_ID=1; [[ "${2:-}" != --* && -n "${2:-}" ]] && { FIND_QUERY="$2"; shift; } ;;
    --all)      ALL=1 ;;
    --limit)    LIMIT="${2:-0}"; shift ;;
    --dry-run)  DRY_RUN=1 ;;
    --in-place) IN_PLACE=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

load_albums

# --find-id with an explicit free-text query: read-only, no selection needed.
if (( FIND_ID )) && [[ -n "$FIND_QUERY" ]]; then
  find_ids "$FIND_QUERY"
  exit 0
fi

# Everything else needs a target album.
if [[ -z "$PICK" && -z "$ALBUM_Q" && -z "${ALL:-}" ]]; then
  print_list
  (( ${#A_ALBUM[@]} == 0 )) || exit 0
  exit 0
fi

beet_flags=()
if (( ${#IDS[@]} )); then
  for id in "${IDS[@]}"; do
    [[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]] || warn "'$id' does not look like a MusicBrainz id"
    beet_flags+=(-S "$id")
  done
fi
if (( IN_PLACE )); then
  beet_flags+=(-M -C)   # never move/copy: write tags, leave paths alone
fi

if [[ -n "${ALL:-}" ]]; then
  (( ${#A_ALBUM[@]} )) || { ok "Nothing to do — no untagged albums."; exit 0; }
  if (( FIND_ID )); then
    # Search each album on MusicBrainz and report ids; no imports.
    n=0
    while IFS= read -r i; do
      n=$((n + 1))
      (( LIMIT > 0 && n > LIMIT )) && break
      find_ids "${A_ARTIST[$i]} ${A_ALBUM[$i]}" "$i"
    done < <(sorted_indices)
    exit 0
  fi
  printf '\n  Re-tagging %s album(s)%s\n' "${#A_ALBUM[@]}" \
    "$( (( ${#beet_flags[@]} )) && printf ' using the id(s) given' || printf ' via MusicBrainz search')"
  (( ASSUME_YES )) || { read -r -p "  Continue? [y/N] " a || true; [[ "${a:-n}" =~ ^[Yy] ]] || exit 0; }
  done_n=0 skipped=0 failed=0 n=0
  while IFS= read -r i; do
    n=$((n + 1))
    (( LIMIT > 0 && n > LIMIT )) && break
    rc=0; retag_one "$i" "${beet_flags[@]}" || rc=$?
    case $rc in 0) done_n=$((done_n + 1)) ;; 2) skipped=$((skipped + 1)) ;; *) failed=$((failed + 1)) ;; esac
    load_albums   # the list shifts as albums get tagged
  done < <(sorted_indices)
  printf '\n  Summary: %d tagged, %d skipped, %d failed.\n\n' "$done_n" "$skipped" "$failed"
  (( failed == 0 )) || exit 1
  exit 0
fi

IDX="$(resolve_selection "$PICK" "$ALBUM_Q")"
if (( FIND_ID )); then
  find_ids "${A_ARTIST[$IDX]} ${A_ALBUM[$IDX]}" "$IDX"
  exit 0
fi
retag_one "$IDX" "${beet_flags[@]}"
