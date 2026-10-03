// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon
import Foundation

/// K10：Caps Lock 只管大写。
///
/// Mac 上用中文输入法时，系统默认按一下 Caps Lock 是切换中英文（“ABC”输入法），要按住一会儿才是大写锁定；
/// Windows 上 Caps Lock 一按就是大写。系统设置里对应的开关是“键盘 → 输入法 → 使用大写锁定键切换‘ABC’输入法”。
///
/// 系统设置用的是 Carbon 里没有公开的 TISIsRomanSwitchEnabled / TISSetRomanSwitchState，改了马上生效；
/// 直接写偏好设置（com.apple.HIToolbox 的 TISRomanSwitchState）不起作用（实测 macOS 27）。这里照系统设置的做法调用。
///
/// 和指针设置一样：Win顺 运行、并且打开了这一项时把系统开关关掉，退出或关掉这一项时恢复原样。
/// 原来的状态记在本程序的设置里，万一程序异常退出，下次启动后关掉这一项或退出时仍能恢复。只在主线程上调用。
final class CapsLockSwitchController {
    private typealias IsEnabled = @convention(c) () -> UInt8
    private typealias SetState = @convention(c) (UInt8) -> Void

    /// 改之前系统开关是否打开（"1" / "0"）；没有这一项表示没改过
    private static let savedKey = "capsLock.originalSwitchEnabled"
    /// 早先的版本直接写过偏好设置，记的是原值（"absent" 表示原来没有）。启动时清理掉
    private static let legacyKey = "capsLock.originalRomanSwitchState"

    private let defaults: UserDefaults
    private let isEnabled: IsEnabled?
    private let setState: SetState?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW)
        isEnabled = dlsym(carbon, "TISIsRomanSwitchEnabled").map { unsafeBitCast($0, to: IsEnabled.self) }
        setState = dlsym(carbon, "TISSetRomanSwitchState").map { unsafeBitCast($0, to: SetState.self) }
        if isEnabled == nil || setState == nil {
            Log.keyboard.error("找不到 Caps Lock 切换输入法的系统接口，“Caps Lock 只管大写”不起作用")
        }
        cleanUpLegacyPreference()
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
        guard let saved = defaults.string(forKey: Self.savedKey), let setState else { return }
        setState(saved == "1" ? 1 : 0)
        defaults.removeObject(forKey: Self.savedKey)
        Log.keyboard.notice("Caps Lock 切换输入法：恢复成 \(saved, privacy: .public)")
    }

    private func disableSystemSwitch() {
        guard let isEnabled, let setState, isEnabled() != 0 else { return }
        if defaults.string(forKey: Self.savedKey) == nil {
            defaults.set("1", forKey: Self.savedKey)
        }
        setState(0)
        Log.keyboard.notice("Caps Lock 切换输入法：已关闭")
    }

    /// 早先的版本写的 TISRomanSwitchState 没用，还原成写之前的样子。
    private func cleanUpLegacyPreference() {
        guard let saved = defaults.string(forKey: Self.legacyKey) else { return }
        let domain = "com.apple.HIToolbox" as CFString
        let value: CFPropertyList? = saved == "absent" ? nil : (Int(saved) ?? 1) as CFNumber
        CFPreferencesSetAppValue("TISRomanSwitchState" as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
        defaults.removeObject(forKey: Self.legacyKey)
    }
}
