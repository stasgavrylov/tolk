#!/bin/bash
# Run after scripts/build.sh. Checks the real disk image without launching or installing Tolk.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tolk-dmg-test.XXXXXX")
MOUNTED=false
cleanup() {
  if "$MOUNTED"; then
    hdiutil detach "$WORK/mounted" >/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -x "$ROOT/scripts/package-dmg.sh" ]; then
  echo "Missing executable DMG packager: scripts/package-dmg.sh" >&2
  exit 1
fi
"$ROOT/scripts/package-dmg.sh"
mkdir "$WORK/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$WORK/mounted" "$ROOT/build/Tolk.dmg" >/dev/null
MOUNTED=true
[ -d "$WORK/mounted/Tolk.app" ]
[ -x "$WORK/mounted/Tolk.app/Contents/MacOS/Tolk" ]
[ "$(readlink "$WORK/mounted/Applications")" = /Applications ]
codesign --verify --deep --strict "$WORK/mounted/Tolk.app"
diff -r "$ROOT/build/Tolk.app" "$WORK/mounted/Tolk.app"
hdiutil detach "$WORK/mounted" >/dev/null
MOUNTED=false
echo "PASS: mounted DMG contains the unchanged, signed app and Applications shortcut"

# Isolated projects exercise failure paths without touching the real build.
expect_failure_keeps_previous_dmg() {
  local project=$1
  printf 'previous disk image\n' > "$project/build/Tolk.dmg"
  cp "$project/build/Tolk.dmg" "$project/previous.dmg"
  if "$project/scripts/package-dmg.sh" > "$project/error.log" 2>&1; then
    echo "Expected packaging to reject $project" >&2
    exit 1
  fi
  cmp "$project/previous.dmg" "$project/build/Tolk.dmg"
  [ -z "$(find "$project/build" -maxdepth 1 -name '.tolk-dmg.*' -print)" ]
}

mkdir -p "$WORK/missing/scripts" "$WORK/missing/build"
cp "$ROOT/scripts/package-dmg.sh" "$WORK/missing/scripts/"
expect_failure_keeps_previous_dmg "$WORK/missing"
echo "PASS: missing app is rejected without replacing a previous DMG"

mkdir -p "$WORK/damaged/scripts" "$WORK/damaged/build"
cp "$ROOT/scripts/package-dmg.sh" "$WORK/damaged/scripts/"
ditto "$ROOT/build/Tolk.app" "$WORK/damaged/build/Tolk.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Modified' "$WORK/damaged/build/Tolk.app/Contents/Info.plist"
expect_failure_keeps_previous_dmg "$WORK/damaged"
echo "PASS: damaged app is rejected without replacing a previous DMG"
