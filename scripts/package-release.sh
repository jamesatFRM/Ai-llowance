#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${USAGEBAR_OUTPUT_DIR:-$project_dir/dist}"
build_dir="${USAGEBAR_BUILD_ROOT:-$project_dir/.build}"
(cd "$project_dir" && python3 scripts/check-privacy.py)
bash "$project_dir/scripts/build-app.sh"
app_dir="$output_dir/Ai-llowance.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Contents/Info.plist")
if [ "$(lipo -archs "$app_dir/Contents/MacOS/UsageBar" | wc -w | tr -d ' ')" -gt 1 ]; then architecture=universal; else architecture=$(lipo -archs "$app_dir/Contents/MacOS/UsageBar"); fi
basename="Ai-llowance-${version}-build${build}-macOS-${architecture}"
codesign --verify --deep --strict "$app_dir"
ditto -c -k --norsrc --keepParent "$app_dir" "$output_dir/$basename.zip"
python3 "$project_dir/scripts/check-release.py" "$output_dir/$basename.zip"
tooling="$build_dir/dmg-tools"
if [ ! -f "$tooling/.allowance-tools-ready" ]; then
    python3 -m pip install --disable-pip-version-check --no-deps --require-hashes --target "$tooling" -r "$project_dir/scripts/dmg-requirements.txt"
    touch "$tooling/.allowance-tools-ready"
fi
swift "$project_dir/scripts/make-dmg-background.swift" "$build_dir/dmg-background.png"
cat > "$build_dir/Read me.txt" <<'TXT'
Drag Ai-llowance into Applications, then open it there.

This is an unnotarized preview, not a production release. If macOS blocks the first launch, see Apple's official guidance: https://support.apple.com/102445

Claude Code and/or Codex CLI must be installed for usage readings.
Settings includes Check for Updates. Updates preserve your connected accounts.
TXT
PYTHONPATH="$tooling" python3 -m dmgbuild -s "$project_dir/scripts/dmg-settings.py" -D "app=$app_dir" -D "readme=$build_dir/Read me.txt" -D "background=$build_dir/dmg-background.png" "Ai-llowance $version" "$output_dir/$basename.dmg"
hdiutil verify "$output_dir/$basename.dmg"
python3 "$project_dir/scripts/check-dmg.py" "$output_dir/$basename.dmg"
(cd "$output_dir" && shasum -a 256 "$basename.zip" "$basename.dmg" > SHA256SUMS)
echo "Packaged: $output_dir/$basename.dmg"
