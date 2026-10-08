#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${USAGEBAR_BUILD_ROOT:-$project_dir/.build}"
output_dir="${USAGEBAR_OUTPUT_DIR:-$project_dir/dist}"
mkdir -p "$build_dir" "$output_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
swift build --package-path "$project_dir" --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" --disable-sandbox -c release
binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" --disable-sandbox -c release --show-bin-path)"
app_dir="$output_dir/UsageBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/UsageBar" "$app_dir/Contents/MacOS/UsageBar"
cp "$binary_dir/UsageBridge" "$app_dir/Contents/MacOS/UsageBridge"
cp "$project_dir/Resources/UsageBar.icns" "$app_dir/Contents/Resources/UsageBar.icns"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/Resources/Claude.png" "$project_dir/Resources/ChatGPT.png" "$app_dir/Contents/Resources/"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
# Keep debug paths and symbols out of public binaries; sign after stripping.
/usr/bin/strip -S "$app_dir/Contents/MacOS/UsageBar" "$app_dir/Contents/MacOS/UsageBridge"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.usagebar.app</string>
  <key>CFBundleName</key><string>UsageBar</string>
  <key>CFBundleDisplayName</key><string>UsageBar</string>
  <key>CFBundleExecutable</key><string>UsageBar</string>
  <key>CFBundleIconFile</key><string>UsageBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir/Contents/MacOS/UsageBridge"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "Built local preview: $app_dir"
