// SPDX-License-Identifier: MIT

import CoreGraphics

/// 按 Windows 习惯理解的修饰键。
struct WinModifiers: OptionSet, Hashable {
    let rawValue: Int
    static let ctrl = WinModifiers(rawValue: 1 << 0)
    static let alt = WinModifiers(rawValue: 1 << 1)
    static let win = WinModifiers(rawValue: 1 << 2)
    static let shift = WinModifiers(rawValue: 1 << 3)
}

/// 需要程序自己完成的系统操作（K3、K7）。
enum SystemCommand: Equatable {
    case openFinder
    case showDesktop
    case lockScreen
    case spotlight
    case clipboardHistory
    case capture(CaptureMode)
    case finishScrollingCapture, cancelScrollingCapture
    /// Win+Space：切换输入法
    case switchInputSource
    /// 连按两下 Ctrl：文件搜索（F1）
    case fileSearch
    /// Win+方向键：分屏（W1）
    case window(WindowShortcut)
    /// 调度中心（Windows 的任务视图，鼠标侧键可以设成这个）
    case missionControl
}

/// 对一次按键的处理结果。
enum KeyAction: Equatable {
    /// 原样放行
    case pass
    /// 换成另一个按键（按下换成按下，松开换成松开）
    case send(KeyStroke)
    /// 执行系统操作，按键本身吞掉
    case command(SystemCommand)
    /// Alt+Tab：打开应用切换器
    case appSwitcher(reverse: Bool)
    /// Finder 里的 Ctrl+X：先复制，粘贴时再“移动”
    case finderCut
    /// Finder 里的 Ctrl+V：之前按过 Ctrl+X 就移动，否则粘贴
    case finderPaste
}

/// 判断按键时需要的环境信息。
struct KeyContext {
    var appKind: AppKind
    var clipboardEnabled: Bool
    var searchPanelActive = false
    /// Win+方向键分屏是否打开
    var windowShortcuts = false
    /// 查询键盘焦点。代价较高，只在规则需要时才调用。
    var focus: () -> FocusKind
}

/// 键位规则。只做判断，不碰系统事件，方便测试。
struct KeyMapper {
    var config: KeyboardConfig

    /// 实际按下的 Mac 修饰键对应 Windows 上的哪个键。
    var ctrlFlag: CGEventFlags { .maskControl }
    var altFlag: CGEventFlags { config.layout == .windows ? .maskAlternate : .maskCommand }
    var winFlag: CGEventFlags { config.layout == .windows ? .maskCommand : .maskAlternate }

