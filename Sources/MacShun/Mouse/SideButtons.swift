// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics

/// 鼠标侧键（第 4 键是后退键，第 5 键是前进键）按下时做什么（M4）。
enum SideButtonAction: String, Codable, CaseIterable, Identifiable {
    case back, forward
    case copy, paste, closeTab, refresh
    case taskView, showDesktop, clipboardHistory, fileSearch
    /// 自定义快捷键（见 SideButtonSetting.shortcut）
    case shortcut
    /// 原样交给系统：用罗技、雷蛇等鼠标软件设置侧键时选这个，不抢它们的按键
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: L("后退")
        case .forward: L("前进")
        case .copy: L("复制（Ctrl+C）")
        case .paste: L("粘贴（Ctrl+V）")
        case .closeTab: L("关闭标签页（Ctrl+W）")
        case .refresh: L("刷新（F5）")
        case .taskView: L("任务视图（Win+Tab）")
        case .showDesktop: L("显示桌面（Win+D）")
        case .clipboardHistory: L("剪贴板历史（Win+V）")
        case .fileSearch: L("文件搜索（连按两下 Ctrl）")
        case .shortcut: L("自定义快捷键…")
        case .none: L("不处理（交给系统或其他鼠标软件）")
        }
    }
}

/// 一个侧键的设置。
struct SideButtonSetting: Codable, Equatable {
    var action: SideButtonAction
    /// 选“自定义快捷键”时录下的键（按 Windows 习惯记：Ctrl、Alt、Win、Shift）
    var shortcut: WinShortcut?

    init(_ action: SideButtonAction, shortcut: WinShortcut? = nil) {
        self.action = action
        self.shortcut = shortcut
    }
}

/// 按 Windows 习惯记下的一组快捷键。不记 ⌘、⌥：同一个 Win 键在 Windows 键盘和 Mac 键盘上发出的不一样，
/// 按的时候再按现在这把键盘换成实际的键。
struct WinShortcut: Codable, Equatable {
    var keyCode: CGKeyCode
    var modifiers: Int

    init(keyCode: CGKeyCode, modifiers: WinModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    var winModifiers: WinModifiers { WinModifiers(rawValue: modifiers) }

    /// 例如 “Ctrl+Shift+T”
    var title: String {
        let mods = winModifiers
        var parts: [String] = []
        if mods.contains(.ctrl) { parts.append("Ctrl") }
        if mods.contains(.win) { parts.append("Win") }
        if mods.contains(.alt) { parts.append("Alt") }
        if mods.contains(.shift) { parts.append("Shift") }
        parts.append(Self.keyName(keyCode))
        return parts.joined(separator: "+")
    }

    /// 按键的名字，以美式键盘为准
    static func keyName(_ code: CGKeyCode) -> String {
        if let name = names[code] { return name }
        return L("键 %ld", Int(code))
    }

    private static let names: [CGKeyCode: String] = {
        var map: [CGKeyCode: String] = [
            KeyCode.returnKey: "Enter", KeyCode.keypadEnter: "Enter", KeyCode.tab: "Tab", KeyCode.space: "Space",
            KeyCode.backspace: "Backspace", KeyCode.forwardDelete: "Delete", KeyCode.escape: "Esc",
            KeyCode.home: "Home", KeyCode.end: "End", KeyCode.pageUp: "PageUp", KeyCode.pageDown: "PageDown",
            KeyCode.leftArrow: "←", KeyCode.rightArrow: "→", KeyCode.upArrow: "↑", KeyCode.downArrow: "↓",
            KeyCode.minus: "-", KeyCode.equal: "=", KeyCode.leftBracket: "[", KeyCode.rightBracket: "]",
            KeyCode.backslash: "\\", KeyCode.semicolon: ";", KeyCode.quote: "'", KeyCode.comma: ",",
            KeyCode.period: ".", KeyCode.slash: "/", KeyCode.grave: "`",
        ]
        let letters: [(CGKeyCode, String)] = [
            (KeyCode.a, "A"), (KeyCode.b, "B"), (KeyCode.c, "C"), (KeyCode.d, "D"), (KeyCode.e, "E"), (KeyCode.f, "F"),
            (KeyCode.g, "G"), (KeyCode.h, "H"), (KeyCode.i, "I"), (KeyCode.j, "J"), (KeyCode.k, "K"), (KeyCode.l, "L"),
            (KeyCode.m, "M"), (KeyCode.n, "N"), (KeyCode.o, "O"), (KeyCode.p, "P"), (KeyCode.q, "Q"), (KeyCode.r, "R"),
            (KeyCode.s, "S"), (KeyCode.t, "T"), (KeyCode.u, "U"), (KeyCode.v, "V"), (KeyCode.w, "W"), (KeyCode.x, "X"),
            (KeyCode.y, "Y"), (KeyCode.z, "Z"),
            (KeyCode.zero, "0"), (KeyCode.one, "1"), (KeyCode.two, "2"), (KeyCode.three, "3"), (KeyCode.four, "4"),
            (KeyCode.five, "5"), (KeyCode.six, "6"), (KeyCode.seven, "7"), (KeyCode.eight, "8"), (KeyCode.nine, "9"),
            (KeyCode.f1, "F1"), (KeyCode.f2, "F2"), (KeyCode.f3, "F3"), (KeyCode.f4, "F4"), (KeyCode.f5, "F5"),
            (KeyCode.f6, "F6"), (KeyCode.f7, "F7"), (KeyCode.f8, "F8"), (KeyCode.f9, "F9"), (KeyCode.f10, "F10"),
            (KeyCode.f11, "F11"), (KeyCode.f12, "F12"),
        ]
        for (code, name) in letters { map[code] = name }
        return map
    }()
}

/// 侧键按下时怎么处理。纯函数，方便测试。
enum SideButtons {
    enum Decision: Equatable {
        /// 原样放行
        case pass
        /// 换成另一个侧键：自己支持侧键的程序（浏览器、VS Code）里把前进、后退对调时
        case rewrite(Int64)
        /// 本程序直接发出这个按键
        case keystroke(KeyStroke)
        case command(SystemCommand)
        /// 像用户按了这组键一样发出去，经过 Mac顺 的键盘规则（例如普通程序里 Ctrl+C 变成 ⌘C，远程桌面里不变）
        case shortcut(WinShortcut)
    }

