#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 打包发布版：同时支持 Apple Silicon 和 Intel 的通用程序，装进 dist/MacShun-<版本>.dmg，
# 旁边生成 .sha256 校验文件。版本号取自 Resources/Info.plist 的 CFBundleShortVersionString。
#
# 用法：
#   scripts/release.sh                 只打包
#   scripts/release.sh --publish       打包后在 GitHub 上建 v<版本> 的 Release 并上传（需要 gh 已登录）
#
# 目前没有 Apple 开发者证书，程序没有经过公证：用户第一次打开时要在“隐私与安全性”里点“仍要打开”，
# README 里写了步骤。以后有了 Developer ID，在这里加上签名和 notarytool 公证即可。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Mac顺"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
DMG="$DIST/MacShun-$VERSION.dmg"

cd "$ROOT"
scripts/test.sh
UNIVERSAL=1 scripts/build-app.sh

APP="$ROOT/build/$APP_NAME.app"
# 自动更新只装和正在运行的版本同一张证书签的程序（见 Sources/MacShun/App/Updater.swift），临时签名的发出去，旧版本更新不了
codesign -dvv "$APP" 2>&1 | grep -qx "Authority=WinShun Development" \
    || { echo "错误：程序没有用开发证书签名（先运行 scripts/dev-cert.sh），发出去旧版本没法自动更新" >&2; exit 1; }
ARCHS="$(lipo -archs "$APP/Contents/MacOS/MacShun")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "错误：程序不是通用版（${ARCHS}）" >&2; exit 1; }

# 磁盘映像里放程序和一个指向“应用程序”文件夹的替身，用户拖过去就装好了
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "已生成：${DMG}（${ARCHS}）"

if [[ "${1:-}" == "--publish" ]]; then
    TAG="v$VERSION"
    NOTES="$ROOT/docs/release-notes/$TAG.md"
    [[ -f "$NOTES" ]] || { echo "错误：缺少发布说明 $NOTES" >&2; exit 1; }
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "$APP_NAME $VERSION" --notes-file "$NOTES"
fi
