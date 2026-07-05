# 🎵 Beets Import Toolkit

This is a set of scripts for preprocessing and importing music into a [beets](https://beets.io/) library. Place album folders in `albums/`, run `./import.sh`, and everything is handled automatically.

## Structure

```
/path/to/import/
├── albums/             ← Drop album folders here
│   ├── Artist - Album/
│   └── ...
├── import.sh           ← Main entry point (preprocess + import)
├── preprocess.sh       ← Pre-flight check & fix (runs automatically)
├── embed-lrc.sh        ← Embed .lrc lyrics into file tags
├── clean.sh            ← Remove processed album folders
└── README.md
```

## Setup

Clone or copy these scripts into your beets import staging directory, then configure your beets library path:

```bash
# Edit preprocess.sh and set IMPORT_DIR to your staging folder
# Or just run the scripts from the directory they live in
```

## Scripts

| Script | Purpose |
|---|---|
| `import.sh` | **Main entry point** — runs `preprocess.sh` first, then `beet import .` |
| `preprocess.sh` | Pre-flight check & fix — detects mislabeled files, re-wraps them, tags from filenames, cleans folder names |
| `embed-lrc.sh` | Embed existing `.lrc` sidecar lyrics into audio file tags for beets awareness |
| `clean.sh` | Deletes everything except scripts and `README.md` — run after successful import |

---

## Workflow

```bash
cd /path/to/import/

# Place album folder(s) in albums/:
cp -r /path/to/Album /path/to/import/albums/

# Import (runs preprocessor + beets in one step)
./import.sh

# Clean up
./clean.sh
```

That's it. `import.sh` always runs the preprocessor first — no way to skip it.

### Import without MusicBrainz (use filenames as tags)

Use when files already have correct internal tags, or when the folder contains non-standard releases that MusicBrainz won't match:

```bash
beet import -A "Artist - Album Name/"
```

The `-A` flag (as-is) skips MusicBrainz lookup and uses whatever metadata the files already have, or derives it from the folder/file names.

---

## Folder naming requirements

Beets expects album folders following this pattern:

```
Artist Name - Album Title/
  ├── 01. Track Title.flac
  ├── 02. Track Title.flac
  ├── ...
  └── folder.jpg          (optional cover art)
```

- **Artist and album** are parsed from the folder name using `" - "` as separator
- **Track number and title** are parsed from filenames using `"NN. Title.ext"` pattern
- Cover art (`folder.jpg`, `cover.jpg`, or `front.jpg`) is detected automatically

## preprocess.sh — detailed

This script is always run as part of `./import.sh`. You can also run it standalone for a dry-run or to check a specific folder. It scans every album folder and:

### What it checks

1. **Folder name cleanup** — strips quality/format suffixes like `[16B-44.1kHz]`, `[FLAC]`, `[24B-96kHz]`, `[ALAC]`, `[MP3]`, `[VIP]`, etc.

2. **File validation** — for each `.flac` file, it checks:
   - Is it actually a FLAC? (`metaflac` header check)
   - Is it an MP4 container with a FLAC stream inside? (`file` + `ffprobe`)
   - If neither, flags it as unrecognized

3. **Re-wrap mislabeled files** — files that are actually MP4 containers (ISO Media, MP4 v2) but have `.flac` extensions get re-wrapped to proper FLAC via `ffmpeg`, with tags set from the folder name and filenames.

4. **Tagging** — automatically sets artist, album, title, and track number metadata based on the folder structure.

5. **Cover art** — copies any existing cover image to the output folder.

### Usage

```bash
./preprocess.sh                    # process all folders in albums/
./preprocess.sh --dry-run          # preview only, no changes
./preprocess.sh "Album Folder/"    # process specific folder in albums/
./preprocess.sh --dry-run "Album Folder/"
```

### Artifacts from failed runs

If the script crashes mid-way (e.g. disk full, power loss), you might see folders with `_orig` suffixes. These can be safely deleted once you've confirmed the replacement folder is correct.

---

## Common issues

### "No files imported" from beets

**Likely cause**: Files have the wrong extension. Some download services produce MP4 containers (`.m4a`/`.mp4`) that contain a FLAC audio stream but re-label them as `.flac`.

**Fix**:
```bash
./preprocess.sh
```

This detects and re-wraps them automatically.

### "[Unknown album]" in library

**Likely cause**: A previous import created entries from untagged files (e.g. from a failed test run). The orphan files end up in `/path/to/music/library/__/`.

**Fix**:
```bash
printf "Yes\n" | beet remove -d path:'__/'
```

### Duplicate album prompt during import

If beets says "This album is already in the library!", it found an existing match. Options:
- `K` — Keep all (keep old, skip new)
- `S` — Skip new (same as Keep all, just skip the new copy)
- `R` — Remove old and replace with new
- `M` — Merge (add new tracks to existing album)

### WARNING: Unrecognized file

If `preprocess.sh` says "Unrecognized" for some files, the file format is neither a proper FLAC nor an MP4 container with a FLAC stream. Check the file manually:

```bash
file "filename.flac"
ffprobe "filename.flac" 2>&1 | grep "Audio:"
```

These files cannot be processed by the script and need manual inspection.

---

## Beets library reference

| Setting | Value |
|---|---|
| **Music directory** | `/path/to/music/library/` |
| **Database** | `~/beets/library.db` |
| **Import mode** | `move: yes` (files are moved, not copied) |
| **Plugins** | `musicbrainz` (autotagging) |
| **MusicBrainz search** | Limit: 5, no ASCII query conversion |
| **Staging area** | `/path/to/import/` |

### Useful commands

```bash
beet stats                  # Library overview (tracks, albums, artists)
beet list -a                # All albums
beet list -a "Artist"       # Albums by an artist
beet list album:"Album"     # Tracks in an album
beet list -f '$track. $title' album:"Album"
beet list -f '$path' album:"Album"   # File paths
beet list -a '' ''          # Orphaned albums (empty artist/album)
```

---

## Lyrics

The beets [lyrics](https://beets.io/plugins/lyrics/) plugin ships with beets and can fetch lyrics from multiple sources, then embed them directly into your audio files. It runs automatically during import and can be run against your existing library.

### Setup

Add `lyrics` to your beets plugins list and configure the sources you want to use:

```yaml
# ~/.config/beets/config.yaml
plugins:
    - musicbrainz
    - lyrics

lyrics:
    auto: true     # Fetch lyrics automatically on import
    force: false   # Don't re-fetch if lyrics already exist
    synced: false  # Prefer synced/timed lyrics (LRC format)
    sources:
        - lrclib
        - genius
```

### Dependencies

The lyrics plugin needs `beautifulsoup4` and `requests` (which beets already depends on):

```bash
# Arch / CachyOS
sudo pacman -S python-beautifulsoup4
```

### Available sources

| Source | API key needed | Notes |
|---|---|---|
| `lrclib` | No | Best for synced lyrics, no registration required |
| `genius` | Built-in | Ships with a bundled API key, works out of the box |
| `google` | Yes | Requires Google Custom Search API key + engine ID |

`musixmatch` and `tekstowo` are available in the plugin but disabled by default (they block requests from the beets user agent).

### Usage

```bash
# Fetch lyrics for your entire library (skips tracks that already have them)
beet lyrics

# Fetch lyrics for a specific album or query
beet lyrics album:"Moment Of Truth"
beet lyrics -a "Artist Name"

# Print lyrics to console (doesn't re-fetch)
beet lyrics -p album:"Album"

# Force re-download even if lyrics already exist
beet lyrics -f

# Only fetch for tracks missing lyrics (local mode)
beet lyrics -l
```

The `-p` flag is useful for checking what was found without needing to open the file tags.

### Synced lyrics (with timestamps)

Set `synced: true` and `keep_synced: true` in your config to prefer synced/timed lyrics (`[MM:SS.xx]` format) from LRCLib. This gives you timed lyrics that scroll in sync with the music in compatible players:

```yaml
lyrics:
    synced: true       # Fetch synced lyrics when available
    keep_synced: true  # Don't overwrite tracks that already have synced lyrics
```

### Importing existing .lrc sidecar files

If you already have `.lrc` files sitting next to your audio files, use the `embed-lrc.sh` script to embed them into the file tags so beets knows about them too:

```bash
./embed-lrc.sh                    # Embed all .lrc files in the library
./embed-lrc.sh --dry-run          # Preview only
./embed-lrc.sh --force            # Overwrite existing lyrics tags with .lrc content
./embed-lrc.sh /path/to/album/    # Specific folder only
```

This preserves the `[MM:SS.xx]` timestamps and then runs `beet update` to sync the database.

### Auto-fetch on import

With `auto: true` (default), the plugin automatically fetches and embeds lyrics for every track during `beet import`. No extra steps needed — just run your normal import workflow and lyrics get added alongside MusicBrainz metadata.

## Adding a new album

```
cp -r /path/to/Album /path/to/import/albums/
cd /path/to/import/
./import.sh      # preprocesses + imports from albums/
./clean.sh       # cleans albums/ folder
```
