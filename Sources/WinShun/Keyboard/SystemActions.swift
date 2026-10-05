// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics

/// Win+E/D/L/S 对应的系统操作（K3）。都在主线程上执行。
enum SystemActions {
    static func run(_ command: SystemCommand) {
        switch command {
        case .openFinder: openFinder()
        case .showDesktop: showDesktop()
        case .lockScreen: lockScreen()
        case .spotlight: openSpotlight()
        case .switchInputSource: switchInputSource()
        case .missionControl: missionControl()
        case .clipboardHistory, .fileSearch, .window: break  // 由剪贴板、文件搜索、分屏模块处理
        }
    }

    /// Win+Space：切换到上一个输入法，和系统的 ⌃Space 一样。
    static func switchInputSource() {
        Synthetic.afterModifiersReleased {
            let stroke = SymbolicHotKeys.stroke(id: SymbolicHotKeys.previousInputSource)
                ?? KeyStroke(KeyCode.space, .maskControl)
            Synthetic.tap(stroke, at: .cghidEventTap)
        }
    }

    /// 调度中心。优先通知程序坞，不行再模拟系统设置里的快捷键（默认 ⌃↑）。
    static func missionControl() {
        if DockNotification.send("com.apple.expose.awake") { return }
        Synthetic.afterModifiersReleased {
            let stroke = SymbolicHotKeys.stroke(id: SymbolicHotKeys.missionControl)
                ?? KeyStroke(KeyCode.upArrow, .maskControl)
            Synthetic.tap(stroke, at: .cghidEventTap)
        }
    }

    /// Win+E：打开一个新的 Finder 窗口，显示个人文件夹。
    static func openFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    /// Win+D：显示桌面。优先通知程序坞，不行再模拟系统设置里“显示桌面”的快捷键。
    static func showDesktop() {
        if DockNotification.send("com.apple.showdesktop.awake") { return }
        Synthetic.afterModifiersReleased {
            let stroke = SymbolicHotKeys.stroke(id: SymbolicHotKeys.showDesktop)
                ?? KeyStroke(KeyCode.f11)
            Synthetic.tap(stroke, at: .cghidEventTap)
        }
    }

    /// Win+L：锁屏。
    static func lockScreen() {
        if LoginFramework.lockScreen() { return }
        Synthetic.afterModifiersReleased {
            Synthetic.tap(KeyStroke(KeyCode.q, [.maskControl, .maskCommand]), at: .cghidEventTap)
        }
    }

    /// Win+S：打开聚焦搜索（Spotlight）。
    static func openSpotlight() {
        Synthetic.afterModifiersReleased {
            let stroke = SymbolicHotKeys.stroke(id: SymbolicHotKeys.spotlight)
                ?? KeyStroke(KeyCode.space, .maskCommand)
            Synthetic.tap(stroke, at: .cghidEventTap)
        }
    }
}

/// 读取“系统设置 → 键盘 → 键盘快捷键”里的系统快捷键。
enum SymbolicHotKeys {
    static let showDesktop = 36
    static let missionControl = 32
    static let spotlight = 64
    static let previousInputSource = 60

    /// 返回 nil 表示没设置过（使用系统默认值）；用户关掉了这个快捷键时也返回 nil。
    static func stroke(id: Int) -> KeyStroke? {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        else { return nil }
        return parse(all["\(id)"])
    }

    /// 条目格式：{ enabled = 1; value = { parameters = (字符, 键码, 修饰键); type = standard; }; }
    static func parse(_ entry: Any?) -> KeyStroke? {
        guard let entry = entry as? [String: Any] else { return nil }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count >= 3,
              parameters[1] != 65535
        else { return nil }
        let flags = CGEventFlags(rawValue: UInt64(parameters[2]))
        return KeyStroke(CGKeyCode(parameters[1]), flags)
    }
}

/// 程序坞的内部通知，可以触发“显示桌面”等功能。这是未公开的接口，找不到时返回 false。
enum DockNotification {
    private typealias SendFunction = @convention(c) (CFString, Int32) -> Void

    private static let function: SendFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(symbol, to: SendFunction.self)
    }()

    static var isAvailable: Bool { function != nil }

    static func send(_ name: String) -> Bool {
        guard let function else { return false }
        function(name as CFString, 0)
        return true
    }
}

/// 系统登录框架里的立即锁屏函数。未公开的接口，找不到时返回 false。
enum LoginFramework {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let function: LockFunction? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static var isAvailable: Bool { function != nil }

    static func lockScreen() -> Bool {
        guard let function else { return false }
        _ = function()
        return true
    }
}
