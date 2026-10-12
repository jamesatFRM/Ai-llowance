#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${USAGEBAR_BUILD_ROOT:-$project_dir/.build}"
mkdir -p "$build_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
compiler="$(xcrun --find swift)"
plugin="$(dirname "$compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
extra=(--disable-sandbox)
# Some Command Line Tools releases bundle Swift Testing but omit plugin discovery.
if [ -f "$plugin" ]; then extra+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
frameworks="$(dirname "$compiler")/../../Library/Developer/Frameworks"
if [ -d "$frameworks/Testing.framework" ]; then
    extra+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi
swift test --package-path "$project_dir" --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" "${extra[@]}" "$@"
