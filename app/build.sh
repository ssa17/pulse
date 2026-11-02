#!/bin/bash
# Build Pulse.app (native shell + bundled Node backend).
set -e
cd "$(dirname "$0")/.."

APP=dist/Pulse.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Library"

cp app/Info.plist "$APP/Contents/Info.plist"

# Sanity: package.json's version should match the app's (web mode displays it).
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw app/Info.plist)
PKG_VERSION=$(node -p "require('./package.json').version")
if [ "$APP_VERSION" != "$PKG_VERSION" ]; then
  echo "⚠️  version mismatch: app=$APP_VERSION package.json=$PKG_VERSION — keep them in sync"
fi

# ── Sparkle (auto-update framework) ──────────────────────────────
# Ensure the pre-built framework is present (downloads on a fresh clone).
bash vendor/fetch-sparkle.sh
# Bundle the framework + the Updater helper app (required for non-sandboxed apps).
cp -R vendor/sparkle/Sparkle.framework "$APP/Contents/Frameworks/"
cp -R vendor/sparkle/Sparkle.framework/Versions/Current/Updater.app "$APP/Contents/Library/"

echo "→ compiling Swift shell"
# -target pins the deployment target to the supported floor (macOS 13) instead of
# the build machine's OS version — without it the binary would only run on the
# newest macOS (swiftc defaults minos to the host version).
swiftc -O app/Pulse.swift -o "$APP/Contents/MacOS/Pulse" \
  -target arm64-apple-macos13.0 \
  -framework Cocoa -framework WebKit \
  -F vendor/sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "→ building icon"
node app/make-icon.mjs app/Pulse-1024.png
rm -rf app/Pulse.iconset
mkdir -p app/Pulse.iconset
sips -z 16 16   app/Pulse-1024.png --out app/Pulse.iconset/icon_16x16.png      >/dev/null
sips -z 32 32   app/Pulse-1024.png --out app/Pulse.iconset/icon_16x16@2x.png   >/dev/null
sips -z 32 32   app/Pulse-1024.png --out app/Pulse.iconset/icon_32x32.png      >/dev/null
sips -z 64 64   app/Pulse-1024.png --out app/Pulse.iconset/icon_32x32@2x.png   >/dev/null
sips -z 128 128 app/Pulse-1024.png --out app/Pulse.iconset/icon_128x128.png    >/dev/null
sips -z 256 256 app/Pulse-1024.png --out app/Pulse.iconset/icon_128x128@2x.png >/dev/null
sips -z 256 256 app/Pulse-1024.png --out app/Pulse.iconset/icon_256x256.png    >/dev/null
sips -z 512 512 app/Pulse-1024.png --out app/Pulse.iconset/icon_256x256@2x.png >/dev/null
sips -z 512 512 app/Pulse-1024.png --out app/Pulse.iconset/icon_512x512.png    >/dev/null
iconutil -c icns app/Pulse.iconset -o "$APP/Contents/Resources/Pulse.icns"
rm -rf app/Pulse.iconset

echo "→ bundling backend"
cp server.js "$APP/Contents/Resources/server.js"
cp -R public "$APP/Contents/Resources/public"

echo "Built $APP"
