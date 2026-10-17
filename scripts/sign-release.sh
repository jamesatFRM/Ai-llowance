#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${USAGEBAR_OUTPUT_DIR:-$project_dir/dist}"
tag="${1:?Pass the GitHub release tag}"
tooling="$(bash "$project_dir/scripts/fetch-sparkle-tools.sh")"
feed_dir="$(mktemp -d)"
trap 'rm -rf "$feed_dir"' EXIT
# Generate a feed from only the verified DMG, avoiding duplicate ZIP entries.
cp "$output_dir"/*.dmg "$feed_dir/"
args=(--download-url-prefix "https://github.com/jamesatFRM/Ai-llowance/releases/download/$tag/" --link https://github.com/jamesatFRM/Ai-llowance --maximum-deltas 0)
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | swift "$project_dir/scripts/check-update-key.swift" "$project_dir/Resources/update-public-key.txt"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tooling/bin/generate_appcast" --ed-key-file - "${args[@]}" "$feed_dir"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tooling/bin/sign_update" --ed-key-file - --verify "$feed_dir/appcast.xml"
else
    "$tooling/bin/generate_appcast" --account Ai-llowance "${args[@]}" "$feed_dir"
    "$tooling/bin/sign_update" --account Ai-llowance --verify "$feed_dir/appcast.xml"
fi
python3 "$project_dir/scripts/check-update-feed.py" "$feed_dir/appcast.xml" "$output_dir" "$tag"
cp "$feed_dir/appcast.xml" "$output_dir/appcast.xml"
