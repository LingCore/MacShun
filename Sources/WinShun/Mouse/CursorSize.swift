// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 光标大小（M6）。Windows 在“鼠标”设置里就能调光标大小，Mac 藏在“辅助功能 → 显示 → 指针”里。
///
/// 用窗口服务器未公开的 CGSSetCursorScale 实时改，不写系统偏好：退出 Win顺 时恢复成系统设置的大小，
/// 系统设置里的“指针大小”也不会被改掉。系统可能在显示器重新排列、睡眠唤醒后把它改回去，
/// 所以和指针速度一起定期检查。只在主线程上调用。
final class CursorSizeController {
    /// 系统设置里“指针大小”滑块的范围
    static let range: ClosedRange<Double> = 1...4

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetScale = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetScale = @convention(c) (Int32, Float) -> Int32

    private let connection: MainConnection?
    private let getScale: GetScale?
    private let setScale: SetScale?
    private var loggedFailure = false

    init() {
        let handle = dlopen(nil, RTLD_NOW)
        connection = dlsym(handle, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
        getScale = dlsym(handle, "CGSGetCursorScale").map { unsafeBitCast($0, to: GetScale.self) }
        setScale = dlsym(handle, "CGSSetCursorScale").map { unsafeBitCast($0, to: SetScale.self) }
        if connection == nil || getScale == nil || setScale == nil {
            Log.mouse.error("找不到调整光标大小的系统接口，光标大小设置不起作用")
        }
    }

    var isAvailable: Bool { connection != nil && getScale != nil && setScale != nil }

    func apply(_ config: MouseConfig) {
        let target = config.enabled ? (config.cursorScale ?? systemScale()) : systemScale()
        set(target)
    }

    /// 恢复成系统设置里的大小。
    func restore() {
        set(systemScale())
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
        let value = CFPreferencesCopyAppValue("mouseDriverCursorSize" as CFString, "com.apple.universalaccess" as CFString)
        let scale = (value as? NSNumber)?.doubleValue ?? 1
        return min(max(scale, Self.range.lowerBound), Self.range.upperBound)
    }

    private func set(_ scale: Double) {
        guard let connection, let setScale else { return }
        let target = min(max(scale, Self.range.lowerBound), Self.range.upperBound)
        if let current = currentScale(), abs(current - target) < 0.01 { return }
        let error = setScale(connection(), Float(target))
        if error != 0, !loggedFailure {
            loggedFailure = true
            Log.mouse.error("设置光标大小失败：\(error, privacy: .public)")
        }
    }
}
