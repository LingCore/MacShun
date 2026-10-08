// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import MacShun

private let cmd = CGEventFlags.maskCommand
private let opt = CGEventFlags.maskAlternate
private let ctrl = CGEventFlags.maskControl
private let shift = CGEventFlags.maskShift

private func mapper(_ layout: KeyboardLayoutKind = .windows, _ edit: (inout KeyboardConfig) -> Void = { _ in }) -> KeyMapper {
    var config = KeyboardConfig()
    config.layout = layout
    edit(&config)
    return KeyMapper(config: config)
}

private func context(
    _ kind: AppKind = .normal, browser: Bool = false, focus: FocusKind = .unknown,
    clipboard: Bool = true, chat: Bool = false, inputSource: String? = nil
) -> KeyContext {
    KeyContext(
        appKind: kind, isBrowser: browser, clipboardEnabled: clipboard,
        chatAppRunning: chat, inputSourceID: inputSource, focus: { focus }
    )
}

private func send(_ key: CGKeyCode, _ flags: CGEventFlags = []) -> KeyAction {
    .send(KeyStroke(key, flags))
}

@Suite("K1 Ctrl 组合键")
struct CtrlAsCommandTests {
    @Test func ctrlLetterBecomesCommand() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: context()) == send(KeyCode.c, cmd))
        #expect(m.action(keyCode: KeyCode.v, flags: ctrl, context: context()) == send(KeyCode.v, cmd))
        #expect(m.action(keyCode: KeyCode.s, flags: ctrl, context: context()) == send(KeyCode.s, cmd))
        #expect(m.action(keyCode: KeyCode.one, flags: ctrl, context: context()) == send(KeyCode.one, cmd))
        #expect(m.action(keyCode: KeyCode.slash, flags: ctrl, context: context()) == send(KeyCode.slash, cmd))
    }

    @Test func shiftIsKept() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.z, flags: [ctrl, shift], context: context()) == send(KeyCode.z, [cmd, shift]))
    }

    @Test func ctrlYIsRedo() {
        #expect(mapper().action(keyCode: KeyCode.y, flags: ctrl, context: context()) == send(KeyCode.z, [cmd, shift]))
    }

    @Test func dangerousKeysAreNotRemapped() {
        let m = mapper()
        for key in [KeyCode.h, KeyCode.m, KeyCode.q, KeyCode.grave, KeyCode.space, KeyCode.tab, KeyCode.returnKey] {
            #expect(m.action(keyCode: key, flags: ctrl, context: context()) == .pass)
        }
    }

    /// 微信、QQ 的 ⌃⌘A 截图要原样保留。
    @Test func ctrlWithCommandIsUntouched() {
        #expect(mapper().action(keyCode: KeyCode.a, flags: [ctrl, cmd], context: context()) == .pass)
    }

    @Test func nativeCommandShortcutsStillWork() {
        #expect(mapper().action(keyCode: KeyCode.c, flags: cmd, context: context()) == .pass)
        #expect(mapper(.mac).action(keyCode: KeyCode.c, flags: cmd, context: context()) == .pass)
    }

    @Test func macLayoutUsesControlAsCtrl() {
        #expect(mapper(.mac).action(keyCode: KeyCode.c, flags: ctrl, context: context()) == send(KeyCode.c, cmd))
    }

    @Test func disabled() {
        let m = mapper { $0.ctrlAsCommand = false }
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: context()) == .pass)
        let off = mapper { $0.enabled = false }
        #expect(off.action(keyCode: KeyCode.c, flags: ctrl, context: context()) == .pass)
    }

    /// 普通的 Ctrl 组合键不需要查询焦点（查询焦点是跨进程调用）。
    @Test func doesNotQueryFocusUnlessNeeded() {
        var queried = 0
        let ctx = KeyContext(appKind: .normal, isBrowser: false, clipboardEnabled: true) {
            queried += 1
            return .text
        }
        _ = mapper().action(keyCode: KeyCode.c, flags: ctrl, context: ctx)
        #expect(queried == 0)
        _ = mapper().action(keyCode: KeyCode.home, flags: [], context: ctx)
        #expect(queried == 1)
    }
}

