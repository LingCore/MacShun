#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 生成开发用的自签名代码签名证书。只需运行一次。
#
# 为什么需要：macOS 按签名识别程序。不用固定证书的话，每次重新编译后签名都会变，
# “辅助功能”和“输入监控”权限就要重新授权。
#
# 证书放在单独的钥匙串里，不碰登录钥匙串，也不加进钥匙串搜索列表：
#   ~/Library/Keychains/winshun-dev.keychain-db（密码 winshun-dev，只存这一个开发证书）
# 不要了可以运行：security delete-keychain ~/Library/Keychains/winshun-dev.keychain-db

set -euo pipefail

# 名字沿用改名前（Win顺）的：build-app.sh 按这个名字找证书，换一张证书所有人都要重新授权
IDENTITY="WinShun Development"
KEYCHAIN="$HOME/Library/Keychains/winshun-dev.keychain-db"
KEYCHAIN_PASSWORD="winshun-dev"

if [[ -f "$KEYCHAIN" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "开发证书已经存在：$IDENTITY"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:temp -name "$IDENTITY"

if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# 不自动上锁
security set-keychain-settings "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign >/dev/null
# 允许 codesign 使用私钥时不弹窗
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "已生成开发证书：$IDENTITY"
echo "钥匙串：$KEYCHAIN"
