#!/usr/bin/env bash
# Publish a built macOS image (ISO/DMG/recovery zip) to the GitHub Container
# Registry (GHCR) and create a thin GitHub Release whose only asset is a tiny
# `download.sh`.
#
# Why: GitHub Release assets are capped at 2 GiB per file, so large images had
# to be split into many pieces. GHCR allows up to 10 GB per layer, so the image
# is chunked into CHUNK_LIMIT-sized raw byte parts and pushed as ONE OCI
# artifact under a per-macOS-version package, e.g.
# `ghcr.io/<owner>/macos-tahoe:<tag>` (ISO/DMG and Recovery for one version
# share that package, distinguished by tag).
#
# The heavy bytes never touch GitHub Releases. The generated `download.sh`
# pulls every part straight from the registry API with plain curl (no
# docker/oras/login needed for public packages), merges them locally and
# verifies the SHA-256, so the result is byte-identical to the built image.
#
# Features:
#   * 1 GiB parts, fetched concurrently by download.sh (curl --parallel) with
#     fine-grained resume of an interrupted run (curl -C -)
#   * optional transfer compression: COMPRESS=zstd|gzip (default: none, so the
#     download stays curl-only; zstd needs to be installed on the user machine)
#   * optional keyless cosign signature (best effort; needs id-token: write)
#   * updates a rolling `catalog` release with a machine-readable catalog.json
#
# NOTE: a package whose name differs from the repository is NOT auto-linked, so
# its visibility defaults to private. Set it to Public once (or link it to this
# repository) or anonymous downloads fail with 401.
#
# Usage: publish-ghcr.sh <asset> <package> <tag> <title>
#   e.g. publish-ghcr.sh Tahoe.iso macos-tahoe macos-tahoe-iso-123-1 "macOS Tahoe iso"
# Env:   GH_TOKEN/GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_ACTOR, GITHUB_SHA,
#        GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, COMPRESS (none|zstd|gzip)
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
# 1 GiB parts: many parts means download.sh fetches them concurrently, and a
# failed download only needs to resume a small slice - while staying far below
# GHCR's 10 GB per-layer limit and its ~10 minute upload timeout.
CHUNK_LIMIT=$((1 * 1024 * 1024 * 1024))
# Optional compression of the transfer stream. Unset keeps downloads curl-only.
compress=${COMPRESS:-none}

release_dir=$(mktemp -d)
notes="$release_dir/notes.md"
printf 'Built from commit `%s`.\n' "$GITHUB_SHA" > "$notes"

# ---------------------------------------------------------------------------
# 1) Optionally compress, then split the transfer file into raw chunks.
#    - digest.txt : SHA-256 of the COMPLETE image (used to verify the result)
#    - parts.txt  : one line per chunk: "<name><TAB><sha256><TAB><size>"
# ---------------------------------------------------------------------------
transfer="$asset"
case "$compress" in
    none)
        ;;
    zstd)
        command -v zstd >/dev/null 2>&1 || { echo "ERROR: COMPRESS=zstd but zstd is not installed" >&2; exit 1; }
        transfer="$release_dir/image.zst"
        echo "Compressing with zstd (level ${ZSTD_LEVEL:-6})..."
        zstd -T0 -q -f "-${ZSTD_LEVEL:-6}" -o "$transfer" "$asset"
        ;;
    gzip)
        command -v gzip >/dev/null 2>&1 || { echo "ERROR: COMPRESS=gzip but gzip is not installed" >&2; exit 1; }
        transfer="$release_dir/image.gz"
        echo "Compressing with gzip..."
        gzip -9 -c "$asset" > "$transfer"
        ;;
    *)
        echo "ERROR: unknown COMPRESS='$compress' (use none|zstd|gzip)" >&2
        exit 1
        ;;
esac

python3 - "$transfer" "$asset" "$release_dir" "$CHUNK_LIMIT" <<'PY'
import hashlib
import pathlib
import shutil
import sys

source = pathlib.Path(sys.argv[1])        # file that gets transferred
original = pathlib.Path(sys.argv[2])      # image the user ends up with
destination = pathlib.Path(sys.argv[3])
limit = int(sys.argv[4])

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