@Suite("K2 文字光标")
struct TextNavigationTests {
    @Test func homeEndInText() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.home, flags: [], context: context(focus: .text)) == send(KeyCode.leftArrow, cmd))
        #expect(m.action(keyCode: KeyCode.end, flags: shift, context: context(focus: .text)) == send(KeyCode.rightArrow, [cmd, shift]))
    }

    @Test func homeEndOutsideTextKeepsScrolling() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.home, flags: [], context: context(focus: .browsing)) == .pass)
        #expect(m.action(keyCode: KeyCode.end, flags: [], context: context(focus: .other)) == .pass)
    }

    /// 浏览器里 ⌘← 是“后退”，问不到焦点时不能改写。
    @Test func browserNeedsConfirmedTextFocus() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.home, flags: [], context: context(browser: true, focus: .unknown)) == .pass)
        #expect(m.action(keyCode: KeyCode.home, flags: [], context: context(browser: true, focus: .text)) == send(KeyCode.leftArrow, cmd))
        #expect(m.action(keyCode: KeyCode.home, flags: [], context: context(browser: false, focus: .unknown)) == send(KeyCode.leftArrow, cmd))
    }

    @Test func ctrlHomeEnd() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.home, flags: ctrl, context: context(focus: .text)) == send(KeyCode.upArrow, cmd))
        #expect(m.action(keyCode: KeyCode.end, flags: [ctrl, shift], context: context(focus: .text)) == send(KeyCode.downArrow, [cmd, shift]))
        #expect(m.action(keyCode: KeyCode.home, flags: ctrl, context: context(focus: .browsing)) == send(KeyCode.home))
    }

    @Test func wordMovementAndDeletion() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.leftArrow, flags: ctrl, context: context()) == send(KeyCode.leftArrow, opt))
        #expect(m.action(keyCode: KeyCode.rightArrow, flags: [ctrl, shift], context: context()) == send(KeyCode.rightArrow, [opt, shift]))
        #expect(m.action(keyCode: KeyCode.backspace, flags: ctrl, context: context()) == send(KeyCode.backspace, opt))
        #expect(m.action(keyCode: KeyCode.forwardDelete, flags: ctrl, context: context()) == send(KeyCode.forwardDelete, opt))
    }
}

@Suite("K3 系统快捷键")
struct SystemShortcutTests {
    @Test func altTab() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.tab, flags: opt, context: context()) == .appSwitcher(reverse: false))
        #expect(m.action(keyCode: KeyCode.tab, flags: [opt, shift], context: context()) == .appSwitcher(reverse: true))
    }

    /// Mac 模式下 Alt 就是 ⌘，⌘Tab 本来就能用。
    @Test func altTabOnMacKeyboardIsNative() {
        #expect(mapper(.mac).action(keyCode: KeyCode.tab, flags: cmd, context: context()) == .pass)
    }

    /// 不管设置是哪种模式，⌥Tab 和 ⌘Tab 都能切换程序（键盘刚切换了模式也一样）。
    @Test func altTabWorksInEitherMode() {
        #expect(mapper(.mac).action(keyCode: KeyCode.tab, flags: opt, context: context()) == .appSwitcher(reverse: false))
        #expect(mapper().action(keyCode: KeyCode.tab, flags: cmd, context: context()) == .pass)
        #expect(mapper().action(keyCode: KeyCode.tab, flags: [cmd, shift], context: context()) == .pass)
    }

    @Test func altF4QuitsAppInEitherMode() {
        for layout in KeyboardLayoutKind.allCases {
            #expect(mapper(layout).action(keyCode: KeyCode.f4, flags: opt, context: context()) == send(KeyCode.q, cmd))
            #expect(mapper(layout).action(keyCode: KeyCode.f4, flags: cmd, context: context()) == send(KeyCode.q, cmd))
        }
    }

    @Test func winShortcuts() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.e, flags: cmd, context: context()) == .command(.openFinder))
        #expect(m.action(keyCode: KeyCode.d, flags: cmd, context: context()) == .command(.showDesktop))
        #expect(m.action(keyCode: KeyCode.l, flags: cmd, context: context()) == .command(.lockScreen))
        #expect(m.action(keyCode: KeyCode.s, flags: cmd, context: context()) == .command(.spotlight))
        #expect(m.action(keyCode: KeyCode.space, flags: cmd, context: context()) == .command(.switchInputSource))
    }

    /// ⌥ 一定当 Win 用，所以键盘切到 Mac 模式后 Win+V/E/L/S 马上能用。
    @Test func optionLettersAreWinInEitherMode() {
        let m = mapper(.windows)
        #expect(m.action(keyCode: KeyCode.v, flags: opt, context: context()) == .command(.clipboardHistory))
        #expect(m.action(keyCode: KeyCode.e, flags: opt, context: context()) == .command(.openFinder))
        #expect(m.action(keyCode: KeyCode.l, flags: opt, context: context()) == .command(.lockScreen))
        #expect(m.action(keyCode: KeyCode.s, flags: opt, context: context()) == .command(.spotlight))
        // Alt+D（地址栏的习惯）、⌥Space（启动器常用）不动，按当前模式认 Win 键。
        #expect(m.action(keyCode: KeyCode.d, flags: opt, context: context()) == .pass)
        #expect(m.action(keyCode: KeyCode.space, flags: opt, context: context()) == .pass)
        #expect(mapper(.mac).action(keyCode: KeyCode.d, flags: opt, context: context()) == .command(.showDesktop))
        #expect(mapper(.mac).action(keyCode: KeyCode.space, flags: opt, context: context()) == .command(.switchInputSource))
    }

    @Test func winShortcutsOnMacKeyboardUseOption() {
        let m = mapper(.mac)
        #expect(m.action(keyCode: KeyCode.e, flags: opt, context: context()) == .command(.openFinder))
        #expect(m.action(keyCode: KeyCode.e, flags: cmd, context: context()) == .pass)
    }

    @Test func winV() {
        #expect(mapper().action(keyCode: KeyCode.v, flags: cmd, context: context()) == .command(.clipboardHistory))
        #expect(mapper().action(keyCode: KeyCode.v, flags: cmd, context: context(clipboard: false)) == .pass)
        // 关掉系统快捷键时 Win+V 仍然呼出剪贴板历史。
        let m = mapper { $0.systemShortcuts = false }
        #expect(m.action(keyCode: KeyCode.v, flags: cmd, context: context()) == .command(.clipboardHistory))
        #expect(m.action(keyCode: KeyCode.e, flags: cmd, context: context()) == .pass)
    }
}

