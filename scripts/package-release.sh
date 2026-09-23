#!/bin/bash
# Packages locally. It never pushes, publishes a release, or changes repository visibility.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${STUDIO_OUTPUT_DIR:-dist}/Iterune.app"
[[ -d "$APP" ]] || { echo 'Build the app first.' >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP="${STUDIO_OUTPUT_DIR:-dist}/Iterune-$VERSION-macOS-universal.zip"
lipo "$APP/Contents/MacOS/Iterune" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/Iterune" --verify-installation
python3 scripts/check-privacy.py --directory "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "${STUDIO_NOTARY_PROFILE:-}" ]]; then
  # Reject an ad-hoc build instead of sending it to notarization.
  codesign -dvv "$APP" 2>&1 | grep -q 'Authority=Developer ID Application:' || {
    echo 'Notarization requires a Developer ID Application signature.' >&2; exit 1;
  }
  xcrun notarytool submit "$ZIP" --keychain-profile "$STUDIO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi
(cd "$(dirname "$ZIP")" && shasum -a 256 "$(basename "$ZIP")") > "$ZIP.sha256"
echo "Packaged: $ZIP"