def copy_and_hash(read_stream, part_path, limit):
    """Copy at most `limit` raw bytes from read_stream to part_path."""
    digest = hashlib.sha256()
    size = 0
    remaining = limit
    with part_path.open('wb') as out:
        while remaining > 0:
            block = read_stream.read(min(8 * 1024 * 1024, remaining))
            if not block:
                break
            out.write(block)
            digest.update(block)
            size += len(block)
            remaining -= len(block)
    return digest.hexdigest(), size

parts = []
if source.stat().st_size <= limit:
    part_path = destination / source.name
    shutil.copy2(source, part_path)
    parts.append((source.name, sha256(part_path), part_path.stat().st_size))
else:
    index = 1
    with source.open('rb') as stream:
        while stream.tell() < source.stat().st_size:
            part_path = destination / f'p{index:03d}'
            digest, size = copy_and_hash(stream, part_path, limit)
            parts.append((part_path.name, digest, size))
            index += 1

(destination / 'digest.txt').write_text(sha256(original) + '\n')
with (destination / 'parts.txt').open('w') as manifest:
    for name, part_digest, size in parts:
        manifest.write(f'{name}\t{part_digest}\t{size}\n')
PY

main_digest=$(<"$release_dir/digest.txt")
part_names=()
part_digests=()
while IFS=$'\t' read -r name part_digest part_size; do
    part_names+=("$name")
    part_digests+=("$part_digest")
done < "$release_dir/parts.txt"

