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

private func context(_ kind: AppKind = .normal, focus: FocusKind = .unknown, clipboard: Bool = true) -> KeyContext {
    KeyContext(appKind: kind, clipboardEnabled: clipboard, focus: { focus })
}

private func send(_ key: CGKeyCode, _ flags: CGEventFlags = []) -> KeyAction {
    .send(KeyStroke(key, flags))
}

@Suite("已移除的按键改写")
struct RetiredRemappingTests {
    @Test func pasteStillWorksInSearchPanels() {
        var search = context()
        search.searchPanelActive = true
        let m = mapper()
        #expect(m.action(keyCode: KeyCode.v, flags: ctrl, context: search) == send(KeyCode.v, cmd))
        #expect(m.action(keyCode: KeyCode.v, flags: cmd, context: search) == .command(.clipboardHistory))
        #expect(m.action(keyCode: KeyCode.a, flags: ctrl, context: search) == .pass)
    }

    @Test func ordinaryEditingAndChatKeysPassThrough() {
        for layout in KeyboardLayoutKind.allCases {
            let m = mapper(layout)
            let ordinary = context(focus: .text)
            for key in [KeyCode.a, KeyCode.c, KeyCode.v, KeyCode.x, KeyCode.y, KeyCode.backspace, KeyCode.leftArrow, KeyCode.rightArrow] {
                #expect(m.action(keyCode: key, flags: ctrl, context: ordinary) == .pass)
            }
            for key in [KeyCode.home, KeyCode.end] {
                #expect(m.action(keyCode: key, flags: [], context: ordinary) == .pass)
                #expect(m.action(keyCode: key, flags: [ctrl, shift], context: ordinary) == .pass)
            }
            #expect(m.action(keyCode: KeyCode.a, flags: opt, context: ordinary) == .pass)
            #expect(m.action(keyCode: KeyCode.a, flags: [ctrl, opt], context: ordinary) == .pass)
            #expect(m.action(keyCode: KeyCode.v, flags: [ctrl, shift], context: ordinary) == .pass)
        }
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

    @Test func macClipboardShortcutPreservesPaste() {
        let mac = mapper(.mac)
        #expect(mac.action(keyCode: KeyCode.v, flags: opt, context: context()) == .command(.clipboardHistory))
        #expect(mac.action(keyCode: KeyCode.v, flags: cmd, context: context()) == .pass)
        #expect(mac.action(keyCode: KeyCode.v, flags: opt, context: context(clipboard: false)) == .pass)
        let disabled = mapper(.mac) { $0.enabled = false }
        #expect(disabled.action(keyCode: KeyCode.v, flags: opt, context: context()) == .pass)
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
        #expect(m.action(keyCode: KeyCode.c, flags: ctrl, context: fileList) == .pass)
    }

    /// 正在重命名或在搜索框里时，按键保持输入框的行为。
    @Test func textFieldInFinderIsUntouched() {
        let m = mapper()
        let renaming = context(.finder, focus: .text)
        #expect(m.action(keyCode: KeyCode.returnKey, flags: [], context: renaming) == .pass)
        #expect(m.action(keyCode: KeyCode.backspace, flags: [], context: renaming) == .pass)
        #expect(m.action(keyCode: KeyCode.forwardDelete, flags: [], context: renaming) == .pass)
        #expect(m.action(keyCode: KeyCode.x, flags: ctrl, context: renaming) == .pass)
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

@Suite("K6 远程桌面")
struct SpecialAppTests {
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