@Suite("K4 Finder")
struct FinderTests {
    private let fileList = context(.finder, focus: .browsing)

    @Test func fileOperations() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.f2, flags: [], context: fileList) == send(KeyCode.returnKey))
        #expect(m.action(keyCode: KeyCode.returnKey, flags: [], context: fileList) == send(KeyCode.downArrow, cmd))
        #expect(m.action(keyCode: KeyCode.keypadEnter, flags: [], context: fileList) == send(KeyCode.downArrow, cmd))
        #expect(m.action(keyCode: KeyCode.forwardDelete, flags: [], context: fileList) == send(KeyCode.backspace, cmd))
        #expect(m.action(keyCode: KeyCode.backspace, flags: [], context: fileList) == send(KeyCode.upArrow, cmd))
        #expect(m.action(keyCode: KeyCode.x, flags: ctrl, context: fileList) == .finderCut)
        #expect(m.action(keyCode: KeyCode.v, flags: ctrl, context: fileList) == .finderPaste)
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: fileList) == send(KeyCode.c, cmd))
    }

    /// 正在重命名或在搜索框里时，按键保持输入框的行为。
    @Test func textFieldInFinderIsUntouched() {
        let m = mapper()
        let renaming = context(.finder, focus: .text)
        #expect(m.action(keyCode: KeyCode.returnKey, flags: [], context: renaming) == .pass)
        #expect(m.action(keyCode: KeyCode.backspace, flags: [], context: renaming) == .pass)
        #expect(m.action(keyCode: KeyCode.forwardDelete, flags: [], context: renaming) == .pass)
        #expect(m.action(keyCode: KeyCode.x, flags: ctrl, context: renaming) == send(KeyCode.x, cmd))
    }

    /// 问不到焦点时按 Mac 原样处理，避免误删文件。
    @Test func unknownFocusIsSafe() {
        let m = mapper()
        let unknown = context(.finder, focus: .unknown)
        #expect(m.action(keyCode: KeyCode.forwardDelete, flags: [], context: unknown) == .pass)
        #expect(m.action(keyCode: KeyCode.returnKey, flags: [], context: unknown) == .pass)
        #expect(m.action(keyCode: KeyCode.returnKey, flags: [], context: context(.finder, focus: .other)) == .pass)
    }

    @Test func onlyInFinder() {
        #expect(mapper().action(keyCode: KeyCode.f2, flags: [], context: context(.normal, focus: .browsing)) == .pass)
    }
}

