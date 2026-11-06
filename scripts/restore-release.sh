#!/bin/bash
set -euo pipefail
# 恢复已发布二进制，不构建、不重签、不重置权限或偏好。
RELEASE_DIR="$(cd "${1:?用法：bash restore-release.sh 发布目录 [--verify-only]}" && pwd)"
MODE="${2:-install}"
[[ "$MODE" == install || "$MODE" == --verify-only ]] || { echo '未知参数' >&2; exit 1; }
ARCHIVE=touch-chord-1.0.0-arm64.zip
APP_PATH=/Applications/TouchChord.app
REQUIREMENT='identifier "local.trikey.app" and certificate leaf = H"0702170634f96a407f5a6d538db8330693f0e9dc"'
[[ "$(uname -m)" == arm64 ]] || { echo '此包仅适用于 Apple Silicon' >&2; exit 1; }
[[ -f "$RELEASE_DIR/$ARCHIVE" && -f "$RELEASE_DIR/sha256sums.txt" ]] || { echo '缺少 ZIP 或 sha256sums.txt' >&2; exit 1; }
EXPECTED="$(awk -v file="$ARCHIVE" '$2 == file { print $1 }' "$RELEASE_DIR/sha256sums.txt")"
[[ "$EXPECTED" =~ ^[a-f0-9]{64}$ ]] || { echo 'ZIP 校验记录缺失或重复' >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$RELEASE_DIR/$ARCHIVE")"
[[ "${ACTUAL%% *}" == "$EXPECTED" ]] || { echo 'ZIP 校验失败，未改动应用' >&2; exit 1; }
RESTORE_TEMP="$(mktemp -d)"
INSTALL_TEMP=''
cleanup() {
    rm -rf "$RESTORE_TEMP"
    if [[ -n "$INSTALL_TEMP" ]]; then
        # 替换中断时优先保留旧应用，禁止随临时目录清理而丢失。
        if [[ -d "$INSTALL_TEMP/previous.app" ]]; then
            if [[ ! -e "$APP_PATH" ]]; then mv "$INSTALL_TEMP/previous.app" "$APP_PATH"; fi
            if [[ -d "$INSTALL_TEMP/previous.app" ]]; then
                printf '旧应用保留在：%s/previous.app\n' "$INSTALL_TEMP" >&2
                return
            fi
        fi
        rmdir "$INSTALL_TEMP" 2>/dev/null || true
    fi
}
trap cleanup EXIT
ditto -x -k "$RELEASE_DIR/$ARCHIVE" "$RESTORE_TEMP"
SOURCE="$RESTORE_TEMP/TouchChord.app"
codesign --verify --strict -R "=$REQUIREMENT" "$SOURCE"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")" == 1.0.0 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE/Contents/Info.plist")" == 7 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE/Contents/Info.plist")" == TriKey ]]
if [[ "$MODE" == --verify-only ]]; then echo 'v1.0.0 ZIP、版本和固定签名验证通过，未更改应用'; exit 0; fi
[[ ! -L "$APP_PATH" ]] || { echo '拒绝覆盖符号链接' >&2; exit 1; }
if [[ -e "$APP_PATH" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" == local.trikey.app ]]
fi
# 通过正常退出菜单对应的 Quit 事件执行清理；绝不使用 SIGKILL。
PIDS="$(pgrep -f '^/Applications/TouchChord[.]app/Contents/MacOS/TriKey$' || true)"
if [[ -n "$PIDS" ]]; then
    /usr/bin/osascript -e 'tell application "/Applications/TouchChord.app" to quit'
    for ((ATTEMPT=0; ATTEMPT<30; ATTEMPT++)); do
        pgrep -f '^/Applications/TouchChord[.]app/Contents/MacOS/TriKey$' >/dev/null || break
        sleep 1
    done
    if pgrep -f '^/Applications/TouchChord[.]app/Contents/MacOS/TriKey$' >/dev/null; then
        echo '应用未正常退出，停止恢复；未覆盖应用' >&2; exit 1
    fi
fi
INSTALL_TEMP="$(mktemp -d /Applications/.touchchord-restore.XXXXXX)"
ditto "$SOURCE" "$INSTALL_TEMP/TouchChord.app"
codesign --verify --strict -R "=$REQUIREMENT" "$INSTALL_TEMP/TouchChord.app"
if [[ -e "$APP_PATH" ]]; then
    BACKUP_DIR="$HOME/Library/Application Support/TouchChord/Backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/before-restore-$(date +%Y%m%d-%H%M%S)-$$.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$BACKUP_FILE"
    unzip -tq "$BACKUP_FILE"
    mv "$APP_PATH" "$INSTALL_TEMP/previous.app"
    printf '已备份替换前应用：%s\n' "$BACKUP_FILE"
fi
mv "$INSTALL_TEMP/TouchChord.app" "$APP_PATH"
codesign --verify --strict -R "=$REQUIREMENT" "$APP_PATH"
if [[ -d "$INSTALL_TEMP/previous.app" ]]; then rm -rf "$INSTALL_TEMP/previous.app"; fi
open "$APP_PATH"
echo '已恢复并打开 TouchChord v1.0.0；请确认等待三指触摸和两项权限状态。'
