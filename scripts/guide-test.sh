#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 授权引导自测：真的打开“系统设置”的几页，检查引导浮窗的位置、列表里有没有 Mac顺、授权后是否自动进入下一项。
# 不会关掉或改动任何权限（“未授权”是假装的）。需要辅助功能权限，并先运行 scripts/build-app.sh。
# 大约半分钟，期间不要操作鼠标键盘。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Mac顺.app"
LOG="$(mktemp -t macshun-guidetest)"

WAS_RUNNING=0
if pgrep -x MacShun >/dev/null; then
    WAS_RUNNING=1
    pkill -TERM -x MacShun || true
    sleep 1
fi

open -n -W --stdout "$LOG" --stderr "$LOG" "$APP" --args --guide-test || true
cat "$LOG"

if [[ $WAS_RUNNING == 1 ]]; then
    open "$APP"
fi

grep -q "失败 0 项" "$LOG"