@Suite("K5 终端、K6 远程桌面")
struct SpecialAppTests {
    @Test func terminalKeepsCtrl() {
        let m = mapper()
        let terminal = context(.terminal, focus: .text)
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: terminal) == .pass)
        #expect(m.action(keyCode: KeyCode.a, flags: ctrl, context: terminal) == .pass)
        #expect(m.action(keyCode: KeyCode.leftArrow, flags: ctrl, context: terminal) == .pass)
        #expect(m.action(keyCode: KeyCode.home, flags: [], context: terminal) == .pass)
        #expect(m.action(keyCode: KeyCode.c, flags: [ctrl, shift], context: terminal) == send(KeyCode.c, cmd))
        #expect(m.action(keyCode: KeyCode.v, flags: [ctrl, shift], context: terminal) == send(KeyCode.v, cmd))
        // 系统快捷键在终端里照常。
        #expect(m.action(keyCode: KeyCode.tab, flags: opt, context: terminal) == .appSwitcher(reverse: false))
    }

    @Test func remoteDesktopGetsEverything() {
        let m = mapper()
        let remote = context(.excluded)
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: remote) == .pass)
        #expect(m.action(keyCode: KeyCode.tab, flags: opt, context: remote) == .pass)
        #expect(m.action(keyCode: KeyCode.v, flags: cmd, context: remote) == .pass)
        #expect(m.action(keyCode: KeyCode.e, flags: cmd, context: remote) == .pass)
    }

    @Test func appCatalog() {
        func kind(_ id: String?, _ name: String? = nil, excluded: [String] = []) -> AppKind {
            AppCatalog.kind(of: AppIdentity(bundleID: id, name: name), userExcluded: excluded)
        }
        #expect(kind("com.apple.Terminal") == .terminal)
        #expect(kind("com.googlecode.iterm2") == .terminal)
        #expect(kind("com.apple.finder") == .finder)
        #expect(kind("com.youqu.todesk.mac") == .excluded)
        #expect(kind("com.netease.uuremote") == .excluded)
        #expect(kind("com.oray.sunlogin.macclient") == .excluded)
        #expect(kind("com.parallels.winapp.abc123.notepad") == .excluded)
        #expect(kind("com.unknown.remote", "向日葵远程控制") == .excluded)
        #expect(kind("com.example.app", "Windows App") == .excluded)
        #expect(kind("com.example.app", "Windows App Helper") == .normal)
        #expect(kind("com.example.app", excluded: ["com.example.app"]) == .excluded)
        #expect(kind("com.apple.TextEdit") == .normal)
        #expect(kind(nil) == .normal)
    }
}

@Suite("K9 常用软件")
struct ChatAndInputMethodTests {
    @Test func wechatScreenshot() {
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.a, flags: opt, context: context(chat: true)) == send(KeyCode.a, [ctrl, cmd]))
        #expect(m.action(keyCode: KeyCode.a, flags: [ctrl, opt], context: context(chat: true)) == send(KeyCode.a, [ctrl, cmd]))
        // 微信、QQ 没开时不换，⌃⌘A 在 Finder 里是“制作替身”。
        #expect(m.action(keyCode: KeyCode.a, flags: opt, context: context(chat: false)) == .pass)
        let off = mapper { $0.chatScreenshot = false }
        #expect(off.action(keyCode: KeyCode.a, flags: opt, context: context(chat: true)) == .pass)
        // 终端里 Alt、Ctrl 组合键保持原样。
        #expect(m.action(keyCode: KeyCode.a, flags: [ctrl, opt], context: context(.terminal, chat: true)) == .pass)
        // Mac 键盘上 Alt 是 ⌘，⌘A 是全选，不能换。
        #expect(mapper(.mac).action(keyCode: KeyCode.a, flags: cmd, context: context(chat: true)) == .pass)
        #expect(mapper(.mac).action(keyCode: KeyCode.a, flags: opt, context: context(chat: true)) == send(KeyCode.a, [ctrl, cmd]))
    }

    @Test func sogouPunctuationToggle() {
        let m = mapper()
        let sogou = context(inputSource: "com.sogou.inputmethod.sogou.pinyin")
        #expect(m.action(keyCode: KeyCode.period, flags: ctrl, context: sogou) == .pass)
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: sogou) == send(KeyCode.c, cmd))
        let apple = context(inputSource: "com.apple.inputmethod.SCIM.ITABC")
        #expect(m.action(keyCode: KeyCode.period, flags: ctrl, context: apple) == send(KeyCode.period, cmd))
    }
}
