#!/usr/bin/env python3
"""Check release contents without printing any potentially sensitive matches."""
import pathlib
import plistlib
import re
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
allowed = {
    'UsageBar.app/Contents/Info.plist',
    'UsageBar.app/Contents/MacOS/UsageBar',
    'UsageBar.app/Contents/MacOS/UsageBridge',
    'UsageBar.app/Contents/Resources/UsageBar.icns',
    'UsageBar.app/Contents/Resources/LICENSE',
    'UsageBar.app/Contents/_CodeSignature/CodeResources',
}
secret_patterns = [
    rb'gh[pousr]_[A-Za-z0-9]{30,}',
    rb'sk-(?:ant|proj)-[A-Za-z0-9_-]{20,}',
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
]
with zipfile.ZipFile(archive) as z:
    files = {entry.filename for entry in z.infolist() if not entry.is_dir()}
    if files != allowed:
        raise SystemExit('Archive contains unexpected or missing files.')
    for entry in z.infolist():
        if entry.is_dir():
            continue
        if entry.filename.startswith('/') or '..' in pathlib.PurePosixPath(entry.filename).parts:
            raise SystemExit('Unsafe archive path.')
        data = z.read(entry)
        if any(re.search(pattern, data) for pattern in secret_patterns):
            raise SystemExit('Potential credential found; do not publish.')
        if b'/Users/' in data or b'/private/var/folders/' in data:
            raise SystemExit('Local machine path found; do not publish.')
    info = plistlib.loads(z.read('UsageBar.app/Contents/Info.plist'))
    if info.get('CFBundleIdentifier') != 'com.usagebar.app' or not info.get('LSUIElement'):
        raise SystemExit('Unexpected app identity or mode.')
    for executable in ['UsageBar', 'UsageBridge']:
        mode = z.getinfo('UsageBar.app/Contents/MacOS/' + executable).external_attr >> 16
        if not mode & 0o111:
            raise SystemExit('Executable permission missing.')
print('Release archive passed: expected files, executable permissions, app identity, and sensitive-pattern checks.')
