#!/usr/bin/env python3
"""Check release contents without printing any potentially sensitive matches."""
import pathlib
import plistlib
import re
import sys
import stat
import base64
import zipfile

archive = pathlib.Path(sys.argv[1])
allowed = {
    'Ai-llowance.app/Contents/Info.plist',
    'Ai-llowance.app/Contents/MacOS/UsageBar',
    'Ai-llowance.app/Contents/MacOS/UsageBridge',
    'Ai-llowance.app/Contents/Resources/UsageBar.icns',
    'Ai-llowance.app/Contents/Resources/LICENSE',
    'Ai-llowance.app/Contents/Resources/Claude.png',
    'Ai-llowance.app/Contents/Resources/ChatGPT.png',
    'Ai-llowance.app/Contents/Resources/THIRD_PARTY_NOTICES.md',
    'Ai-llowance.app/Contents/Resources/PRIVACY.md',
    'Ai-llowance.app/Contents/_CodeSignature/CodeResources',
}
secret_patterns = [
    rb'gh[pousr]_[A-Za-z0-9]{30,}',
    rb'sk-(?:ant|proj)-[A-Za-z0-9_-]{20,}',
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
]
with zipfile.ZipFile(archive) as z:
    files = {entry.filename for entry in z.infolist() if not entry.is_dir()}
    framework_prefix = 'Ai-llowance.app/Contents/Frameworks/Sparkle.framework/'
    own_files = {name for name in files if not name.startswith(framework_prefix)}
    if own_files != allowed or framework_prefix + 'Versions/B/Sparkle' not in files and framework_prefix + 'Versions/A/Sparkle' not in files:
        raise SystemExit('Archive contains unexpected or missing files.')
    for entry in z.infolist():
        if entry.is_dir():
            continue
        if entry.filename.startswith('/') or '..' in pathlib.PurePosixPath(entry.filename).parts:
            raise SystemExit('Unsafe archive path.')
        data = z.read(entry)
        if stat.S_ISLNK(entry.external_attr >> 16):
            target = data.decode('utf-8')
            resolved = pathlib.PurePosixPath(entry.filename).parent / target
            # Framework aliases may use ../ within this bundle, never escape it.
            import posixpath
            if target.startswith('/') or not posixpath.normpath(str(resolved)).startswith(framework_prefix):
                raise SystemExit('Unsafe framework alias.')
        if pathlib.PurePosixPath(entry.filename).name in {'accounts.json', 'auth.json', '.credentials.json', '.env'}:
            raise SystemExit('Private file in release.')
        if any(re.search(pattern, data) for pattern in secret_patterns):
            raise SystemExit('Potential credential found; do not publish.')
        if b'/Users/' in data or b'/private/var/folders/' in data:
            raise SystemExit('Local machine path found; do not publish.')
    info = plistlib.loads(z.read('Ai-llowance.app/Contents/Info.plist'))
    if info.get('CFBundleIdentifier') != 'com.usagebar.app' or info.get('CFBundleDisplayName') != 'Ai-llowance' or not info.get('LSUIElement'):
        raise SystemExit('Unexpected app identity or mode.')
    if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32 or info.get('SUFeedURL') != 'https://github.com/jamesatFRM/Ai-llowance/releases/download/update-feed/appcast.xml':
        raise SystemExit('Missing or unexpected update configuration.')
    if not info.get('SURequireSignedFeed') or not info.get('SUVerifyUpdateBeforeExtraction') or info.get('SUEnableSystemProfiling') or info.get('SUAutomaticallyUpdate'):
        raise SystemExit('Unsafe updater defaults.')
    if info.get('SUSignedFeedFailureExpirationInterval') != 0:
        raise SystemExit('Signed feeds must not silently become optional.')
    for executable in ['UsageBar', 'UsageBridge']:
        mode = z.getinfo('Ai-llowance.app/Contents/MacOS/' + executable).external_attr >> 16
        if not mode & 0o111:
            raise SystemExit('Executable permission missing.')
print('Release archive passed: expected files, executable permissions, app identity, and sensitive-pattern checks.')
