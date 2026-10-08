#!/bin/bash
# SPDX-License-Identifier: MIT
#
# 真机测试自动更新（见 Sources/MacShun/App/Updater.swift）：在本机搭一个假的 GitHub 发布，
# 让一份临时的 Mac顺 自己检查、下载、核对、替换并重新打开。不碰“应用程序”里装的那份。
#   1. 用开发证书签的 99.0.0：应该装上，并且新版本自己打开；
#   2. 临时签名（签名和现在的不一致）的 99.0.0：应该拒绝，原来的程序不动。
# 需要先运行 scripts/build-app.sh。运行期间会退出正在运行的 Mac顺，测完再打开。
#
# 用法：scripts/update-test.sh [要测的 .app，默认 build/Mac顺.app]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-$ROOT/build/Mac顺.app}"
IDENTITY="WinShun Development"
KEYCHAIN="$HOME/Library/Keychains/winshun-dev.keychain-db"
KEYCHAIN_PASSWORD="winshun-dev"
WORK="$(mktemp -d -t macshun-update-test)"
PORT=$((20000 + RANDOM % 10000))
SERVER_PID=""
FAILED=0
WAS_RUNNING=0

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    pkill -TERM -f "$WORK/" 2>/dev/null || true
    sleep 1
    rm -rf "$WORK"
    # 测之前开着的，测完（包括中途出错）重新打开
    if [[ $WAS_RUNNING == 1 ]]; then
        open "/Applications/Mac顺.app" 2>/dev/null || open "$SOURCE_APP"
    fi
}
trap cleanup EXIT

pass() { echo "✔ $1"; }
fail() { echo "✘ $1"; FAILED=$((FAILED + 1)); }
# 最近两分钟 Mac顺 的日志（先存下来再查：pipefail 下 grep -q 提前退出会让整条管道算失败）
recent_log() { /usr/bin/log show --last 2m --style compact --predicate 'subsystem == "io.github.lingcore.winshun"' 2>/dev/null; }
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }

[[ -d "$SOURCE_APP" ]] || { echo "没有 $SOURCE_APP，先运行 scripts/build-app.sh" >&2; exit 1; }
OLD_VERSION="$(version_of "$SOURCE_APP")"

if pgrep -x MacShun >/dev/null; then
    WAS_RUNNING=1
    pkill -TERM -x MacShun || true
    sleep 1
fi

# 做一个假的新版本：版本号改成 99.0.0，重新签名，装进 dmg。sign 是 dev（开发证书）或 adhoc（临时签名）
make_release() {
    local sign="$1" dir="$WORK/release-$1"
    mkdir -p "$dir/stage"
    ditto "$SOURCE_APP" "$dir/stage/Mac顺.app"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 99.0.0' "$dir/stage/Mac顺.app/Contents/Info.plist"
    if [[ "$sign" == dev ]]; then
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
        codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$dir/stage/Mac顺.app"
    else
        codesign --force --sign - "$dir/stage/Mac顺.app"
    fi
    ln -s /Applications "$dir/stage/Applications"
    hdiutil create -quiet -volname "Mac顺 99.0.0" -srcfolder "$dir/stage" -fs HFS+ -format UDZO "$dir/MacShun-99.0.0.dmg"
    local sha size
    sha="$(shasum -a 256 "$dir/MacShun-99.0.0.dmg" | cut -d' ' -f1)"
    size="$(stat -f %z "$dir/MacShun-99.0.0.dmg")"
    # 和 GitHub 接口 /releases/latest 的回答一样的格式
    cat > "$dir/latest.json" <<JSON
{"tag_name": "v99.0.0", "html_url": "https://github.com/LingCore/MacShun/releases", "body": "测试。Test.",
 "assets": [{"name": "MacShun-99.0.0.dmg", "size": $size, "digest": "sha256:$sha",
             "browser_download_url": "http://127.0.0.1:$PORT/release-$sign/MacShun-99.0.0.dmg"}]}
JSON
}

# 放一份旧版本到临时文件夹，带着假发布的地址打开，等它自己更新
run_case() {
    local sign="$1" target="$WORK/target-$1/Mac顺.app"
    mkdir -p "$(dirname "$target")"
    ditto "$SOURCE_APP" "$target"
    open -n --env "MACSHUN_UPDATE_FEED=http://127.0.0.1:$PORT/release-$sign/latest.json" \
        --env MACSHUN_UPDATE_AUTOINSTALL=1 "$target"
    sleep 0.5
    local first new=""
    first="$(pgrep -f "$target/Contents/MacOS/MacShun" || true)"
    for _ in $(seq 1 40); do
        sleep 0.5
        new="$(pgrep -f "$target/Contents/MacOS/MacShun" || true)"
        [[ "$(version_of "$target")" == 99.0.0 && -n "$new" && "$new" != "$first" ]] && break
    done
    # 看看程序报了什么
    sleep 2
    if [[ "$sign" == dev ]]; then
        [[ "$(version_of "$target")" == 99.0.0 ]] && pass "换成了新版本" || fail "没有换成新版本（还是 $(version_of "$target")）"
        codesign --verify --strict "$target" 2>/dev/null && pass "新版本签名完好" || fail "新版本签名不对"
        [[ -n "$first" && -n "$new" && "$new" != "$first" ]] && pass "旧版本退出，新版本自己打开了（${first} → ${new}）" \
            || fail "新版本没有打开（${first} → ${new}）"
        grep -q "已更新到 99.0.0" <<< "$(recent_log)" && pass "日志里记下了更新" || fail "日志里没有更新的记录"
        [[ -z "$(ls -A "$(dirname "$target")" | grep -v '^Mac顺.app$' || true)" ]] && pass "没有留下临时文件" \
            || fail "文件夹里多了：$(ls -A "$(dirname "$target")")"
        xattr -p com.apple.quarantine "$target" >/dev/null 2>&1 && fail "新版本带了隔离标记，打开时会被拦" || pass "新版本没有隔离标记"
    else
        [[ "$(version_of "$target")" == "$OLD_VERSION" ]] && pass "签名不一致的版本没有装" || fail "签名不一致的版本被装上了"
        grep -q "新版本的签名不对" <<< "$(recent_log)" && pass "日志里记下了签名不对" || fail "日志里没有签名不对的记录"
        hdiutil info | grep -q "$WORK" && fail "安装包没有推出" || pass "安装包已经推出"
    fi
    pkill -TERM -f "$target/Contents/MacOS/MacShun" 2>/dev/null || true
    sleep 1
}

make_release dev
make_release adhoc
(cd "$WORK" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1

echo "— 同一张证书签的新版本"
run_case dev
echo "— 签名不一致的新版本"
run_case adhoc

echo "失败 $FAILED 项"
[[ $FAILED == 0 ]]
