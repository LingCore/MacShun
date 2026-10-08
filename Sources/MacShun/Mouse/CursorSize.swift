// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 光标大小（M6）。Windows 在“鼠标”设置里就能调光标大小，Mac 藏在“辅助功能 → 显示 → 指针”里。
///
/// 直接改系统设置里的“指针大小”，跟在系统设置里拖滑块一样：写系统偏好，再用窗口服务器未公开的
/// CGSSetCursorScale 让它马上生效。只改窗口服务器不行：晃动指针定位、唤醒之后，系统会按系统偏好
/// 把光标改回去，而且这时 CGSGetCursorScale 可能还报着旧的倍数，查不出来。
///
/// 系统偏好要有“完全磁盘访问权限”才写得进去，这个权限要重启 Mac顺 才生效。没有时退回到只改窗口服务器，
/// 倍数存在 Mac顺 的设置里，退出时恢复成系统设置的大小；有了权限后下次启动时搬进系统设置。只在主线程上调用。
final class CursorSizeController {
    static let shared = CursorSizeController()

    /// 系统设置里“指针大小”滑块的范围
    static let range: ClosedRange<Double> = 1...4

    private static let domain = "com.apple.universalaccess" as CFString
    private static let key = "mouseDriverCursorSize" as CFString

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetScale = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetScale = @convention(c) (Int32, Float) -> Int32

    private let connection: MainConnection?
    private let getScale: GetScale?
    private let setScale: SetScale?
    private var loggedFailure = false
    /// 上次写系统偏好被拒绝了。之后等有了权限再写，免得每次都被拒绝
    private(set) var writeDenied = false

    private init() {
        let handle = dlopen(nil, RTLD_NOW)
        connection = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
        getScale = dlsym(handle, "CGSGetCursorScale").map { unsafeBitCast($0, to: GetScale.self) }
        setScale = dlsym(handle, "CGSSetCursorScale").map { unsafeBitCast($0, to: SetScale.self) }
        if connection == nil || getScale == nil || setScale == nil {
            Log.mouse.error("找不到调整光标大小的系统接口，光标大小设置不起作用")
        }
    }

    var isAvailable: Bool { connection != nil && getScale != nil && setScale != nil }

    /// 让光标跟设置一致。config.cursorScale 只在写不进系统偏好时才有值，这时每次都重新设一遍，
    /// 因为系统改回去以后 CGSGetCursorScale 可能还报着旧的倍数。
    func apply(_ config: MouseConfig) {
        if let scale = config.cursorScale {
            set(scale, force: true)
        } else {
            set(systemScale())
        }
    }

    /// 恢复成系统设置里的大小。
    func restore() {
        set(systemScale())
    }

    /// 改系统设置里的“指针大小”，马上生效。返回 false 表示系统偏好写不进去。
    @discardableResult
    func setSystemScale(_ scale: Double) -> Bool {
        let target = clamp(scale)
        let saved = Self.writeSystemScale(target)
        if saved {
            set(target, force: true)
        } else if !writeDenied {
            Log.mouse.error("写不进系统设置里的指针大小（没有完全磁盘访问权限），改成只在 Mac顺 运行时调整光标大小")
        }
        writeDenied = !saved
        return saved
    }

    /// 只写系统偏好，不碰窗口服务器
    private static func writeSystemScale(_ scale: Double) -> Bool {
        CFPreferencesSetValue(key, NSNumber(value: scale), domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            // 写不进去时丢掉本进程里缓存的这个值，免得读出来以为写进去了
            CFPreferencesAppSynchronize(domain)
            return false
        }
        return true
    }

    /// 现在的光标大小，读不到时为 nil。
    func currentScale() -> Double? {
        guard let connection, let getScale else { return nil }
        var value: Float = 0
        guard getScale(connection(), &value) == 0 else { return nil }
        return Double(value)
    }

    /// “系统设置 → 辅助功能 → 显示 → 指针大小”，没调过时是 1。
    func systemScale() -> Double {
        CFPreferencesAppSynchronize(Self.domain)
        let value = CFPreferencesCopyAppValue(Self.key, Self.domain)
        return clamp((value as? NSNumber)?.doubleValue ?? 1)
    }

    private func clamp(_ scale: Double) -> Double {
        min(max(scale, Self.range.lowerBound), Self.range.upperBound)
    }

    private func set(_ scale: Double, force: Bool = false) {
        guard let connection, let setScale else { return }
        let target = clamp(scale)
        if !force, let current = currentScale(), abs(current - target) < 0.01 { return }
        let error = setScale(connection(), Float(target))
        if error != 0, !loggedFailure {
            loggedFailure = true
            Log.mouse.error("设置光标大小失败：\(error, privacy: .public)")
        }
    }
}
