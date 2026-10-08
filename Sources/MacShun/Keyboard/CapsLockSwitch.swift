// SPDX-License-Identifier: MIT

import Carbon
import Foundation

/// 早先试过的“Caps Lock 只管大写”（K10，已去掉）留下的系统设置，在这里还原。
///
/// 当时的做法是关掉系统的“使用大写锁定键切换‘ABC’输入法”，Caps Lock 打开时再临时切到英文键盘。
/// 但 macOS 切换输入法时会自动关掉 Caps Lock，结果反而要按 Shift+Caps Lock 才能大写，不如系统默认的
/// “短按切换中英文、按住锁定大写”，所以去掉了。用过那几个版本的电脑上，系统开关可能还是关着的。
enum CapsLockLeftovers {
    /// 那时记下的改之前系统开关是否打开（"1" / "0"）
    private static let savedKey = "capsLock.originalSwitchEnabled"
    /// 更早的版本直接写过偏好设置 TISRomanSwitchState，记的是原值（"absent" 表示原来没有）
    private static let legacyKey = "capsLock.originalRomanSwitchState"

    /// 启动时调用一次。
    static func restore(defaults: UserDefaults = .standard) {
        if let saved = defaults.string(forKey: savedKey) {
            typealias SetState = @convention(c) (UInt8) -> Void
            let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_NOW)
            if let symbol = dlsym(carbon, "TISSetRomanSwitchState") {
                unsafeBitCast(symbol, to: SetState.self)(saved == "1" ? 1 : 0)
                Log.keyboard.notice("还原 Caps Lock 切换输入法的系统设置：\(saved, privacy: .public)")
            }
            defaults.removeObject(forKey: savedKey)
        }
        if let saved = defaults.string(forKey: legacyKey) {
            let domain = "com.apple.HIToolbox" as CFString
            let value: CFPropertyList? = saved == "absent" ? nil : (Int(saved) ?? 1) as CFNumber
            CFPreferencesSetAppValue("TISRomanSwitchState" as CFString, value, domain)
            CFPreferencesAppSynchronize(domain)
            defaults.removeObject(forKey: legacyKey)
        }
    }
}
