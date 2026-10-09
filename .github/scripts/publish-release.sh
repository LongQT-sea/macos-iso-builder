#!/usr/bin/env bash
set -euo pipefail

asset=$1
tag=$2
title=$3
asset_name=$(basename "$asset")
release_dir=$(mktemp -d)
notes="$release_dir/notes.md"
printf 'Built from commit `%s`.\n' "$GITHUB_SHA" > "$notes"

# Release assets must be smaller than 2 GiB. Use portable Python splitting
# because the macOS runner ships BSD utilities.
python3 - "$asset" "$release_dir" <<'PY'
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
limit = 1900 * 1024 * 1024
if source.stat().st_size <= limit:
    shutil.move(str(source), str(destination / source.name))
else:
    with source.open('rb') as stream:
        index = 1
        while stream.tell() < source.stat().st_size:
            with (destination / f'{source.name}.part{index:03d}').open('wb') as part:
                remaining = limit
                while remaining:
                    block = stream.read(min(8 * 1024 * 1024, remaining))
                    if not block:
                        break
                    part.write(block)
                    remaining -= len(block)
            index += 1
PY

if [ -f "$release_dir/$asset_name.part001" ]; then
  printf '\nDownload all parts into the same folder, then combine them before use:\n\n```bash\ncat "%s".part* > "%s"\n```\n\nWindows (Command Prompt):\n\n```bat\ncopy /b "%s.part*" "%s"\n```\n' \
    "$asset_name" "$asset_name" "$asset_name" "$asset_name" >> "$notes"
fi

assets=()
for file in "$release_dir"/*; do
  [ "$file" = "$notes" ] || assets+=("$file")
done
release_url=$(gh release create "$tag" "${assets[@]}" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" \
  --title "$title" \
  --notes-file "$notes" \
  --draft=false \
  --prerelease=false)
printf 'release_url=%s\n' "$release_url" >> "$GITHUB_OUTPUT"
printf '\nDownload: [GitHub Release](%s)\n' "$release_url" >> "$GITHUB_STEP_SUMMARY"
