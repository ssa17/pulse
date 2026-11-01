#!/bin/bash
# Fetch the pre-built Sparkle framework + CLI tools into vendor/sparkle/.
# Idempotent: skips the download if the framework is already present.
#
# Sparkle is a third-party framework (https://sparkle-project.org) used for
# auto-updates. We vendor the pre-built release rather than building from
# source, and gitignore it (see .gitignore) to keep the repo free of binaries.
set -e
cd "$(dirname "$0")"

SPARKLE_VERSION=2.10.1
DEST=sparkle

if [ -d "$DEST/Sparkle.framework" ]; then
  echo "Sparkle $SPARKLE_VERSION already present in vendor/$DEST/"
  exit 0
fi

echo "→ downloading Sparkle $SPARKLE_VERSION"
mkdir -p "$DEST"
curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
  -o "$DEST/.sparkle.tar.xz"
tar -xf "$DEST/.sparkle.tar.xz" -C "$DEST"
rm "$DEST/.sparkle.tar.xz"

# Keep only what we need (framework + CLI tools + license); drop the test app & symbols
rm -rf "$DEST/Sparkle Test App.app" "$DEST/Symbols" "$DEST/INSTALL" "$DEST/CHANGELOG"
chmod +x "$DEST"/bin/* 2>/dev/null || true

echo "→ Sparkle $SPARKLE_VERSION ready in vendor/$DEST/"
