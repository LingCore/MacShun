// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Testing
@testable import WinShun

@Suite("M4 鼠标侧键")
struct SideButtonTests {
    private func decide(_ button: Int64, _ setting: SideButtonSetting, native: Bool = false, excluded: Bool = false)
        -> SideButtons.Decision {
        SideButtons.decide(button: button, setting: setting, nativeApp: native, excluded: excluded)
    }

    @Test func defaultsGoBackAndForward() {
        let config = MouseConfig()
        #expect(decide(3, config.backButton) == .keystroke(KeyStroke(KeyCode.leftBracket, .maskCommand)))
        #expect(decide(4, config.forwardButton) == .keystroke(KeyStroke(KeyCode.rightBracket, .maskCommand)))
        // 浏览器、VS Code 自己认侧键，原样交给它们
        #expect(decide(3, config.backButton, native: true) == .pass)
        #expect(decide(4, config.forwardButton, native: true) == .pass)
    }

    @Test func swappedButtonsInAppsThatHandleThemNatively() {
        // 两个侧键对调：浏览器里换成另一个侧键，不发 ⌘[（VS Code 里 ⌘[ 是减少缩进）
        #expect(decide(3, SideButtonSetting(.forward), native: true) == .rewrite(4))
        #expect(decide(4, SideButtonSetting(.back), native: true) == .rewrite(3))
        #expect(decide(3, SideButtonSetting(.forward)) == .keystroke(KeyStroke(KeyCode.rightBracket, .maskCommand)))
    }

    @Test func noneAndExcludedAppsPassThrough() {
        // 交给其他鼠标软件
        #expect(decide(3, SideButtonSetting(.none)) == .pass)
        // 远程桌面、虚拟机里原样交给里面的系统，设了什么都一样
        #expect(decide(3, SideButtonSetting(.copy), excluded: true) == .pass)
    }

    @Test func presetsAndShortcuts() {
        #expect(decide(4, SideButtonSetting(.copy)) == .keystroke(KeyStroke(KeyCode.c, .maskCommand)))
        #expect(decide(4, SideButtonSetting(.copy), native: true) == .keystroke(KeyStroke(KeyCode.c, .maskCommand)))
        #expect(decide(4, SideButtonSetting(.taskView)) == .command(.missionControl))
        #expect(decide(4, SideButtonSetting(.clipboardHistory)) == .command(.clipboardHistory))
        let shortcut = WinShortcut(keyCode: KeyCode.t, modifiers: [.ctrl, .shift])
        #expect(decide(4, SideButtonSetting(.shortcut, shortcut: shortcut)) == .shortcut(shortcut))
        // 选了自定义但还没录：先不处理
        #expect(decide(4, SideButtonSetting(.shortcut)) == .pass)
    }

    @Test func shortcutTitlesUseWindowsNames() {
        #expect(WinShortcut(keyCode: KeyCode.t, modifiers: [.ctrl, .shift]).title == "Ctrl+Shift+T")
        #expect(WinShortcut(keyCode: KeyCode.tab, modifiers: .alt).title == "Alt+Tab")
        #expect(WinShortcut(keyCode: KeyCode.d, modifiers: .win).title == "Win+D")
        #expect(WinShortcut(keyCode: KeyCode.f5, modifiers: []).title == "F5")
    }

    @Test func winAndAltFollowTheKeyboardLayout() {
        // Windows 键盘：Win 键发出 ⌘、Alt 键发出 ⌥；Mac 键盘反过来
        #expect(SideButtons.flags(for: [.win, .ctrl], layout: .windows) == [.maskCommand, .maskControl])
        #expect(SideButtons.flags(for: .win, layout: .mac) == .maskAlternate)
        #expect(SideButtons.flags(for: .alt, layout: .mac) == .maskCommand)
        // 录的时候反过来换
        #expect(SideButtons.modifiers(of: [.maskCommand, .maskShift], layout: .windows) == [.win, .shift])
        #expect(SideButtons.modifiers(of: .maskCommand, layout: .mac) == .alt)
    }

    @Test func oldSwitchTurnedOffMeansNone() throws {
        let off = try JSONDecoder().decode(MouseConfig.self, from: Data(#"{"sideButtons": false}"#.utf8))
        #expect(off.backButton == SideButtonSetting(.none) && off.forwardButton == SideButtonSetting(.none))
        let on = try JSONDecoder().decode(MouseConfig.self, from: Data(#"{"sideButtons": true}"#.utf8))
        #expect(on.backButton == SideButtonSetting(.back) && on.forwardButton == SideButtonSetting(.forward))
        // 存了再读回来一样
        var config = MouseConfig()
        config.forwardButton = SideButtonSetting(.shortcut, shortcut: WinShortcut(keyCode: KeyCode.w, modifiers: .ctrl))
        let again = try JSONDecoder().decode(MouseConfig.self, from: JSONEncoder().encode(config))
        #expect(again.forwardButton == config.forwardButton)
    }
}
