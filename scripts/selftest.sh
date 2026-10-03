#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 真机自测：Win顺 自己模拟按键、滚轮、鼠标侧键，经过事件拦截后检查效果。
# 需要先授权（辅助功能、输入监控），并先运行 scripts/build-app.sh。
# 运行期间约一分钟，不要操作键盘和鼠标。会弹出测试窗口、打开 Finder 和聚焦搜索，并切换一次程序。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Win顺.app"
LOG="$(mktemp -t winshun-selftest)"

WAS_RUNNING=0
if pgrep -x WinShun >/dev/null; then
    WAS_RUNNING=1
    pkill -TERM -x WinShun || true
    sleep 1
fi

# scripts/selftest.sh window 只测分屏（十几秒）
ARG="--self-test"
[[ "${1:-}" == "window" ]] && ARG="--self-test-window"
open -n -W --stdout "$LOG" --stderr "$LOG" "$APP" --args "$ARG" || true
cat "$LOG"

if [[ $WAS_RUNNING == 1 ]]; then
    open "$APP"
fi

grep -q "失败 0 项" "$LOG"
