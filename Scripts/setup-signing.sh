#!/bin/bash
set -euo pipefail
umask 077
SIGNING_DIR="$HOME/Library/Application Support/TriKey/Signing"
IDENTITY_FILE="$SIGNING_DIR/identity.sha1"
CERT_FILE="$SIGNING_DIR/certificate.pem"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CERT_NAME="TriKey Local Development"

if [[ -f "$IDENTITY_FILE" ]]; then
    read -r IDENTITY < "$IDENTITY_FILE"
    if [[ ! "$IDENTITY" =~ ^[A-F0-9]{40}$ || ! -f "$CERT_FILE" ]]; then
        echo '签名记录不完整，请恢复原证书和私钥；不会自动创建新身份。' >&2
        exit 1
    fi
else
    # 避免在本机记录丢失后静默更换身份，导致已有授权失效。
    if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
        echo '钥匙串已有 TriKey 证书，但缺少固定身份记录。请恢复 Signing 目录。' >&2
        exit 1
    fi
    SIGNING_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/trikey-signing.XXXXXX")"
    trap 'rm -rf "$SIGNING_TEMP"' EXIT
    /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
        -subj "/CN=$CERT_NAME/" \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=critical,codeSigning' \
        -keyout "$SIGNING_TEMP/key.pem" -out "$SIGNING_TEMP/certificate.pem"
    # 临时目录仅当前用户可访问；私钥导入钥匙串后删除，不放入项目或安装包。
    /usr/bin/openssl rsa -in "$SIGNING_TEMP/key.pem" -out "$SIGNING_TEMP/rsa-key.pem"
    security import "$SIGNING_TEMP/rsa-key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
    security import "$SIGNING_TEMP/certificate.pem" -k "$KEYCHAIN" -f pemseq -t cert
    mkdir -p "$SIGNING_DIR"
    cp "$SIGNING_TEMP/certificate.pem" "$CERT_FILE"
    FINGERPRINT="$(/usr/bin/openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha1)"
    IDENTITY="${FINGERPRINT#*=}"
    IDENTITY="${IDENTITY//:/}"
    printf '%s\n' "$IDENTITY" > "$IDENTITY_FILE"
fi

FINGERPRINT="$(/usr/bin/openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha1)"
FINGERPRINT="${FINGERPRINT#*=}"
if [[ "${FINGERPRINT//:/}" != "$IDENTITY" ]]; then
    echo '证书与固定指纹不匹配，停止设置信任；请恢复原签名记录。' >&2
    exit 1
fi
if ! security find-identity -v -p codesigning "$KEYCHAIN" | /usr/bin/grep -Fq "$IDENTITY"; then
    # 仅当前用户、仅代码签名用途，不授予 SSL 信任、不修改系统钥匙串。
    echo '正在为 TriKey 本地证书设置代码签名信任；如系统弹出授权，请本人确认。'
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_FILE"
fi
security find-identity -v -p codesigning "$KEYCHAIN" | /usr/bin/grep -F "$IDENTITY"
printf '固定签名身份已就绪：%s\n记录：%s\n' "$IDENTITY" "$IDENTITY_FILE"
