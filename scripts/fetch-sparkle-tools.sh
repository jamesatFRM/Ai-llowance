#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
tooling="${USAGEBAR_BUILD_ROOT:-$project_dir/.build}/sparkle-tools"
mkdir -p "$tooling"
if [ ! -x "$tooling/bin/generate_appcast" ]; then
    curl --fail --location --silent --show-error https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz -o "$tooling/Sparkle.tar.xz"
    python3 - "$tooling/Sparkle.tar.xz" <<'PY2'
import hashlib,pathlib,sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() == 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c', 'Sparkle tool archive checksum mismatch'
PY2
    tar -xJf "$tooling/Sparkle.tar.xz" -C "$tooling"
fi
printf '%s\n' "$tooling"
