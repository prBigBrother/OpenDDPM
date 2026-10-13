#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.2.0}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/OpenDDPM.app"
rm -rf "$APP"
mkdir -p "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64" "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Carbon \
    Sources/OpenDDPM/*.swift -o "$BUILD_DIR/$ARCH/OpenDDPM"
  clang -O2 -fobjc-arc -fmodules -target "$ARCH-apple-macosx13.0" \
    -framework Foundation -framework IOKit -framework CoreGraphics \
    Sources/NativeDDC/main.m -o "$BUILD_DIR/$ARCH/openddpm-ddc"
done
lipo -create "$BUILD_DIR/arm64/OpenDDPM" "$BUILD_DIR/x86_64/OpenDDPM" -output "$APP/Contents/MacOS/OpenDDPM"
lipo -create "$BUILD_DIR/arm64/openddpm-ddc" "$BUILD_DIR/x86_64/openddpm-ddc" -output "$APP/Contents/Helpers/openddpm-ddc"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>OpenDDPM</string>
<key>CFBundleDisplayName</key><string>OpenDDPM</string>
<key>CFBundleIdentifier</key><string>io.github.prbigbrother.OpenDDPM</string>
<key>CFBundleExecutable</key><string>OpenDDPM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
cp Vendor/NativeDDC/LICENSE-m1ddc.txt "$APP/Contents/Resources/NativeDDC-LICENSE.txt"
cp Vendor/NativeDDC/NOTICE.md "$APP/Contents/Resources/NativeDDC-NOTICE.md"
cp LICENSE "$APP/Contents/Resources/OpenDDPM-LICENSE.txt"
cp assets/logo.png "$APP/Contents/Resources/logo.png"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -s format png -z "$SIZE" "$SIZE" assets/logo.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -s format png -z "$DOUBLE" "$DOUBLE" assets/logo.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Helpers/openddpm-ddc"
if [ "$SIGNING_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, universal arm64 + x86_64)"
