#!/usr/bin/env bash
# Experimental GHCR publish flow.
#
# The heavy image (ISO/DMG, up to ~18 GB) does NOT go to GitHub Releases.
# Instead it is chunked into raw byte parts of at most CHUNK_LIMIT bytes and
# pushed to the GitHub Container Registry as ONE OCI artifact under a
# per-macOS-version package, e.g. `ghcr.io/<owner>/macos-tahoe:<tag>` (ISO/DMG
# and Recovery for one version share that package, distinguished by tag).
# GHCR has a 10 GB per-layer limit and a ~10 minute upload timeout, so parts
# are kept below that (5 GiB): fewer parts than the 2 GiB limit Releases
# imposes, and a safer upload.
#
# The GitHub Release created here is "thin": its only asset is a tiny
# `download.sh` that fetches the parts from GHCR with plain curl (works for
# every public package WITHOUT docker/oras/login on the user's machine),
# merges them locally (`cat part... > image`) and verifies the SHA-256. The
# merged result is byte-identical to the ISO/DMG built on the runner.
#
# NOTE: a package whose name differs from the repository is NOT auto-linked,
# so its visibility defaults to private. Set it to Public once (or link it to
# this repository) or anonymous downloads will fail with 401.
#
# Usage: publish-ghcr.sh <asset> <package> <tag> <title>
#   e.g. publish-ghcr.sh Tahoe.iso macos-tahoe macos-tahoe-iso-123-1 "macOS Tahoe iso"
# Env:   GH_TOKEN/GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_ACTOR, GITHUB_SHA,
#        GITHUB_OUTPUT, GITHUB_STEP_SUMMARY
set -euo pipefail

asset=$1
package=$2
tag=$3
title=$4

# NOTE: bash on the macOS runner is 3.2 - no ${var,,}; lowercase via tr.
repo=$(printf '%s' "${GITHUB_REPOSITORY}" | tr '[:upper:]' '[:lower:]')
owner=${repo%%/*}
package_path="${owner}/${package}"
image_ref="${package_path}:${tag}"
asset_name=$(basename "$asset")
CHUNK_LIMIT=$((5 * 1024 * 1024 * 1024)) # 5 GiB, well under GHCR's 10 GB/layer

release_dir=$(mktemp -d)
notes="$release_dir/notes.md"
printf 'Built from commit `%s`.\n' "$GITHUB_SHA" > "$notes"

# ---------------------------------------------------------------------------
# 1) Split the asset into raw chunks (exact byte copy), computing:
#    - digest.txt : SHA-256 of the complete asset
#    - parts.txt  : one line per chunk: "<filename><TAB><sha256-of-chunk>"
# ---------------------------------------------------------------------------
python3 - "$asset" "$release_dir" "$CHUNK_LIMIT" <<'PY'
import hashlib
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
limit = int(sys.argv[3])

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

def copy_and_hash(read_stream, part_path, limit):
    """Copy at most `limit` raw bytes from read_stream to part_path."""
    digest = hashlib.sha256()
    remaining = limit
    with part_path.open('wb') as out:
        while remaining > 0:
            block = read_stream.read(min(8 * 1024 * 1024, remaining))
            if not block:
                break
            out.write(block)
            digest.update(block)
            remaining -= len(block)
    return digest.hexdigest()

parts = []
if source.stat().st_size <= limit:
    part_path = destination / source.name
    shutil.copy2(source, part_path)
    parts.append((source.name, sha256(part_path)))
else:
    index = 1
    with source.open('rb') as stream:
        while stream.tell() < source.stat().st_size:
            part_path = destination / f'p{index:03d}'
            parts.append((part_path.name, copy_and_hash(stream, part_path, limit)))
            index += 1

(destination / 'digest.txt').write_text(sha256(source) + '\n')
with (destination / 'parts.txt').open('w') as manifest:
    for name, part_digest in parts:
        manifest.write(f'{name}\t{part_digest}\n')
PY

main_digest=$(<"$release_dir/digest.txt")
part_names=()
part_digests=()
while IFS=$'\t' read -r name part_digest; do
    part_names+=("$name")
    part_digests+=("$part_digest")
done < "$release_dir/parts.txt"

if [ ${#part_names[@]} -eq 0 ]; then
    echo "ERROR: no parts produced from $asset" >&2
    exit 1
fi

echo "asset=$asset_name"
echo "parts=${#part_names[@]} part-size=${CHUNK_LIMIT} bytes"
echo "sha256=$main_digest"

# ---------------------------------------------------------------------------
# 2) Push the chunks to GHCR with oras (installed as a workflow step).
#    Every chunk becomes one layer/blob; a blob's digest is the sha256 of its
#    bytes, so the download script can fetch each chunk straight from the
#    registry API by digest - no manifest parsing needed at runtime.
# ---------------------------------------------------------------------------
oras login ghcr.io --username "${GITHUB_ACTOR}" --password-stdin <<< "${GH_TOKEN:-${GITHUB_TOKEN}}"
(
    cd "$release_dir"
    oras push --artifact-type application/vnd.macos-builder.image.v1 "ghcr.io/${image_ref}" "${part_names[@]}"
)

# Verify every chunk was stored uncompressed with the exact digest we computed.
# (If oras ever started compressing blobs, the download URLs would 404 - fail
# loudly here instead of shipping a broken release.)
manifest=$(oras manifest fetch "ghcr.io/${image_ref}")
for part_digest in "${part_digests[@]}"; do
    case "$manifest" in
        *"sha256:${part_digest}"*) ;;
        *) echo "ERROR: blob sha256:${part_digest} missing from pushed manifest" >&2; exit 1 ;;
    esac
done
echo "verified: ${#part_digests[@]} blob(s) present in ghcr.io/${image_ref}"

# TODO(experiment): GC old versions of this GHCR package. GITHUB_TOKEN cannot
# delete package versions; use a PAT with delete:packages in a scheduled job.

# ---------------------------------------------------------------------------
# 3) Generate `download.sh` - runnable on the user's machine with ONLY
#    curl + sha256sum/shasum. It pulls each chunk by digest from the GHCR
#    registry API, concatenates them and verifies the full asset's SHA-256.
# ---------------------------------------------------------------------------
python3 - "$release_dir/download.sh" "$asset_name" "$package_path" "$main_digest" "$release_dir/parts.txt" <<'PY'
import pathlib
import shlex
import sys

script_path = pathlib.Path(sys.argv[1])
name = sys.argv[2]
repo = sys.argv[3]
main_digest = sys.argv[4]
parts_path = pathlib.Path(sys.argv[5])

parts = []
with parts_path.open() as manifest:
    for line in manifest:
        part_name, part_digest = line.rstrip('\n').split('\t')
        parts.append((part_name, part_digest))

num_parts = len(parts)
plural = 's' if num_parts != 1 else ''
quote = shlex.quote

lines = [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    '',
    f'name={quote(name)}',
    '[ ! -e "$name" ] || { echo "Output already exists: $name" >&2; exit 1; }',
    'work=$(mktemp -d "./.macos-download.XXXXXX")',
    "trap 'rm -rf -- \"$work\"' EXIT",
    '',
    f'repo={quote(repo)}',
    '# Anonymous pull token works for public GHCR packages; falls back to an',
    '# optional GITHUB_TOKEN/GH_TOKEN env var for private packages.',
    'token_json=$(curl -fsSL --retry 3 --retry-all-errors \\',
    '  "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull") \\',
    '  || token_json=""',
    'token=$(printf \'%s\' "$token_json" | sed -n \'s/.*"token":"\\([^"]*\\)".*/\\1/p\')',
    'if [ -z "$token" ] && [ -n "${GITHUB_TOKEN:-}" ]; then',
    '  token_json=$(curl -fsSL --retry 3 --retry-all-errors \\',
    '    -u "x-access-token:${GITHUB_TOKEN}" \\',
    '    "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull")',
    '  token=$(printf \'%s\' "$token_json" | sed -n \'s/.*"token":"\\([^"]*\\)".*/\\1/p\')',
    'fi',
    '[ -n "$token" ] || { echo "Failed to get GHCR pull token" >&2; exit 1; }',
    '',
    f'printf "Pulling {num_parts} part{plural} of $name from GHCR...\\n"',
    '',
]

