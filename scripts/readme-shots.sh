#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 重新生成 README 里的截图（docs/images 下中文、英文 × 浅色、深色各一套）。
# 用假数据离屏渲染（scripts/readme-shots/main.swift），不碰真实配置、剪贴板历史和系统设置。
#
# 用法：
#   scripts/readme-shots.sh            全部重新生成
#   scripts/readme-shots.sh search     只生成一种：keyboard、mouse、display、panel、search、snap

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 和程序一起编译（不要 MacShunMain.swift 里的入口），DEBUG 才有截图用的假数据入口
SOURCES=()
while IFS= read -r -d '' file; do SOURCES+=("$file"); done \
    < <(find "$ROOT/Sources/MacShun" -name '*.swift' ! -name MacShunMain.swift -print0)
swiftc -O -D DEBUG -swift-version 5 -o "$WORK/shots" "$ROOT/scripts/readme-shots/main.swift" "${SOURCES[@]}" -lsqlite3
# 界面文字和图片从程序旁边的 .lproj 里找
rsync -a --exclude Info.plist "$ROOT/Resources/" "$WORK/"

for look in light dark; do
    "$WORK/shots" "$ROOT/docs/images" "$look" zh ${1:-} -AppleLanguages "(zh-Hans)"
    "$WORK/shots" "$ROOT/docs/images" "$look" en ${1:-} -AppleLanguages "(en)"
done
echo "已更新 docs/images"
