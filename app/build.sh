#!/bin/bash
# Build Pulse.app (native shell + bundled Node backend).
# Usage: ./app/build.sh [--notarize | --no-notarize]
#   (no flag)      sign locally, and re-notarize automatically when the PREVIOUS
#                  build was notarized — once you've opted in, the dev loop keeps
#                  Touch ID on "Purge disk cache" (macOS 26.3+ gates it on
#                  codesign -R="notarized").
#   --notarize     always notarize (timestamp + notarytool + staple)
#   --no-notarize  never notarize (fast, offline, password-only prompt)
set -e
cd "$(dirname "$0")/.."

NOTARIZE=2  # 2 = auto, 1 = explicit --notarize, 0 = never
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    -h|--help)
      echo "Usage: $0 [--notarize | --no-notarize]"
      echo "  (no flag)      sign locally; re-notarize automatically if the previous build was"
      echo "  --notarize     always timestamp + notarytool ($NOTARY_PROFILE) + staple"
      echo "  --no-notarize  never notarize (fast + offline; password-only 'Purge' prompt)"
      echo "Touch ID on 'Purge disk cache' needs a notarized build (macOS 26.3+)."
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

APP=dist/Pulse.app
# Auto: inherit notarization from the previous build. The check is local and
# instant (it validates the stapled ticket in-place); the submission itself
# happens at the end of the build. No previous build / unnotarized → plain.
if [ "$NOTARIZE" = 2 ]; then
  if [ -d "$APP" ] && codesign -v -R="notarized" "$APP" >/dev/null 2>&1; then
    echo "→ notarize (auto: previous build was notarized — keeps Touch ID)"
  else
    NOTARIZE=0
  fi
fi
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Library"

cp app/Info.plist "$APP/Contents/Info.plist"

# package.json's version is DERIVED from the app's — Info.plist is the single
# source of truth. Sync it so the two never drift (only writes on change).
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw app/Info.plist)
PKG_VERSION=$(node -p "require('./package.json').version")
if [ "$APP_VERSION" != "$PKG_VERSION" ]; then
  node -e "const fs=require('fs');const f='package.json';const p=JSON.parse(fs.readFileSync(f,'utf8'));p.version='$APP_VERSION';fs.writeFileSync(f,JSON.stringify(p,null,2)+'\n')"
  echo "→ synced package.json version: $PKG_VERSION → $APP_VERSION"
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

echo "→ compiling thermal helper"
clang -O2 app/pulse-thermal.c -o "$APP/Contents/MacOS/pulse-thermal" \
  -target arm64-apple-macos13.0 \
  -framework CoreFoundation -framework IOKit

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
cp -R public "$APP/Contents/Resources/public"
cp server.js "$APP/Contents/Resources/server.js"

echo "→ code-signing bundle"
# Sign inside-out with Developer ID + Hardened Runtime when available (same as
# fastlane): stops Gatekeeper's first-launch "could not verify" prompt and keeps
# Sparkle.framework under our Team ID for Library Validation.
# On macOS 26.3+, authd gates Touch ID on admin prompts (system.privilege.admin,
# used by "Purge disk cache") behind notarization (codesign -R="notarized"):
# a NOTARIZED build (flag, or auto-inherited) gets Touch ID + password fallback;
# a plain build is fast/offline but password-only. NOTARIZE: 1/2 = will submit,
# 0 = will not.
CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Developer ID Application" | awk -F'"' '{print $2}')
if [ -n "$CERT" ]; then
  echo "   identity: $CERT"
  SIGN_FLAGS=(--force --options=runtime)
  if [ "$NOTARIZE" != 0 ]; then
    SIGN_FLAGS+=(--timestamp)   # an embedded timestamp is only needed to notarize
  fi
  codesign --sign "$CERT" "${SIGN_FLAGS[@]}" "$APP/Contents/Library/Updater.app"
  codesign --sign "$CERT" --deep "${SIGN_FLAGS[@]}" "$APP"
elif [ "$NOTARIZE" = 1 ]; then
  echo "error: --notarize requires a 'Developer ID Application' certificate in your keychain" >&2
  exit 1
else
  if [ "$NOTARIZE" = 2 ]; then
    echo "   warning: previous build was notarized, but no Developer ID cert found"
    NOTARIZE=0   # auto degrades gracefully; only an explicit --notarize errors
  fi
  echo "   no Developer ID cert found — falling back to ad-hoc (password-only prompt)"
  codesign --force -s - "$APP"
fi

if [ "$NOTARIZE" != 0 ]; then
  echo "→ notarizing + stapling (profile: $NOTARY_PROFILE)"
  NOTARIZE_ZIP="dist/notarize.zip"
  ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
  trap 'rm -f "$NOTARIZE_ZIP"' EXIT
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARIZE_ZIP"
  trap - EXIT
  xcrun stapler staple "$APP"
  codesign -vvvv -R="notarized" "$APP" >/dev/null
  echo "Built + notarized $APP (Touch ID ready)"
else
  echo "Built $APP (password-only 'Purge' prompt — build with --notarize for Touch ID)"
fi
