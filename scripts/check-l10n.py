#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# 检查界面文字的翻译：
#   1. 代码里每个 L("…") 在 Resources/en.lproj 里都有英文；
#   2. 界面代码里没有漏掉 L() 的中文文字（日志、注释、自测、拼音表除外）；
#   3. 译文里的 %@、%ld 和原文一致。
# 用法：scripts/check-l10n.py          检查，有问题时返回非 0
#       scripts/check-l10n.py --keys   列出所有键

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "MacShun"
STRINGS = ROOT / "Resources" / "en.lproj" / "Localizable.strings"
STRINGSDICT = ROOT / "Resources" / "en.lproj" / "Localizable.stringsdict"

# 不是界面文字的文件：自测输出、拼音表、按名字识别程序、搜索用的文件夹别名
SKIP_FILES = {"SelfTest.swift", "GuideTest.swift", "Pinyin.swift", "AppCatalog.swift", "FolderAliases.swift"}
# 不是界面文字的行
SKIP_LINE = re.compile(r"Log\.|appendingPathComponent|lower\.contains|summary = |\+ \"读取剪贴板|label: \"|keywords: \"|\"简体中文\"")
# 设置搜索目录里的标题：存的是键，显示时才翻译
CATALOG_TITLE = re.compile(r'title: "((?:[^"\\\n]|\\.)*)"')

LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
L_CALL = re.compile(r'(?<![A-Za-z_])L\("((?:[^"\\\n]|\\.)*)"')
HAN = re.compile(r"[一-鿿]")
FORMAT = re.compile(r"%(?:\d+\$)?(?:@|ld|lld|d|lf|f)")


def code_part(line: str) -> str:
    """去掉行尾注释。"""
    in_string = escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
    return line


def parse_strings(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    return {k.replace('\\"', '"'): v.replace('\\"', '"') for k, v in pairs}


def main() -> int:
    keys: dict[str, str] = {}
    unwrapped = []
    for path in sorted(SOURCES.rglob("*.swift")):
        if path.name in SKIP_FILES:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip().startswith("//") or SKIP_LINE.search(line):
                continue
            code = code_part(line)
            if path.name == "SettingsSearch.swift":
                for key in CATALOG_TITLE.findall(code):
                    keys.setdefault(key, f"{path.name}:{number}")
                code = CATALOG_TITLE.sub("", code)
            for key in L_CALL.findall(code):
                keys.setdefault(key.replace('\\"', '"'), f"{path.name}:{number}")
            for match in LITERAL.finditer(code):
                if HAN.search(match.group(1)) and code[max(0, match.start() - 2):match.start()] != "L(":
                    unwrapped.append(f"{path.relative_to(ROOT)}:{number}: {match.group(0)}")

    if "--keys" in sys.argv:
        for key, where in keys.items():
            print(f"{where}\t{key}")
        return 0

    english = parse_strings(STRINGS) if STRINGS.exists() else {}
    plurals = plistlib.loads(STRINGSDICT.read_bytes()) if STRINGSDICT.exists() else {}
    problems = []
    for key, where in keys.items():
        if key in plurals:
            continue
        if key not in english:
            problems.append(f"缺英文：{where}  {key}")
        elif sorted(FORMAT.findall(key)) != sorted(FORMAT.findall(english[key])):
            problems.append(f"格式不一致：{key}  →  {english[key]}")
    for key in english:
        if key not in keys and key not in plurals:
            problems.append(f"没用到的译文：{key}")
    problems += [f"没包 L()：{u}" for u in unwrapped]

    for p in problems:
        print(p)
    print(f"{len(keys)} 句界面文字，{len(problems)} 个问题")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
