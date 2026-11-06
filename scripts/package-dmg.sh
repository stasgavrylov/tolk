#!/bin/bash
# Packages an existing build/Tolk.app as build/Tolk.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/Tolk.app
if [ ! -d "$APP" ]; then
  echo "Missing $APP. Run scripts/build.sh first." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

# Build privately, then replace the previous image only after verification succeeds.
STAGING=$(mktemp -d build/.tolk-dmg.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/payload"
ditto "$APP" "$STAGING/payload/Tolk.app"
ln -s /Applications "$STAGING/payload/Applications"
hdiutil create -volname Tolk -srcfolder "$STAGING/payload" -format UDZO "$STAGING/Tolk.dmg"
hdiutil verify "$STAGING/Tolk.dmg"
mv -f "$STAGING/Tolk.dmg" build/Tolk.dmg
echo "Packaged build/Tolk.dmg"