for part_name, part_digest in parts:
    blob_url = f'https://ghcr.io/v2/{repo}/blobs/sha256:{part_digest}'
    lines.append(f'curl --fail --location --retry 3 --retry-all-errors -H "Authorization: Bearer $token" \\')
    lines.append(f'  -o "$work"/{quote(part_name)} {quote(blob_url)}')

merged_parts = ' '.join(f'"$work"/{quote(part_name)}' for part_name, _ in parts)
lines += [
    '',
    f'cat {merged_parts} > "$work/image"',
    'if command -v sha256sum >/dev/null 2>&1; then',
    '  actual=$(sha256sum "$work/image"); actual=${actual%% *}',
    'else',
    '  actual=$(shasum -a 256 "$work/image"); actual=${actual%% *}',
    'fi',
    f'[ "$actual" = {quote(main_digest)} ] || {{ echo "SHA-256 mismatch" >&2; exit 1; }}',
    'mv -n -- "$work/image" "$name"',
    '[ ! -e "$work/image" ] || { echo "Output already exists: $name" >&2; exit 1; }',
    'printf "Downloaded and verified: %s\\n" "$name"',
    '',
]
script_path.write_text('\n'.join(lines) + '\n')
script_path.chmod(0o755)
PY

# ---------------------------------------------------------------------------
# 4) Thin GitHub Release: ONLY download.sh + notes with the one-liner.
# ---------------------------------------------------------------------------
command="curl -fsSL https://github.com/${repo}/releases/download/${tag}/download.sh | bash"
part_word="parts"
[ "${#part_names[@]}" -eq 1 ] && part_word="part"
{
  printf '\nDownload, merge all parts locally, and verify SHA-256 (Linux/macOS; curl and sha256sum/shasum required):\n\n```bash\n%s\n```\n' "$command"
  printf '\nThe image was not uploaded as Release assets: it lives on **GitHub Container Registry** (`ghcr.io/%s`), split into **%s %s** (each < 10 GB). `download.sh` pulls them, merges them, and verifies the SHA-256.\n' "$image_ref" "${#part_names[@]}" "$part_word"
  printf '\nSHA-256 (`%s`): `%s`\n' "$asset_name" "$main_digest"
  if [ "${asset_name##*.}" = "zip" ]; then
    printf '\nUnzip the downloaded archive before use.\n'
  fi
} >> "$notes"

chmod +x "$release_dir/download.sh"
gh release create "$tag" "$release_dir/download.sh" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" \
  --title "$title" \
  --notes-file "$notes" \
  --draft=false \
  --prerelease=false

release_url=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json url -q .url)
printf 'release_url=%s\n' "$release_url" >> "$GITHUB_OUTPUT"
printf '\nDownload: one-liner on the [GitHub Release](%s).\n' "$release_url" >> "$GITHUB_STEP_SUMMARY"