    func modifiers(of flags: CGEventFlags) -> WinModifiers {
        var m: WinModifiers = []
        if flags.contains(ctrlFlag) { m.insert(.ctrl) }
        if flags.contains(altFlag) { m.insert(.alt) }
        if flags.contains(winFlag) { m.insert(.win) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        return m
    }

    func action(keyCode: CGKeyCode, flags: CGEventFlags, context: KeyContext) -> KeyAction {
        guard context.appKind != .excluded else { return .pass }
        let mods = modifiers(of: flags)
        let shortcut = WinShortcut(keyCode: keyCode, modifiers: mods)
        if config.captureShortcut == shortcut || config.captureTextShortcut == shortcut,
           shortcut.canStartCapture(layout: config.layout) {
            return .command(.capture(config.captureShortcut == shortcut ? .image : .text))
        }
        // W1：Win+方向键分屏。分屏有自己的开关，不跟着键盘改写的总开关走。
        // 只认当前布局的 Win 键：Windows 键盘上是 ⌘，Mac 键盘上是 ⌥（和 Win 键在同一个位置）。
        // 不像 Win+V 那样在 Windows 键盘上也认 ⌥：那里 ⌥ 是 Alt
        if context.windowShortcuts, let shortcut = Self.windowShortcut(keyCode: keyCode, mods: mods) {
            return .command(.window(shortcut))
        }
        guard config.enabled else { return .pass }

        // 搜索面板保留 Ctrl+V 粘贴，Windows 布局下 ⌘V 用于打开剪贴板历史。
        if context.searchPanelActive, keyCode == KeyCode.v, mods == [.ctrl] {
            return .send(KeyStroke(KeyCode.v, .maskCommand))
        }

        // K3、K7：所有应用里都生效，终端也一样。
        if let action = systemShortcut(keyCode: keyCode, flags: flags, mods: mods, context: context) {
            return action
        }

        // K4：只改写 Finder 文件列表上的按键，保留搜索框和重命名的原生行为。
        if context.appKind == .finder, config.finderShortcuts {
            return finderShortcut(keyCode: keyCode, mods: mods, focus: context.focus) ?? .pass
        }

        return .pass
    }

    static func windowShortcut(keyCode: CGKeyCode, mods: WinModifiers) -> WindowShortcut? {
        switch (keyCode, mods) {
        case (KeyCode.leftArrow, [.win]): return .snap(.left)
        case (KeyCode.rightArrow, [.win]): return .snap(.right)
        case (KeyCode.upArrow, [.win]): return .snap(.up)
        case (KeyCode.downArrow, [.win]): return .snap(.down)
        case (KeyCode.leftArrow, [.win, .shift]): return .moveToDisplay(left: true)
        case (KeyCode.rightArrow, [.win, .shift]): return .moveToDisplay(left: false)
        case (KeyCode.upArrow, [.win, .shift]): return .stretchVertically
        default: return nil
        }
    }

    /// K3、K7。最常用的几个组合不依赖键盘的 Win/Mac 模式，切换模式后马上就能用：
    /// - ⌥ 一定当 Alt 或 Win 用：Windows 用户不会用 ⌥+字母打 √ ∂ ß 这类符号；
    /// - Alt+Tab：⌥Tab 打开切换器，⌘Tab 本来就是系统的切换程序；
    /// - Alt+F4：⌥F4、⌘F4 都退出程序（没有 Win+F4 这个快捷键）。
    /// 只有 Win+D、Win+Space 按当前布局认 Win 键：Windows 模式下 Alt+D 是浏览器地址栏的习惯，⌥Space 常被启动器占用。
    private func systemShortcut(keyCode: CGKeyCode, flags: CGEventFlags, mods: WinModifiers, context: KeyContext) -> KeyAction? {
        let raw = flags.intersection(.modifierKeys)
        let win = mods == [.win] || raw == .maskAlternate

        if keyCode == KeyCode.v, win, context.clipboardEnabled {
            return .command(.clipboardHistory)
        }
        guard config.systemShortcuts else { return nil }

        if keyCode == KeyCode.tab {
            switch raw.subtracting(.maskShift) {
            case .maskAlternate: return .appSwitcher(reverse: raw.contains(.maskShift))
            case .maskCommand: return .pass
            default: break
            }
        }
        if keyCode == KeyCode.f4, raw == .maskAlternate || raw == .maskCommand {
            return .send(KeyStroke(KeyCode.q, .maskCommand))
        }
        switch keyCode {
        case KeyCode.e where win: return .command(.openFinder)
        case KeyCode.l where win: return .command(.lockScreen)
        case KeyCode.s where win: return .command(.spotlight)
        case KeyCode.d where mods == [.win]: return .command(.showDesktop)
        case KeyCode.space where mods == [.win]: return .command(.switchInputSource)
        default: return nil
        }
    }

    private func finderShortcut(keyCode: CGKeyCode, mods: WinModifiers, focus: () -> FocusKind) -> KeyAction? {
        let relevant: Bool
        switch (keyCode, mods) {
        case (KeyCode.x, [.ctrl]), (KeyCode.v, [.ctrl]),
             (KeyCode.f2, []), (KeyCode.returnKey, []), (KeyCode.keypadEnter, []),
             (KeyCode.forwardDelete, []), (KeyCode.backspace, []):
            relevant = true
        default:
            relevant = false
        }
        // 只有焦点确实在文件列表上才改写；问不到焦点时按 Mac 原样处理，避免误删文件。
        guard relevant, focus() == .browsing else { return nil }

        switch keyCode {
        case KeyCode.x: return .finderCut
        case KeyCode.v: return .finderPaste
        case KeyCode.f2: return .send(KeyStroke(KeyCode.returnKey))                        // 重命名
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return .send(KeyStroke(KeyCode.downArrow, .maskCommand))                       // 打开
        case KeyCode.forwardDelete: return .send(KeyStroke(KeyCode.backspace, .maskCommand)) // 移到废纸篓
        case KeyCode.backspace: return .send(KeyStroke(KeyCode.upArrow, .maskCommand))       // 上一级
        default: return nil
        }
    }
}

extension WinShortcut {
    /// 截图是全局热键，不能占用普通打字、聊天应用的截图键或系统截图键。
    func canStartCapture(layout: KeyboardLayoutKind) -> Bool {
        let flags = SideButtons.flags(for: winModifiers, layout: layout)
        let functions = [KeyCode.f1, KeyCode.f2, KeyCode.f3, KeyCode.f4, KeyCode.f5, KeyCode.f6,
                         KeyCode.f7, KeyCode.f8, KeyCode.f9, KeyCode.f10, KeyCode.f11, KeyCode.f12]
        if flags.subtracting(.maskShift).isEmpty { return functions.contains(keyCode) }
        if keyCode == KeyCode.a, flags == .maskAlternate || flags == [.maskControl, .maskAlternate]
            || flags == [.maskControl, .maskCommand] { return false }
        let screenKeys = [KeyCode.three, KeyCode.four, KeyCode.five, KeyCode.six]
        return !(screenKeys.contains(keyCode) && flags.subtracting(.maskControl) == [.maskCommand, .maskShift])
    }
}
