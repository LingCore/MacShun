#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 编译并打包成 build/Win顺.app，用开发证书签名（先运行一次 scripts/dev-cert.sh）。
#
# 用法：
#   scripts/build-app.sh            编译打包
#   scripts/build-app.sh --install  编译打包，装到“应用程序”文件夹并启动

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Win顺"
APP="$ROOT/build/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"
IDENTITY="WinShun Development"
KEYCHAIN="$HOME/Library/Keychains/winshun-dev.keychain-db"
KEYCHAIN_PASSWORD="winshun-dev"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WinShun" "$APP/Contents/MacOS/WinShun"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # 图标由 scripts/make-icon.py 生成
cp "$ROOT/Resources/AppGlyph.svg" "$APP/Contents/Resources/AppGlyph.svg"   # 不带底板的矢量标志，“拾穗计划”页用
cp "$ROOT/Resources/AuthorAvatar.png" "$APP/Contents/Resources/AuthorAvatar.png"   # 作者头像，“拾穗计划”页用

if [[ -f "$KEYCHAIN" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$APP"
else
    echo "警告：没有找到开发证书，改用临时签名。这样每次重新编译后都要重新授权。" >&2
    echo "      运行一次 scripts/dev-cert.sh 可以解决。" >&2
    codesign --force --sign - "$APP"
fi
codesign --verify "$APP"
echo "已生成：$APP"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -x WinShun >/dev/null; then
        # 程序收到终止信号后会正常退出，把鼠标设置恢复原样
        pkill -TERM -x WinShun || true
        sleep 1
    fi
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    open "$INSTALLED"
    echo "已安装并启动：$INSTALLED"
fi
