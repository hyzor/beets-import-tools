# 🎵 Beets Import Directory

This folder is the staging area for importing music into the beets library at `/media/wdblue/share/Music/`.

## Scripts

| Script | Purpose |
|---|---|
| `preprocess.sh` | Pre-flight check & fix — detects mislabeled files, re-wraps them, tags from filenames |
| `import.sh` | Runs `beet import .` — standard MusicBrainz-autotagged import |
| `clean.sh` | Deletes everything except itself, `import.sh`, and `README.md` — run after successful import |

---

## Full workflow

```bash
cd /media/wdblue/share/import/

# 1. Place album folder(s) here, e.g.:
#    Artist - Album Name/

# 2. Preprocess (optional but recommended — catches common issues)
./preprocess.sh

# 3. Import (auto-tags via MusicBrainz)
./import.sh

# 4. Clean up
./clean.sh
```

### Quick import (when you know files are clean)

```bash
cd /media/wdblue/share/import/
./import.sh
./clean.sh
```

### Import without MusicBrainz (use filenames as tags)

Use when files already have correct internal tags, or when the folder contains non-standard releases that MusicBrainz won't match:

```bash
beet import -A "Artist - Album Name/"
```

The `-A` flag (as-is) skips MusicBrainz lookup and uses whatever metadata the files already have, or derives it from the folder/file names.

---

## Folder naming requirements

Beets expects album folders in `/media/wdblue/share/import/` following this pattern:

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

This script is the main defense against failed imports. It scans every album folder and:

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
./preprocess.sh                    # process all folders
./preprocess.sh --dry-run          # preview only, no changes
./preprocess.sh "Album Folder/"    # process specific folder
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

**Likely cause**: A previous import created entries from untagged files (e.g. from a failed test run). The orphan files end up in `/media/wdblue/share/Music/__/`.

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
| **Music directory** | `/media/wdblue/share/Music/` |
| **Database** | `~/beets/library.db` |
| **Import mode** | `move: yes` (files are moved, not copied) |
| **Plugins** | `musicbrainz` (autotagging) |
| **MusicBrainz search** | Limit: 5, no ASCII query conversion |
| **Staging area** | `/media/wdblue/share/import/` |

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

## Adding a new album

```
cp -r /path/to/Album /media/wdblue/share/import/
cd /media/wdblue/share/import/
./preprocess.sh
./import.sh
./clean.sh
```
