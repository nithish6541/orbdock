#!/bin/zsh
# Builds Orb.app into ./build. Usage: ./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Orb.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -framework AppKit -framework ApplicationServices \
  Sources/*.swift -o "$APP/Contents/MacOS/Orb"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# The app icon is the orb itself, at rest, rendered by the same code that animates it.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$APP/Contents/MacOS/Orb" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Orb 2>/dev/null || true
  open "$APP"
fi
