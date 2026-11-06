#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?请指定输出 icns 路径}"
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT
mkdir "$ICON_TEMP/AppIcon.iconset"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$PROJECT_DIR/resources/app-icon.png" --out "$ICON_TEMP/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$PROJECT_DIR/resources/app-icon.png" --out "$ICON_TEMP/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_TEMP/AppIcon.iconset" -o "$OUTPUT"
