#!/bin/bash
# Generates Resources/OpenLift.icns from Scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p Resources
swift Scripts/make-icon.swift

ICONSET="$(mktemp -d)/OpenLift.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/OpenLift.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Resources/OpenLift.icns"
