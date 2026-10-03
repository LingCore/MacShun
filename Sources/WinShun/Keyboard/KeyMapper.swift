// SPDX-License-Identifier: GPL-3.0-or-later

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
    /// Win+Space：切换输入法
    case switchInputSource
    /// 连按两下 Ctrl：文件搜索（F1）
    case fileSearch
    /// Win+方向键：分屏（W1）
    case window(WindowShortcut)
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
    var isBrowser: Bool
    var clipboardEnabled: Bool
    /// 微信或 QQ 是否在运行
    var chatAppRunning: Bool = false
    /// 当前输入源的标识
    var inputSourceID: String? = nil
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

    /// Ctrl+这些键会变成 ⌘+同一个键（K1）。
    /// 不改写的：Ctrl+H（⌘H 会隐藏程序）、Ctrl+M（⌘M 会最小化）、Ctrl+Q（⌘Q 会退出程序）、Ctrl+`。
    static let ctrlAsCommandKeys: Set<CGKeyCode> = KeyCode.letters
        .subtracting([KeyCode.h, KeyCode.m, KeyCode.q])
        .union(KeyCode.digits)
        .union(KeyCode.symbols)

    func action(keyCode: CGKeyCode, flags: CGEventFlags, context: KeyContext) -> KeyAction {
        guard context.appKind != .excluded else { return .pass }
        let mods = modifiers(of: flags)
        // W1：Win+方向键分屏。分屏有自己的开关，不跟着键盘改写的总开关走。
        // 只认当前布局的 Win 键：Windows 键盘上是 ⌘，Mac 键盘上是 ⌥（和 Win 键在同一个位置）。
        // 不像 Win+V 那样在 Windows 键盘上也认 ⌥：那里 ⌥ 是 Alt
        if context.windowShortcuts, let shortcut = Self.windowShortcut(keyCode: keyCode, mods: mods) {
            return .command(.window(shortcut))
        }
        guard config.enabled else { return .pass }

        let shift: CGEventFlags = mods.contains(.shift) ? .maskShift : []

        // 焦点只查一次。
        var cachedFocus: FocusKind?
        func focus() -> FocusKind {
            if let cachedFocus { return cachedFocus }
            let f = context.focus()
            cachedFocus = f
            return f
        }

        // K3、K7：所有应用里都生效，终端也一样。
        if let action = systemShortcut(keyCode: keyCode, flags: flags, mods: mods, context: context) {
            return action
        }

        // K5：终端里只改 Ctrl+Shift+C/V。
        if context.appKind == .terminal {
            if config.ctrlAsCommand, mods == [.ctrl, .shift] {
                if keyCode == KeyCode.c { return .send(KeyStroke(KeyCode.c, .maskCommand)) }
                if keyCode == KeyCode.v { return .send(KeyStroke(KeyCode.v, .maskCommand)) }
            }
            return .pass
        }

        // K9：微信、QQ 的截图。Windows 上是 Alt+A（微信）和 Ctrl+Alt+A（QQ），Mac 上都是 ⌃⌘A。
        // 只在它们运行时才换，否则 ⌃⌘A 在 Finder 里是“制作替身”。
        // 只认 ⌥：Mac 模式下 Alt 发出 ⌘，⌘A 是全选不能动，而 Ctrl+Alt+A 本来就是 ⌃⌘A。
        let rawMods = flags.intersection(.modifierKeys)
        if config.chatScreenshot, context.chatAppRunning, keyCode == KeyCode.a,
           rawMods == .maskAlternate || rawMods == [.maskControl, .maskAlternate] {
            return .send(KeyStroke(KeyCode.a, [.maskControl, .maskCommand]))
        }

        // K4：Finder 的文件列表里。光标在输入框里（例如正在重命名）时不改写。
        if context.appKind == .finder, config.finderShortcuts,
           let action = finderShortcut(keyCode: keyCode, mods: mods, focus: focus) {
            return action
        }

        // K2：文字光标移动。
        if config.textNavigation,
           let action = textNavigation(keyCode: keyCode, mods: mods, shift: shift, context: context, focus: focus) {
            return action
        }

        // K1：Ctrl+键 → ⌘+键。
        if config.ctrlAsCommand, mods.subtracting(.shift) == [.ctrl], Self.ctrlAsCommandKeys.contains(keyCode) {
            // K9：搜狗输入法用 ⌃. 切换中英文标点，和 Windows 版的 Ctrl+. 一样，保留给它。
            if keyCode == KeyCode.period,
               context.inputSourceID?.hasPrefix(AppCatalog.sogouInputSourcePrefix) == true {
                return .pass
            }
            if keyCode == KeyCode.y && shift.isEmpty {
                return .send(KeyStroke(KeyCode.z, [.maskCommand, .maskShift]))  // Ctrl+Y 重做
            }
            return .send(KeyStroke(keyCode, CGEventFlags.maskCommand.union(shift)))
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

    private func textNavigation(
        keyCode: CGKeyCode, mods: WinModifiers, shift: CGEventFlags,
        context: KeyContext, focus: () -> FocusKind
    ) -> KeyAction? {
        let base = mods.subtracting(.shift)

        // 光标是否在可以输入文字的地方。浏览器里 ⌘← 是“后退”，所以浏览器里必须确定是输入框才算。
        func inText() -> Bool {
            switch focus() {
            case .text: return true
            case .unknown: return !context.isBrowser
            case .browsing, .other: return false
            }
        }

        switch (keyCode, base) {
        case (KeyCode.home, []), (KeyCode.end, []):
            // 不在输入框里时，Mac 原本的 Home/End 就是滚到顶部/底部，和 Windows 一样。
            guard inText() else { return nil }
            let arrow = keyCode == KeyCode.home ? KeyCode.leftArrow : KeyCode.rightArrow
            return .send(KeyStroke(arrow, CGEventFlags.maskCommand.union(shift)))

        case (KeyCode.home, [.ctrl]), (KeyCode.end, [.ctrl]):
            if inText() {
                let arrow = keyCode == KeyCode.home ? KeyCode.upArrow : KeyCode.downArrow
                return .send(KeyStroke(arrow, CGEventFlags.maskCommand.union(shift)))
            }
            return .send(KeyStroke(keyCode, shift))

        case (KeyCode.leftArrow, [.ctrl]), (KeyCode.rightArrow, [.ctrl]):
            return .send(KeyStroke(keyCode, CGEventFlags.maskAlternate.union(shift)))

        case (KeyCode.backspace, [.ctrl]), (KeyCode.forwardDelete, [.ctrl]):
            return .send(KeyStroke(keyCode, CGEventFlags.maskAlternate.union(shift)))

        default:
            return nil
        }
    }
}
