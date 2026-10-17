#!/bin/bash
# Uses a locally configured notarytool Keychain profile; never accepts raw credentials.
set -euo pipefail
umask 077
identity="${USAGEBAR_SIGNING_IDENTITY:--}"
profile="${USAGEBAR_NOTARY_PROFILE:-}"
if [ -z "$profile" ] || [ "$identity" = "-" ]; then
    echo "Notarization requires USAGEBAR_NOTARY_PROFILE and a Developer ID Application signing identity." >&2
    exit 1
fi
case "$identity" in
    "Developer ID Application: "*) ;;
    *) echo "Notarization requires the complete Developer ID Application identity name." >&2; exit 1 ;;
esac
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
if [ "${1:-}" = "--check-config" ]; then exit 0; fi
if [ "$#" -ne 1 ]; then echo "Usage: notarize-release.sh APP_OR_DMG" >&2; exit 1; fi
target="$1"
temporary="$(mktemp -d "${TMPDIR:-/private/tmp}/allowance-notary.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
case "$target" in
    *.app)
        codesign --verify --deep --strict "$target"
        upload="$temporary/Submission.zip"
        ditto -c -k --norsrc --keepParent "$target" "$upload"
        ;;
    *.dmg)
        codesign --force --sign "$identity" --timestamp "$target"
        codesign --verify --strict "$target"
        upload="$target"
        ;;
    *) echo "Only an app bundle or DMG can be submitted." >&2; exit 1 ;;
esac
# This can take several minutes. No password or API key is passed on the command line.
submission_exit=0
xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json > "$temporary/result.json" || submission_exit=$?
python3 - "$temporary/result.json" "$submission_exit" <<'PY'
import json,pathlib,sys
try: result=json.loads(pathlib.Path(sys.argv[1]).read_text())
except (ValueError,OSError): raise SystemExit('Notarization did not return a valid result. Check Xcode tools and the local Keychain profile.')
if sys.argv[2]!='0' or result.get('status')!='Accepted':
    # Keep the submission identifier actionable without copying service logs/credentials.
    print('Notarization was not accepted. Retrieve the notary log for submission '+str(result.get('id','unknown'))+'.',file=sys.stderr)
    raise SystemExit(1)
print('Apple accepted notarization submission '+str(result.get('id','unknown'))+'.')
PY
xcrun stapler staple "$target"
xcrun stapler validate "$target"
case "$target" in
    *.app) spctl --assess --type execute --verbose=2 "$target" ;;
    *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$target" ;;
esac
