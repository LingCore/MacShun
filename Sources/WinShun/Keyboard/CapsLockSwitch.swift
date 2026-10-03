// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon
import Foundation

/// K10：Caps Lock 只管大写。
///
/// Mac 上用中文输入法时，系统默认按一下 Caps Lock 是切换中英文（“ABC”输入法），要按住一会儿才是大写锁定；
/// Windows 上 Caps Lock 一按就是大写。系统设置里对应的开关是“键盘 → 输入法 → 使用大写锁定键切换‘ABC’输入法”，
/// 存在 com.apple.HIToolbox 的 TISRomanSwitchState（1 打开，0 关闭，没有这一项时按系统默认）。
///
/// 和指针设置一样：Win顺 运行、并且打开了这一项时把系统开关关掉，退出或关掉这一项时恢复原样。
/// 原来的值记在本程序的设置里，万一程序异常退出，下次启动后关掉这一项或退出时仍能恢复。只在主线程上调用。
final class CapsLockSwitchController {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "TISRomanSwitchState" as CFString
    /// 改之前系统里的值：“absent” 表示原来没有这一项
    private static let savedKey = "capsLock.originalRomanSwitchState"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func apply(_ config: KeyboardConfig) {
        if config.capsLockTypesOnly {
            disableSystemSwitch()
        } else {
            restore()
        }
    }

    /// 系统开关恢复成 Win顺 改之前的样子。
    func restore() {
        guard let saved = defaults.string(forKey: Self.savedKey) else { return }
        let value: CFPropertyList? = saved == "absent" ? nil : (Int(saved) ?? 1) as CFNumber
        write(value)
        defaults.removeObject(forKey: Self.savedKey)
        Log.keyboard.notice("Caps Lock 切换输入法：恢复成 \(saved, privacy: .public)")
    }

    private func disableSystemSwitch() {
        let current = CFPreferencesCopyAppValue(Self.key, Self.domain) as? NSNumber
        if current?.intValue == 0 { return }
        if defaults.string(forKey: Self.savedKey) == nil {
            defaults.set(current.map { "\($0.intValue)" } ?? "absent", forKey: Self.savedKey)
        }
        write(0 as CFNumber)
        Log.keyboard.notice("Caps Lock 切换输入法：已关闭")
    }

    private func write(_ value: CFPropertyList?) {
        CFPreferencesSetAppValue(Self.key, value, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
        // 通知各程序的输入法框架重新读设置
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
