#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/Build/TouchChord.app"
codesign --verify --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP_DIR/Contents/MacOS/TriKey" | tr ' ' '-')"
DMG_PATH="$PROJECT_DIR/Build/TouchChord-$VERSION-$ARCH.dmg"
if [[ -e "$DMG_PATH" ]]; then
    printf '安装包已存在，不覆盖：%s\n' "$DMG_PATH" >&2
    exit 1
fi
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/Build/dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
chmod 755 "$STAGING_DIR"
ditto "$APP_DIR" "$STAGING_DIR/TouchChord.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$PROJECT_DIR/Resources/安装说明.txt" "$STAGING_DIR/安装说明.txt"
hdiutil create -volname TouchChord -srcfolder "$STAGING_DIR" -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
printf '安装包：%s\n' "$DMG_PATH"
