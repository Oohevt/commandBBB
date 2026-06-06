#!/bin/bash
set -e
cd "$(dirname "$0")"

DEST="/Applications/CommandB.app"
SRC="build/Build/Products/Release/CommandB.app"

xcodebuild \
  -project CommandB.xcodeproj \
  -scheme CommandB \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
  build

# Kill any running instance and wait until gone
pkill -9 -x CommandB 2>/dev/null || true
while pgrep -x CommandB >/dev/null; do sleep 0.1; done

# Replace cleanly — rm first, then ditto (correct tool for app bundles).
# Plain `cp -R src dst` nests src INSIDE dst when dst exists; that bug left
# the installed binary permanently stale.
rm -rf "$DEST"
ditto "$SRC" "$DEST"

open "$DEST"
echo "Installed $(stat -f '%Sm' "$DEST/Contents/MacOS/CommandB") and launched."
