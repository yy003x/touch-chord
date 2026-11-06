#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY_FILE="$HOME/Library/Application Support/TriKey/Signing/identity.sha1"
if [[ ! -f "$IDENTITY_FILE" ]]; then
    echo '缺少固定签名身份，请先执行 bash scripts/setup-signing.sh。禁止回退到临时签名。' >&2
    exit 1
fi
read -r SIGN_ID < "$IDENTITY_FILE"
if [[ ! "$SIGN_ID" =~ ^[A-F0-9]{40}$ ]] || ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "$SIGN_ID"; then
    echo '固定签名身份不可用，请解锁登录钥匙串或恢复原证书及私钥。' >&2
    exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build --package-path "$PROJECT_DIR" -c release --product TriKeyProbe
swift build --package-path "$PROJECT_DIR" -c release --product TriKey
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/build/TouchChord.app"
if [[ -L "$APP_DIR" ]]; then
    printf 'Refusing to replace symlink: %s\n' "$APP_DIR" >&2
    exit 1
fi
if [[ -e "$APP_DIR" ]]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
    if [[ "$BUNDLE_ID" != local.trikey.app ]]; then
        printf 'Unexpected bundle identifier: %s\n' "$BUNDLE_ID" >&2
        exit 1
    fi
fi
if pgrep -f "^$APP_DIR/Contents/MacOS/TriKey$" >/dev/null; then
    echo '请先退出 build/TouchChord.app 再构建，避免覆盖运行中的应用。' >&2
    exit 1
fi
mkdir -p "$PROJECT_DIR/build"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/build/staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/TouchChord.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$BIN_DIR/TriKey" "$STAGED_APP/Contents/MacOS/TriKey"
cp "$PROJECT_DIR/resources/info.plist" "$STAGED_APP/Contents/Info.plist"
mkdir -p "$STAGED_APP/Contents/Resources"
bash "$PROJECT_DIR/scripts/build-icon.sh" "$STAGED_APP/Contents/Resources/AppIcon.icns"
# 明确绑定证书和 bundle ID，代码变化不会改变 designated requirement。
REQUIREMENT="identifier \"local.trikey.app\" and certificate leaf = H\"$SIGN_ID\""
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
    --requirements "=designated => $REQUIREMENT" "$STAGED_APP"
codesign --verify --strict --verbose=2 -R "=$REQUIREMENT" "$STAGED_APP"
ditto "$STAGED_APP" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
printf 'App: %s\nProbe: %s/TriKeyProbe\n' "$APP_DIR" "$BIN_DIR"
