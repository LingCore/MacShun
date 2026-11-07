#!/bin/bash
# SPDX-License-Identifier: MIT
# 需要已授权辅助功能的工作版。仅在独立的临时文件面板中测试。
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Mac顺.app"
test_tmp=${TMPDIR:-/tmp}
tmp=$(mktemp -d "${test_tmp%/}/macshun-dialog-test.XXXXXX")
fixture="$tmp/DialogFixture.app"
mkdir -p "$fixture/Contents/MacOS"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.lingcore.qa.dialogfixture</string>
<key>CFBundleExecutable</key><string>DialogFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
was_running=0
cleanup() {
    if [[ -n "${session:-}" ]]; then touch "$session/stop"; fi
    if [[ -n "${host_job:-}" ]]; then wait "$host_job" || true; fi
    /usr/bin/find "$tmp" -depth -delete
    if [[ "$was_running" == 1 ]] && ! pgrep -x MacShun >/dev/null; then open -ng "$app"; fi
}
trap cleanup EXIT
swiftc scripts/fixtures/FileDialog.swift -o "$fixture/Contents/MacOS/DialogFixture"
codesign --force --sign - "$fixture"

# 两个实例同时监听双击 Ctrl 会争抢焦点。只暂停并恢复此工作副本。
for pid in $(pgrep -x MacShun || true); do
    [[ "$(ps -p "$pid" -o comm=)" == "$app/Contents/MacOS/MacShun" &&
       "$(ps -p "$pid" -o command=)" != *--*test* ]] || { echo "其他版本或自测正在运行"; exit 1; }
done
for pid in $(pgrep -x MacShun || true); do
    was_running=1
    kill -TERM "$pid"
    for ((i=0; i<50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then echo "工作版仍在运行"; exit 1; fi
done
for mode in open open-sheet save save-sheet; do
    session="$tmp/$mode"
    folder="$session/项目 资料"
    mkdir -p "$session/起点" "$folder"
    file="$folder/报价.txt"
    touch "$file"
    case "$mode" in open|save-sheet) query="$file";; *) query="$folder";; esac
    open -n -W --stdout "$session/host.log" "$fixture" --args "$mode" "$session" &
    host_job=$!
    open -ng -W --stdout "$session/test.log" "$app" --args --self-test-file-dialog "$query" "$session/arrived"
    cat "$session/test.log"
    grep -q "失败 0 项" "$session/test.log"
    for ((i=0; i<50; i++)); do [[ -f "$session/arrived" ]] && break; sleep 0.1; done
    [[ -f "$session/arrived" ]] && ! grep -q 'Unexpected submission' "$session/host.log" || { echo "$mode: 目录、文件名或面板状态有误"; exit 1; }
    touch "$session/stop"; wait "$host_job"; host_job=""
    echo "$mode: 已到达目标目录，原面板等待确认。"
done
