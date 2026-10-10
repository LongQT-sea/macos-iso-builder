#!/usr/bin/env bash
# Delete old versions of this repository's GHCR packages, keeping the newest
# KEEP versions of every package. Intended for a scheduled workflow.
#
# GITHUB_TOKEN cannot delete package versions, so this needs a token with the
# `delete:packages` scope (a classic PAT) in the GHCR_GC_TOKEN secret.
#
# Env:
#   GH_TOKEN           (required) PAT with delete:packages
#   GITHUB_REPOSITORY  (required) owner/repo
#   KEEP               versions to keep per package (default 5)
#   DRY_RUN            "1" to only list what would be deleted (default 0)
#   PACKAGE_PREFIX     only touch packages with this prefix (default macos-)
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
owner=${GITHUB_REPOSITORY%%/*}
keep=${KEEP:-5}
dry_run=${DRY_RUN:-0}
prefix=${PACKAGE_PREFIX:-macos-}

# User packages and organization packages live under different endpoints.
owner_type=$(gh api "/users/${owner}" --jq .type 2>/dev/null || echo User)
if [ "$owner_type" = "Organization" ]; then
    base="/orgs/${owner}/packages"
else
    base="/users/${owner}/packages"
fi

echo "owner=${owner} type=${owner_type} keep=${keep} dry_run=${dry_run} prefix=${prefix}"

packages=$(gh api --paginate "${base}?package_type=container&per_page=100" --jq '.[].name' 2>/dev/null || true)
if [ -z "$packages" ]; then
    echo "No container packages found (or the token lacks access)."
    exit 0
fi

total_deleted=0
for package in $packages; do
    case "$package" in
        "${prefix}"*) ;;
        *) continue ;;
    esac

    # Newest first. Output: "<id><TAB><created_at><TAB><comma-separated tags>".
    versions=$(gh api --paginate "${base}/container/${package}/versions?per_page=100" \
        --jq 'sort_by(.created_at) | reverse | .[] | "\(.id)\t\(.created_at)\t\([.metadata.container.tags[]?] | join(","))"' 2>/dev/null || true)
    [ -n "$versions" ] || { echo "${package}: no versions"; continue; }

    count=0
    kept=0
    while IFS=$'\t' read -r version_id created_at tags; do
        [ -n "$version_id" ] || continue
        count=$((count + 1))
        if [ "$count" -le "$keep" ]; then
            kept=$((kept + 1))
            continue
        fi
        if [ "$dry_run" = "1" ]; then
            echo "DRY-RUN ${package}: would delete version ${version_id} (${created_at}) tags='${tags}'"
        else
            if gh api -X DELETE "${base}/container/${package}/versions/${version_id}" >/dev/null 2>&1; then
                echo "deleted ${package}: version ${version_id} (${created_at}) tags='${tags}'"
                total_deleted=$((total_deleted + 1))
            else
                echo "::warning::failed to delete ${package} version ${version_id}" >&2
            fi
        fi
    done <<< "$versions"

    echo "${package}: ${count} version(s), kept ${kept} newest"
done

echo "done (deleted=${total_deleted}, dry_run=${dry_run})"