    static let backButton: Int64 = 3
    static let forwardButton: Int64 = 4

    /// - Parameters:
    ///   - nativeApp: 前台程序自己支持侧键前进、后退
    ///   - excluded: 远程桌面、虚拟机、用户排除的程序：侧键原样交给里面的系统
    static func decide(button: Int64, setting: SideButtonSetting, nativeApp: Bool, excluded: Bool) -> Decision {
        guard !excluded else { return .pass }
        switch setting.action {
        case .none: return .pass
        case .back, .forward:
            let wanted = setting.action == .back ? backButton : forwardButton
            if nativeApp { return wanted == button ? .pass : .rewrite(wanted) }
            return .keystroke(KeyStroke(setting.action == .back ? KeyCode.leftBracket : KeyCode.rightBracket, .maskCommand))
        case .copy: return .keystroke(KeyStroke(KeyCode.c, .maskCommand))
        case .paste: return .keystroke(KeyStroke(KeyCode.v, .maskCommand))
        case .closeTab: return .keystroke(KeyStroke(KeyCode.w, .maskCommand))
        case .refresh: return .keystroke(KeyStroke(KeyCode.r, .maskCommand))
        case .taskView: return .command(.missionControl)
        case .showDesktop: return .command(.showDesktop)
        case .clipboardHistory: return .command(.clipboardHistory)
        case .fileSearch: return .command(.fileSearch)
        case .shortcut: return setting.shortcut.map { .shortcut($0) } ?? .pass
        }
    }

    /// 按现在这把键盘的布局，把 Windows 习惯的修饰键换成实际要发出的修饰键
    static func flags(for modifiers: WinModifiers, layout: KeyboardLayoutKind) -> CGEventFlags {
        var config = KeyboardConfig()
        config.layout = layout
        let mapper = KeyMapper(config: config)
        var flags: CGEventFlags = []
        if modifiers.contains(.ctrl) { flags.insert(mapper.ctrlFlag) }
        if modifiers.contains(.alt) { flags.insert(mapper.altFlag) }
        if modifiers.contains(.win) { flags.insert(mapper.winFlag) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    /// 录快捷键时：实际按下的修饰键按现在这把键盘的布局记成 Windows 习惯的修饰键
    static func modifiers(of flags: CGEventFlags, layout: KeyboardLayoutKind) -> WinModifiers {
        var config = KeyboardConfig()
        config.layout = layout
        return KeyMapper(config: config).modifiers(of: flags)
    }

    private static let playQueue = DispatchQueue(label: "MacShun.SideButtonShortcut", qos: .userInteractive)

    /// 模拟按下这组键：先按修饰键，再按键，再依次松开。从硬件那一层发出（不带本程序的标记），
    /// 所以和用户在键盘上按的一样经过 Mac顺 的键盘规则。哪个线程都可以调用。
    static func play(_ shortcut: WinShortcut, layout: KeyboardLayoutKind) {
        let wanted = flags(for: shortcut.winModifiers, layout: layout)
        let keys = [(KeyCode.control, CGEventFlags.maskControl), (KeyCode.shift, .maskShift),
                    (KeyCode.option, .maskAlternate), (KeyCode.command, .maskCommand)].filter { wanted.contains($0.1) }
        playQueue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ event: CGEvent?) {
                event?.post(tap: .cghidEventTap)
                usleep(4000)
            }
            func modifier(_ key: CGKeyCode, _ flags: CGEventFlags) -> CGEvent? {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
                event?.type = .flagsChanged
                event?.flags = flags
                return event
            }
            var flags: CGEventFlags = []
            for (key, flag) in keys {
                flags.insert(flag)
                post(modifier(key, flags))
            }
            var keyFlags = flags
            if KeyCode.functionFlagKeys.contains(shortcut.keyCode) { keyFlags.insert(.maskSecondaryFn) }
            if KeyCode.arrows.contains(shortcut.keyCode) { keyFlags.insert(.maskNumericPad) }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down)
                event?.flags = keyFlags
                post(event)
            }
            for (key, flag) in keys.reversed() {
                flags.remove(flag)
                post(modifier(key, flags))
            }
        }
    }
}