if [ ${#part_names[@]} -eq 0 ]; then
    echo "ERROR: no parts produced from $asset" >&2
    exit 1
fi

echo "asset=$asset_name"
echo "parts=${#part_names[@]} part-size=${CHUNK_LIMIT} bytes compress=$compress"
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
    oras push \
        --artifact-type application/vnd.macos-builder.image.v1 \
        --annotation "org.opencontainers.image.title=${asset_name}" \
        --annotation "org.opencontainers.image.version=${tag}" \
        --annotation "org.opencontainers.image.revision=${GITHUB_SHA}" \
        "ghcr.io/${image_ref}" "${part_names[@]}"
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

# ---------------------------------------------------------------------------
# 3) Optional keyless cosign signature (best effort). Never block a release on
#    it; a missing/unreachable transparency log should not lose the image.
# ---------------------------------------------------------------------------
signed=0
if command -v cosign >/dev/null 2>&1; then
    if cosign sign --yes "ghcr.io/${image_ref}"; then
        echo "signed ghcr.io/${image_ref} with cosign (keyless)"
        signed=1
    else
        echo "::warning::cosign signing failed; release continues unsigned"
    fi
else
    echo "cosign not installed; skipping signature"
fi

# ---------------------------------------------------------------------------
# 4) Generate `download.sh` - runnable on the user's machine with ONLY
#    curl + sha256sum/shasum (plus zstd/gzip when COMPRESS is enabled).
#    It pulls each chunk by digest from the GHCR registry API, concatenates
#    them and verifies the full image's SHA-256.
# ---------------------------------------------------------------------------
python3 - "$release_dir/download.sh" "$asset_name" "$package_path" "$main_digest" "$release_dir/parts.txt" "$compress" <<'PY'
import pathlib
import shlex
import sys

script_path = pathlib.Path(sys.argv[1])
name = sys.argv[2]
repo = sys.argv[3]
main_digest = sys.argv[4]
parts_path = pathlib.Path(sys.argv[5])
compress = sys.argv[6]

parts = []
with parts_path.open() as manifest:
    for line in manifest:
        part_name, part_digest, part_size = line.rstrip('\n').split('\t')
        parts.append((part_name, part_digest, int(part_size)))

num_parts = len(parts)
plural = 's' if num_parts != 1 else ''
quote = shlex.quote
work_id = main_digest[:12] if compress == 'none' else f'{main_digest[:12]}-{compress}'

lines = [
    '#!/usr/bin/env bash',
    '# Generated by publish-ghcr.sh - downloads the image from GHCR with curl.',
    'set -euo pipefail',
    '',
    f'name={quote(name)}',
    '[ ! -e "$name" ] || { echo "Output already exists: $name" >&2; exit 1; }',
    '',
    '# Partial parts live here between runs so an interrupted download resumes.',
    '# The directory is keyed by the image digest, so parts from a different',
    '# build are never mixed in.',
    f'work="$PWD/.macos-download-{work_id}"',
    'mkdir -p -- "$work"',
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
    f'printf "Fetching {num_parts} part{plural} of $name from GHCR...\\n"',
    '',
    '# "<name>|<digest>|<size>" for every part.',
    'parts=(',
]
for part_name, part_digest, part_size in parts:
    lines.append(f'  {quote(f"{part_name}|{part_digest}|{part_size}")}')
lines += [
    ')',
    '',
    '# Work out which parts still need bytes; complete parts are skipped and',
    '# partial ones are resumed with curl -C -.',
    'pending=()',
    'for entry in "${parts[@]}"; do',
    '  IFS="|" read -r pname pdigest psize <<< "$entry"',
    '  dest="$work/$pname"',
    '  url="https://ghcr.io/v2/${repo}/blobs/sha256:${pdigest}"',
    '  resume=0',
    '  if [ -f "$dest" ]; then',
    '    cur=$(wc -c < "$dest" | tr -d " ")',
    '    if [ "$cur" -eq "$psize" ]; then',
    '      continue',
    '    fi',
    '    if [ "$cur" -gt "$psize" ]; then',
    '      rm -f -- "$dest"',
    '    else',
    '      resume=1',
    '    fi',
    '  fi',
    '  pending+=("$dest|$url|$resume")',
    'done',
    '',
    'if [ "${#pending[@]}" -gt 0 ]; then',
    '  if curl --parallel --version >/dev/null 2>&1; then',
    '    args=(--fail --location --retry 3 --retry-all-errors -H "Authorization: Bearer $token" --parallel --parallel-max 6)',
    '    for entry in "${pending[@]}"; do',
    '      IFS="|" read -r dest url resume <<< "$entry"',
    '      if [ "$resume" = 1 ]; then',
    '        args+=(-C - -o "$dest" "$url")',
    '      else',
    '        args+=(-o "$dest" "$url")',
    '      fi',
    '    done',
    '    curl "${args[@]}"',
    '  else',
    '    for entry in "${pending[@]}"; do',
    '      IFS="|" read -r dest url resume <<< "$entry"',
    '      if [ "$resume" = 1 ]; then',
    '        curl --fail --location --retry 3 --retry-all-errors -H "Authorization: Bearer $token" -C - -o "$dest" "$url"',
    '      else',
    '        curl --fail --location --retry 3 --retry-all-errors -H "Authorization: Bearer $token" -o "$dest" "$url"',
    '      fi',
    '    done',
    '  fi',
    'fi',
    '',
    'cat ' + ' '.join(f'"$work"/{quote(part_name)}' for part_name, _, _ in parts) + ' > "$work/transfer"',
    '',
]
if compress == 'zstd':
    lines += [
        'command -v zstd >/dev/null 2>&1 || { echo "This build is zstd-compressed; please install zstd." >&2; exit 1; }',
        'zstd -d -q -f -o "$work/image" "$work/transfer"',
        'img="$work/image"',
    ]
elif compress == 'gzip':
    lines += [
        'command -v gzip >/dev/null 2>&1 || { echo "This build is gzip-compressed; please install gzip." >&2; exit 1; }',
        'gzip -dc "$work/transfer" > "$work/image"',
        'img="$work/image"',
    ]
else:
    lines += ['img="$work/transfer"']
lines += [
    '',
    'if command -v sha256sum >/dev/null 2>&1; then',
    '  actual=$(sha256sum "$img"); actual=${actual%% *}',
    'else',
    '  actual=$(shasum -a 256 "$img"); actual=${actual%% *}',
    'fi',
    f'[ "$actual" = {quote(main_digest)} ] || {{ echo "SHA-256 mismatch (discarding partial download)" >&2; rm -rf -- "$work"; exit 1; }}',
    'mv -n -- "$img" "$name"',
    '[ ! -e "$img" ] || { echo "Output already exists: $name" >&2; exit 1; }',
    'rm -rf -- "$work"',
    'printf "Downloaded and verified: %s\\n" "$name"',
    '',
]
script_path.write_text('\n'.join(lines) + '\n')
script_path.chmod(0o755)
PY

# ---------------------------------------------------------------------------
# 5) Thin GitHub Release: ONLY download.sh + notes with the one-liner.
# ---------------------------------------------------------------------------
command="curl -fsSL https://github.com/${repo}/releases/download/${tag}/download.sh | bash"
part_word="parts"
[ "${#part_names[@]}" -eq 1 ] && part_word="part"
{
  printf '\nDownload, merge all parts locally, and verify SHA-256 (Linux/macOS; curl and sha256sum/shasum required):\n\n```bash\n%s\n```\n' "$command"
  printf '\nThe image was not uploaded as Release assets: it lives on **GitHub Container Registry** (`ghcr.io/%s`), split into **%s %s** (each < 10 GB). `download.sh` pulls them, merges them, and verifies the SHA-256.\n' "$image_ref" "${#part_names[@]}" "$part_word"
  if [ "$compress" != "none" ]; then
    printf '\nParts are **%s-compressed** on the wire to save bandwidth; `download.sh` decompresses them automatically (requires `%s` locally).\n' "$compress" "$compress"
  fi
  printf '\nSHA-256 (`%s`): `%s`\n' "$asset_name" "$main_digest"
  if [ "$signed" = "1" ]; then
    printf '\nThe artifact is signed with [cosign](https://docs.sigstore.dev/) (keyless). Verify it with:\n\n```bash\ncosign verify ghcr.io/%s \\\n  --certificate-identity-regexp "^https://github.com/%s/" \\\n  --certificate-oidc-issuer https://token.actions.githubusercontent.com\n```\n' "$image_ref" "$repo"
  fi
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

# ---------------------------------------------------------------------------
# 6) Refresh the rolling `catalog` release with a machine-readable index of
#    every build. Kept best effort: a catalog hiccup must not fail the release.
# ---------------------------------------------------------------------------
if [ "$compress" = none ]; then
    transfer_size=$(wc -c < "$asset" | tr -d ' ')
else
    transfer_size=$(wc -c < "$transfer" | tr -d ' ')
fi
asset_size=$(wc -c < "$asset" | tr -d ' ')
(
    catalog_tag=catalog
    catalog_dir=$(mktemp -d)
    catalog_file="$catalog_dir/catalog.json"
    if gh release view "$catalog_tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        gh release download "$catalog_tag" --repo "$GITHUB_REPOSITORY" \
            --pattern catalog.json --dir "$catalog_dir" --clobber >/dev/null 2>&1 || true
    fi
    ENTRY_NAME="$asset_name" ENTRY_PACKAGE="$package_path" ENTRY_TAG="$tag" \
    ENTRY_SHA="$main_digest" ENTRY_PARTS="${#part_names[@]}" \
    ENTRY_SIZE="$asset_size" ENTRY_TRANSFER_SIZE="$transfer_size" \
    ENTRY_COMPRESS="$compress" ENTRY_RELEASE_URL="$release_url" \
    python3 - "$catalog_file" <<'PY'
import datetime
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if path.exists():
    try:
        data = json.loads(path.read_text())
    except ValueError:
        data = []
else:
    data = []
if not isinstance(data, list):
    data = []
entry = {
    'name': os.environ['ENTRY_NAME'],
    'package': os.environ['ENTRY_PACKAGE'],
    'tag': os.environ['ENTRY_TAG'],
    'sha256': os.environ['ENTRY_SHA'],
    'parts': int(os.environ['ENTRY_PARTS']),
    'size': int(os.environ['ENTRY_SIZE']),
    'transfer_size': int(os.environ['ENTRY_TRANSFER_SIZE']),
    'compression': os.environ['ENTRY_COMPRESS'],
    'release_url': os.environ['ENTRY_RELEASE_URL'],
    'created': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
}
data = [row for row in data if row.get('tag') != entry['tag']]
data.insert(0, entry)
path.write_text(json.dumps(data, indent=2) + '\n')
PY
    if gh release view "$catalog_tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        gh release upload "$catalog_tag" "$catalog_file" --repo "$GITHUB_REPOSITORY" --clobber
    else
        gh release create "$catalog_tag" "$catalog_file" \
            --repo "$GITHUB_REPOSITORY" \
            --target "$GITHUB_SHA" \
            --title "Build catalog" \
            --latest=false \
            --notes "Machine-readable index of every build published to GHCR. Refreshed on each build."
    fi
    rm -rf -- "$catalog_dir"
) || echo "::warning::failed to update the 'catalog' release"
