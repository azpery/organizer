#!/bin/bash
# Builds build/Organizer.app (release). Use --install to copy it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Organizer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Organizer "$APP/Contents/MacOS/Organizer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Organizer.app
  cp -R "$APP" /Applications/
  echo "✓ installé dans /Applications"
fi
