#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set STUDIO_BUILD_DIR to keep compiler output outside the source tree.
BUILD_DIR="${STUDIO_BUILD_DIR:-.build}"
OUTPUT_DIR="${STUDIO_OUTPUT_DIR:-dist}"
CONFIGURATION=release
BUNDLE_ID=dev.agentskillstudio.mac
DATA_MODE=production
if [[ "${STUDIO_DEVELOPMENT:-0}" == "1" ]]; then
  CONFIGURATION=debug
  BUNDLE_ID=dev.agentskillstudio.mac.development
  DATA_MODE=isolatedDevelopment
  [[ -z "${STUDIO_SIGN_IDENTITY:-}" ]] || { echo 'Development smoke does not use distribution signing.' >&2; exit 1; }
fi
ARCH_ARGS=()
if [[ "${STUDIO_UNIVERSAL:-0}" == "1" ]]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR=$(swift build -c "$CONFIGURATION" --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)
APP="$OUTPUT_DIR/Iterune.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Iterune" "$APP/Contents/MacOS/Iterune"
# SwiftPM uses different bundle layouts for native and multi-architecture builds.
# Replace this generated bundle so an older Contents/Resources cannot shadow new catalogs.
rm -rf "$APP/Contents/Resources/Iterune_SkillStudioCore.bundle"
cp -R "$BIN_DIR/Iterune_SkillStudioCore.bundle" "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp BRAND_ASSETS.md "$APP/Contents/Resources/BRAND_ASSETS.md"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Iterune</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>IteruneRuntimeDataMode</key><string>$DATA_MODE</string>
  <key>CFBundleName</key><string>Iterune</string>
  <key>CFBundleDisplayName</key><string>Iterune</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.1</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ja</string><string>zh-Hans</string><string>zh-Hant</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Remove debug symbol paths from the distributable, then check before signing.
strip -S "$APP/Contents/MacOS/Iterune"
python3 scripts/check-privacy.py --directory "$APP"
if [[ -n "${STUDIO_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$STUDIO_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
