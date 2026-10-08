#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${USAGEBAR_OUTPUT_DIR:-$project_dir/dist}"
bash "$project_dir/scripts/build-app.sh"
app_dir="$output_dir/Ai-llowance.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
architecture=$(uname -m)
archive="Ai-llowance-${version}-macOS-${architecture}.zip"
/usr/bin/codesign --verify --deep --strict "$app_dir"
/usr/bin/ditto -c -k --norsrc --keepParent "$app_dir" "$output_dir/$archive"
python3 "$project_dir/scripts/check-release.py" "$output_dir/$archive"
(cd "$output_dir" && /usr/bin/shasum -a 256 "$archive" > SHA256SUMS)
echo "Packaged preview: $output_dir/$archive"
