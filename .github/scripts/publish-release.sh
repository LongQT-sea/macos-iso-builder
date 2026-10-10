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
python3 - "$asset" "$release_dir" "$GITHUB_REPOSITORY" "$tag" <<'PY'
import hashlib
import pathlib
import shlex
import urllib.parse
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
digest = hashlib.sha256()
with source.open('rb') as stream:
    for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
        digest.update(block)
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
# Pin every URL and checksum to this release, including the helper itself.
base_url = f'https://github.com/{sys.argv[3]}/releases/download/{urllib.parse.quote(sys.argv[4], safe="")}'
files = sorted(path.name for path in destination.iterdir() if path.name != 'notes.md')
quote = shlex.quote
lines = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    f'name={quote(source.name)}',
    '[ ! -e "$name" ] || { echo "Output already exists: $name" >&2; exit 1; }',
    'work=$(mktemp -d "./.macos-download.XXXXXX")',
    "trap 'rm -rf -- \"$work\"' EXIT",
]
for name in files:
    url = base_url + '/' + urllib.parse.quote(name, safe='')
    lines.append(f'curl --fail --location --retry 3 --output "$work"/{quote(name)} {quote(url)}')
parts = ' '.join('"$work"/' + quote(name) for name in files)
lines += [
    f'cat {parts} > "$work/image"',
    'if command -v sha256sum >/dev/null 2>&1; then',
    '  actual=$(sha256sum "$work/image"); actual=${actual%% *}',
    'else',
    '  actual=$(shasum -a 256 "$work/image"); actual=${actual%% *}',
    'fi',
    f'[ "$actual" = {quote(digest.hexdigest())} ] || {{ echo "SHA-256 mismatch" >&2; exit 1; }}',
    'mv -n -- "$work/image" "$name"',
    '[ ! -e "$work/image" ] || { echo "Output already exists: $name" >&2; exit 1; }',
    'printf "Downloaded and verified: %s\\n" "$name"',
]
(destination / 'download.sh').write_text('\n'.join(lines) + '\n')
command = f'curl -fsSL {quote(base_url + "/download.sh")} | bash'
with (destination / 'notes.md').open('a') as notes:
    notes.write('\nDownload, combine all parts, verify SHA-256, and remove temporary split files (Linux/macOS; Bash and curl required):\n\n```bash\n' + command + '\n```\n')
    notes.write(f'\nSHA-256 (`{source.name}`): `{digest.hexdigest()}`\n')
    if source.name.endswith('.zip'):
        notes.write('\nUnzip the downloaded archive before use.\n')
PY

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
