#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 编译并打包成 build/Mac顺.app，用开发证书签名（先运行一次 scripts/dev-cert.sh）。
#
# 用法：
#   scripts/build-app.sh            编译打包
#   scripts/build-app.sh --install  编译打包，装到“应用程序”文件夹并启动
#   UNIVERSAL=1 scripts/build-app.sh  同时编译 Apple Silicon 和 Intel 版本，合成一个程序（发布用，见 release.sh）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Mac顺"
APP="$ROOT/build/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"
# 证书名和钥匙串沿用改名前（Win顺）的：换一张证书签名就变了，所有人都要重新授权
IDENTITY="WinShun Development"
KEYCHAIN="$HOME/Library/Keychains/winshun-dev.keychain-db"
KEYCHAIN_PASSWORD="winshun-dev"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

cd "$ROOT"
# macOS 自带的 bash 3.2 里，空数组配 set -u 会报错，所以写成 ${A[@]+"${A[@]}"}
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacShun" "$APP/Contents/MacOS/MacShun"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # 图标由 scripts/make-icon.py 生成
cp "$ROOT/Resources/AppGlyph.svg" "$APP/Contents/Resources/AppGlyph.svg"   # 不带底板的矢量标志，“拾穗计划”页用
cp "$ROOT/Resources/AuthorAvatar.png" "$APP/Contents/Resources/AuthorAvatar.png"   # 作者头像，“拾穗计划”页用
# 界面文字：英文译文和中文（中文就是代码里的原文），见 scripts/check-l10n.py
for lang in en zh-Hans; do
    cp -R "$ROOT/Resources/$lang.lproj" "$APP/Contents/Resources/$lang.lproj"
done

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
    # 改名前的进程叫 WinShun、装在 Win顺.app，一并退出、删掉
    for process in MacShun WinShun; do
        if pgrep -x "$process" >/dev/null; then
            # 程序收到终止信号后会正常退出，把鼠标设置恢复原样
            pkill -TERM -x "$process" || true
            sleep 1
        fi
    done
    rm -rf "$INSTALLED" "/Applications/Win顺.app"
    ditto "$APP" "$INSTALLED"
    open "$INSTALLED"
    echo "已安装并启动：$INSTALLED"
fi
