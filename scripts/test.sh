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

swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
