#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${USAGEBAR_BUILD_ROOT:-$project_dir/.build}"
output_dir="${USAGEBAR_OUTPUT_DIR:-$project_dir/dist}"
version="$(cat "$project_dir/VERSION")"
build_number="${USAGEBAR_BUILD_NUMBER:-200}"
identity="${USAGEBAR_SIGNING_IDENTITY:--}"
if [ "$identity" != "-" ]; then
    # A production signing request must never fall back to ad-hoc signing.
    python3 - "$identity" <<'PY2'
import subprocess,sys
identity=sys.argv[1]
if not identity.startswith('Developer ID Application: '):
    raise SystemExit('Use the complete Developer ID Application identity name for distribution signing.')
available=subprocess.check_output(['security','find-identity','-v','-p','codesigning'],text=True)
if '"'+identity+'"' not in available:
    raise SystemExit('The requested Developer ID Application identity and private key are not available in the Keychain.')
PY2
fi
if [ -n "${USAGEBAR_NOTARY_PROFILE:-}" ] || [ "${USAGEBAR_REQUIRE_NOTARIZATION:-0}" = "1" ]; then
    bash "$project_dir/scripts/notarize-release.sh" --check-config
fi
mkdir -p "$build_dir" "$output_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-cache"
extra=(--disable-sandbox)
if [ -n "${USAGEBAR_BUILD_SYSTEM:-}" ]; then extra+=(--build-system "$USAGEBAR_BUILD_SYSTEM"); fi
architectures="${USAGEBAR_ARCHITECTURES:-$(uname -m)}"
for architecture in $architectures; do
    swift build --package-path "$project_dir" --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" "${extra[@]}" --arch "$architecture" -c release
    binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" --cache-path "$build_dir/package-cache" "${extra[@]}" --arch "$architecture" -c release --show-bin-path)"
    mkdir -p "$build_dir/slices/$architecture"
    cp "$binary_dir/UsageBar" "$binary_dir/UsageBridge" "$build_dir/slices/$architecture/"
done
app_dir="$output_dir/Ai-llowance.app"
# Only replace the generated output bundle, never an installed application.
if [ -d "$app_dir" ]; then rm -rf "$app_dir"; fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
for binary in UsageBar UsageBridge; do
    slices=()
    for architecture in $architectures; do slices+=("$build_dir/slices/$architecture/$binary"); done
    if [ "${#slices[@]}" -gt 1 ]; then lipo -create "${slices[@]}" -output "$app_dir/Contents/MacOS/$binary"
    else cp "${slices[0]}" "$app_dir/Contents/MacOS/$binary"; fi
done
framework="$(python3 - "$build_dir" <<'PY2'
from pathlib import Path
import sys
matches=list((Path(sys.argv[1])/'artifacts').glob('**/macos*/Sparkle.framework'))
if len(matches)!=1: raise SystemExit('Expected one pinned Sparkle framework')
print(matches[0])
PY2
)"
ditto "$framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
codesign --verify --deep --strict "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$project_dir/Resources/UsageBar.icns" "$project_dir/Resources/Claude.png" "$project_dir/Resources/ChatGPT.png" "$app_dir/Contents/Resources/"
cp "$project_dir/LICENSE" "$project_dir/THIRD_PARTY_NOTICES.md" "$project_dir/PRIVACY.md" "$app_dir/Contents/Resources/"
/usr/bin/strip -S "$app_dir/Contents/MacOS/UsageBar" "$app_dir/Contents/MacOS/UsageBridge"
# SwiftPM may add build-machine framework search paths. Keep only portable paths.
python3 - "$app_dir/Contents/MacOS/UsageBar" <<'PY2'
import subprocess,sys,re
p=sys.argv[1]
rpaths=re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+) \(offset',subprocess.check_output(['otool','-l',p],text=True))
for path in dict.fromkeys(rpaths):
    if path.startswith('/') and not path.startswith(('/usr/lib','/System/Library')):
        subprocess.run(['install_name_tool','-delete_rpath',path,p],check=True)
PY2
python3 - "$app_dir" "$version" "$build_number" "$project_dir/Resources/update-public-key.txt" <<'PY2'
import pathlib,plistlib,sys,base64,re
app,version,build,keyfile=sys.argv[1:]
key=pathlib.Path(keyfile).read_text().strip()
assert len(base64.b64decode(key,validate=True))==32
assert re.fullmatch(r'\d+\.\d+\.\d+',version) and re.fullmatch(r'\d+',build)
info=dict(CFBundleIdentifier='com.usagebar.app',CFBundleName='Ai-llowance',CFBundleDisplayName='Ai-llowance',CFBundleExecutable='UsageBar',CFBundleIconFile='UsageBar',CFBundlePackageType='APPL',CFBundleShortVersionString=version,CFBundleVersion=build,LSMinimumSystemVersion='14.0',LSUIElement=True,NSHighResolutionCapable=True,
    SUFeedURL='https://github.com/jamesatFRM/Ai-llowance/releases/download/update-feed/appcast.xml',SUPublicEDKey=key,SUEnableAutomaticChecks=True,SUAutomaticallyUpdate=False,SUEnableSystemProfiling=False,SUScheduledCheckInterval=86400,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0)
pathlib.Path(app,'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY2
if [ "$identity" = "-" ]; then
    codesign --force --sign - "$app_dir/Contents/MacOS/UsageBridge"
    codesign --force --sign - "$app_dir"
else
    # Sign inside out. --deep is for verification, not signing. Sparkle's
    # Downloader retains its upstream entitlements, as its signing guide requires.
    sparkle="$app_dir/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Versions/B/Autoupdate"
    codesign --force --sign "$identity" --options runtime --timestamp "$sparkle/Versions/B/Updater.app"
    codesign --force --sign "$identity" --options runtime --timestamp "$sparkle"
    codesign --force --sign "$identity" --options runtime --timestamp "$app_dir/Contents/MacOS/UsageBridge"
    codesign --force --sign "$identity" --options runtime --timestamp "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
echo "Built app: $app_dir"
