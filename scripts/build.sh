#!/bin/bash
# Builds build/Tolk.app (release by default). Usage: scripts/build.sh [debug|release] [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
INSTALL=${2:-}
swift build -c "$CONFIG" --product Tolk
PRODUCTS=$(swift build -c "$CONFIG" --show-bin-path)
APP=build/Tolk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Tolk" "$APP/Contents/MacOS/Tolk"
cp -R "$PRODUCTS"/KeyboardShortcuts_KeyboardShortcuts.bundle "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A stable signing identity keeps Accessibility and Keychain grants across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --deep --options runtime --entitlements Resources/Tolk.entitlements --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
if [ "$INSTALL" = "--install" ]; then
  pkill -x Tolk 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Tolk.app
  cp -R "$APP" /Applications/Tolk.app
  echo "Installed /Applications/Tolk.app"
fi
