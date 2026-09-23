#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Set STUDIO_BUILD_DIR to keep compiler output outside the source tree.
BUILD_DIR="${STUDIO_BUILD_DIR:-.build}"
OUTPUT_DIR="${STUDIO_OUTPUT_DIR:-dist}"
ARCH_ARGS=()
if [[ "${STUDIO_UNIVERSAL:-0}" == "1" ]]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
swift build -c release --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR=$(swift build -c release --scratch-path "$BUILD_DIR" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)
APP="$OUTPUT_DIR/Attune.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Attune" "$APP/Contents/MacOS/Attune"
# SwiftPM uses different bundle layouts for native and multi-architecture builds.
# Replace this generated bundle so an older Contents/Resources cannot shadow new catalogs.
rm -rf "$APP/Contents/Resources/Attune_SkillStudioCore.bundle"
cp -R "$BIN_DIR/Attune_SkillStudioCore.bundle" "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp BRAND_ASSETS.md "$APP/Contents/Resources/BRAND_ASSETS.md"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Attune</string>
  <key>CFBundleIdentifier</key><string>dev.agentskillstudio.mac</string>
  <key>CFBundleName</key><string>Attune</string>
  <key>CFBundleDisplayName</key><string>Attune</string>
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
strip -S "$APP/Contents/MacOS/Attune"
python3 scripts/check-privacy.py --directory "$APP"
if [[ -n "${STUDIO_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$STUDIO_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
