#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${USAGEBAR_BUILD_ROOT:-$project_dir/.build}"
mkdir -p "$build_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
compiler="$(xcrun --find swift)"
plugin="$(dirname "$compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
extra=()
# Some Command Line Tools releases bundle Swift Testing but omit plugin discovery.
if [ -f "$plugin" ]; then extra=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
swift test --package-path "$project_dir" --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" --disable-sandbox "${extra[@]}" "$@"
