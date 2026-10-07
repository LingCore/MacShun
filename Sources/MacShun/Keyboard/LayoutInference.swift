// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// 从按键习惯学习键盘处于 Windows 模式还是 Mac 模式（K8），不需要用户做任何事。
///
/// 切到 Mac 模式的键盘，是键盘自己把 Alt、Win 两个键的信号对调，系统和本程序只能看到“这是 ⌘ / ⌥”，
/// 看不到键的位置，设备信息也不会变（实测 MCHOSE K99），所以没法直接读出模式。
///
/// 最常用的 Alt+Tab、Alt+F4、Win+V/E/L/S 两种模式下都能用（见 KeyMapper），只有 Win+D、Win+Space
/// 需要知道模式。模式从这些按法里学：
/// - Alt+Tab、Alt+F4：Alt 发出 ⌥ 是 Windows 模式，发出 ⌘ 是 Mac 模式；
/// - ⌥+V/E/L/S：这是 Win+V 等的按法，说明 Win 发出 ⌥，是 Mac 模式。
/// 没有 Win+F4 这个快捷键，所以 F4 看到一次就算；其他的可能是偶尔按的 Win+Tab、Alt+V，要连续两次。
/// 与当前模式一致的按法会清零计数。
struct LayoutInference {
    static let observationsNeeded = 2

    private var pendingLayout: KeyboardLayoutKind?
    private var pendingDevice: String?
    private var pendingCount = 0

    /// 返回应该切换到的布局；不需要切换时返回 nil。
    mutating func observe(keyCode: CGKeyCode, flags: CGEventFlags, current: KeyboardLayoutKind, device: String?) -> KeyboardLayoutKind? {
        let mods = flags.intersection([.maskCommand, .maskAlternate, .maskControl])
        let implied: KeyboardLayoutKind
        let conclusive: Bool
        switch keyCode {
        case KeyCode.tab, KeyCode.f4:
            switch mods {
            case .maskAlternate: implied = .windows
            case .maskCommand: implied = .mac
            default: return nil
            }
            conclusive = keyCode == KeyCode.f4
        case KeyCode.v, KeyCode.e, KeyCode.l, KeyCode.s:
            guard mods == .maskAlternate else { return nil }
            implied = .mac
            conclusive = false
        default:
            return nil
        }

        if implied == current {
            reset()
            return nil
        }
        if conclusive {
            reset()
            return implied
        }
        if pendingDevice != device || pendingLayout != implied {
            pendingDevice = device
            pendingLayout = implied
            pendingCount = 0
        }
        pendingCount += 1
        guard pendingCount >= Self.observationsNeeded else { return nil }
        reset()
        return implied
    }

    private mutating func reset() {
        pendingLayout = nil
        pendingDevice = nil
        pendingCount = 0
    }
}
