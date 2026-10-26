#!/bin/bash
# Builds OpenLift and assembles a runnable .app bundle.
#
# Usage: Scripts/make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/OpenLift.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/OpenLift" "$APP/Contents/MacOS/OpenLift"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature is enough for local development.
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "Built $APP"
