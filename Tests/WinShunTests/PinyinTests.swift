// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import WinShun

@Suite("C2 拼音搜索")
struct PinyinTests {
    private func matches(_ text: String, _ query: String) -> Bool {
        PinyinIndex(text: text).matches(query)
    }

    @Test func initialsAndFullPinyin() {
        #expect(matches("剪贴板", "jtb"))
        #expect(matches("剪贴板", "jiantieban"))
        #expect(matches("剪贴板", "tieban"))
        #expect(matches("剪贴板", "JTB"))
        #expect(!matches("剪贴板", "jtx"))
        #expect(!matches("剪贴板", "bantie"))
    }

    @Test func mixedFullAndInitials() {
        #expect(matches("剪贴板", "jiantb"))
        #expect(matches("剪贴板", "jtieb"))
    }

    @Test func chineseQuery() {
        #expect(matches("这是剪贴板历史", "剪贴"))
        #expect(!matches("这是剪贴板历史", "剪刀"))
    }

    @Test func middleOfText() {
        #expect(matches("请把这段文字复制一下", "fz"))
        #expect(matches("请把这段文字复制一下", "wenzi"))
    }

    @Test func polyphonicCorrections() {
        #expect(matches("银行卡号", "yhkh"))
        #expect(matches("银行卡号", "yinhang"))
        #expect(!matches("银行卡号", "yinxing"))
        #expect(matches("收货地址", "shdz"))
        #expect(matches("收货地址", "dizhi"))
        #expect(matches("长度", "changdu"))
        #expect(matches("校长", "xiaozhang"))
        #expect(matches("重新启动", "chongxin"))
        #expect(matches("请重启电脑", "cq"))
        #expect(matches("网易云音乐", "yinyue"))
        #expect(matches("模板文件", "muban"))
    }

    @Test func uUmlaut() {
        #expect(matches("绿色", "lvse"))
        #expect(matches("绿色", "luse"))
        #expect(matches("绿色", "ls"))
    }

    @Test func englishAndMixed() {
        #expect(matches("Hello World", "hello"))
        #expect(matches("Hello World", "WORLD"))
        #expect(matches("微信WeChat", "wxwechat"))
        #expect(matches("微信WeChat", "wechat"))
        #expect(matches("订单号 20261002", "20261002"))
        #expect(!matches("Hello World", "help"))
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(matches("任何内容", ""))
        #expect(matches("任何内容", "   "))
    }

    @Test func syllables() {
        #expect(Pinyin.syllables(of: Array("剪贴板")) == ["jian", "tie", "ban"])
        #expect(Pinyin.syllables(of: Array("银行")) == ["yin", "hang"])
        #expect(Pinyin.syllables(of: Array("a银行b")) == ["a", "yin", "hang", "b"])
        #expect(Pinyin.syllable(for: "绿") == "lv")
    }
}
