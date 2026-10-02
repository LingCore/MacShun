// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOKit.hid
import IOKit.hidsystem

/// 按设备关闭指针加速、调指针速度（M1）。
///
/// 用系统公开的 HID 属性 HIDUseLinearScalingMouseAcceleration：打开后指针移动距离和鼠标移动距离成正比。
/// 这和 macOS 14 起“系统设置 → 鼠标 → 高级 → 指针加速”关掉时的效果一样，区别是这里可以每个鼠标分别设置。
///
/// 没有加速时，指针移动距离 = 鼠标移动的计数 × HIDMouseAcceleration（系统里就是“跟踪速度”，最高 3）。
/// 指针速度就是改这个倍数，可以超过 3；只在没有加速时调，有加速时这个值是选加速曲线用的，交给系统。
///
/// 这些属性不会保存，鼠标重新连接、电脑睡眠唤醒后要重新设置。只在主线程上调用。
///
/// 不归本程序管的鼠标，按系统设置恢复（全局偏好 com.apple.mouse.linear、com.apple.mouse.scaling）。
/// 用它而不是第一次读到的设备值，是为了在上次程序异常退出、或用户改过系统开关之后也能恢复正确。
final class PointerAccelerationController {
    private static let linearKey = kIOHIDUseLinearScalingMouseAccelerationKey as CFString
    private static let speedKey = kIOHIDMouseAccelerationType as CFString

    private let client = makeClient()
    /// 设置失败过的鼠标和属性，同一个只记一次日志。
    private var failedKeys: Set<String> = []

    /// 公开接口创建的“简单客户端”只能读这个属性、不能改（实测 macOS 27），
    /// 所以优先用 IOKit 里未公开的 IOHIDEventSystemClientCreate；找不到时退回简单客户端。
    private static func makeClient() -> IOHIDEventSystemClient {
        typealias CreateFunction = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
        if let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
           let symbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
           let client = unsafeBitCast(symbol, to: CreateFunction.self)(kCFAllocatorDefault)?.takeRetainedValue() {
            return client
        }
        Log.mouse.error("找不到完整的 HID 客户端，可能无法按鼠标关闭指针加速")
        return IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    }

    func apply(_ config: MouseConfig) {
        let systemLinear = self.systemLinear()
        let systemSpeed = self.systemSpeed()
        for service in mouseServices() {
            guard let key = deviceKey(service) else { continue }
            let settings = config.settings(forDevice: key)
            let wantLinear = config.enabled && settings.linearPointer
            let speed = wantLinear ? (settings.pointerSpeed ?? systemSpeed) : systemSpeed
            if let speed { set(service, key, Self.speedKey, Self.fixed(speed)) }
            set(service, key, Self.linearKey, wantLinear || systemLinear)
        }
    }

    /// 所有鼠标恢复成系统设置。
    func restore() {
        let systemLinear = self.systemLinear()
        let systemSpeed = self.systemSpeed()
        for service in mouseServices() {
            let key = deviceKey(service) ?? ""
            if let systemSpeed { set(service, key, Self.speedKey, Self.fixed(systemSpeed)) }
            set(service, key, Self.linearKey, systemLinear)
        }
    }

    /// 每个鼠标现在的指针速度，自测用。
    func currentSpeeds() -> [String: Double] {
        var result: [String: Double] = [:]
        for service in mouseServices() {
            guard let key = deviceKey(service), let value = number(service, Self.speedKey) else { continue }
            result[key] = Double(value.int32Value) / 65536
        }
        return result
    }

    /// “系统设置 → 鼠标 → 跟踪速度”的值。读不到时返回 nil，不去动它。
    func systemSpeed() -> Double? {
        if let value = UserDefaults.standard.object(forKey: "com.apple.mouse.scaling") as? NSNumber {
            return value.doubleValue
        }
        guard let value = IOHIDEventSystemClientCopyProperty(client, Self.speedKey) as? NSNumber else { return nil }
        return Double(value.int32Value) / 65536
    }

    /// 值不一样时才设置，避免反复让系统重建加速设置。
    private func set(_ service: IOHIDServiceClient, _ key: String, _ property: CFString, _ target: Bool) {
        guard boolProperty(service, property) != target else { return }
        report(IOHIDServiceClientSetProperty(service, property, target as CFBoolean), key, property)
    }

    private func set(_ service: IOHIDServiceClient, _ key: String, _ property: CFString, _ target: Int32) {
        guard number(service, property)?.int32Value != target else { return }
        report(IOHIDServiceClientSetProperty(service, property, NSNumber(value: target)), key, property)
    }

    private func report(_ ok: Bool, _ key: String, _ property: CFString) {
        if !ok, failedKeys.insert("\(key)|\(property)").inserted {
            Log.mouse.error("设置 \(property as String, privacy: .public) 失败：\(key, privacy: .public)")
        }
    }

    /// HID 属性里的小数用 16.16 定点数表示。
    private static func fixed(_ value: Double) -> Int32 {
        Int32((value * 65536).rounded())
    }

    /// 系统设置里关掉了“指针加速”时为 true。
    private func systemLinear() -> Bool {
        if let value = UserDefaults.standard.object(forKey: "com.apple.mouse.linear") {
            return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
        }
        guard let value = IOHIDEventSystemClientCopyProperty(client, Self.linearKey) else { return false }
        return Self.bool(value)
    }

    private func mouseServices() -> [IOHIDServiceClient] {
        let all = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return all.filter { service in
            let isPointer = IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                || IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
            guard isPointer else { return false }
            let name = stringProperty(service, kIOHIDProductKey) ?? ""
            return !InputDeviceMonitor.isTrackpad(name: name)
        }
    }

    private func deviceKey(_ service: IOHIDServiceClient) -> String? {
        let name = stringProperty(service, kIOHIDProductKey) ?? L("未知鼠标")
        let vendor = intProperty(service, kIOHIDVendorIDKey) ?? 0
        let product = intProperty(service, kIOHIDProductIDKey) ?? 0
        return InputDevice.makeKey(vendorID: vendor, productID: product, name: name)
    }

    private func boolProperty(_ service: IOHIDServiceClient, _ property: CFString) -> Bool {
        guard let value = IOHIDServiceClientCopyProperty(service, property) else { return false }
        return Self.bool(value)
    }

    private func number(_ service: IOHIDServiceClient, _ property: CFString) -> NSNumber? {
        IOHIDServiceClientCopyProperty(service, property) as? NSNumber
    }

    private static func bool(_ value: CFTypeRef) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return false
    }

    private func stringProperty(_ service: IOHIDServiceClient, _ key: String) -> String? {
        IOHIDServiceClientCopyProperty(service, key as CFString) as? String
    }

    private func intProperty(_ service: IOHIDServiceClient, _ key: String) -> Int? {
        (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue
    }
}
