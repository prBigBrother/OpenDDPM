#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-0.3.0}"
APP="${BUILD_DIR:-$ROOT/build}/OpenDDPM.app"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/OpenDDPM-$VERSION-universal.zip"
STAGING="${BUILD_DIR:-$ROOT/build}/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/OpenDDPM.app"
ln -sfn /Applications "$STAGING/Applications"
cp docs/INSTALL.txt "$STAGING/Read me first.txt"
hdiutil create -volname "OpenDDPM $VERSION" -srcfolder "$STAGING" -ov -format UDZO "dist/OpenDDPM-$VERSION-universal.dmg"
(cd dist && shasum -a 256 "OpenDDPM-$VERSION-universal.zip" "OpenDDPM-$VERSION-universal.dmg") > "dist/SHA256SUMS.txt"
echo "Packaged ZIP and DMG in dist/"
