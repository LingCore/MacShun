#!/bin/bash
# SPDX-License-Identifier: MIT
#
# 运行单元测试。
#
# 只装了 Command Line Tools（没装 Xcode）时，Swift Testing 的宏插件放在 plugins/testing 子目录里，
# 编译器默认找不到，这里把路径告诉它。装了 Xcode 时不需要。

set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
PLUGIN="$(xcode-select -p 2>/dev/null || true)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGIN" ]]; then
    ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN")
fi
LOG="$(mktemp -t macshun-tests)"
trap 'rm -f "$LOG"' EXIT
run_tests() {
    swift test ${ARGS[@]+"${ARGS[@]}"} "$@" 2>&1 | tee "$LOG"
    # Swift 6.2+ 的宿主可能在 AppKit 停止主运行循环后提前 exit(0)。
    # https://github.com/swiftlang/swift/issues/91716
    # 退出码本身不足以证明测试已完成；发布检查必须看到最终汇总。
    for arg in "$@"; do
        case "$arg" in --help|--help-hidden|--list-tests|list|--debugger) return ;; esac
    done
    grep -Eq 'Test run with .* passed after' "$LOG" \
        || { echo "错误：测试未输出完整的成功汇总，不能视为通过" >&2; exit 1; }
}

if [[ $# -gt 0 ]]; then
    run_tests "$@"
else
    # 这些套件共享 AppKit 的进程级窗口、焦点和事件循环状态，分别运行。
    # 不跳过任何用例；剩余纯逻辑测试仍在同一进程并行运行。
    UI_SUITES=(CaptureTests CaptureAnnotationTests ScrollStitcherTests ClipboardImageTests SearchCompositionTests FileSearchLayoutTests FolderScopeTests)
    UI_PATTERN="$(IFS='|'; echo "${UI_SUITES[*]}")"
    run_tests --skip "$UI_PATTERN"
    for suite in "${UI_SUITES[@]}"; do
        run_tests --skip-build --filter "$suite"
    done
fi
