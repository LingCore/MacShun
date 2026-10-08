// SPDX-License-Identifier: MIT

import Foundation
import IOKit.hid

/// 一个输入设备（鼠标或键盘）。
struct InputDevice: Identifiable, Hashable {
    /// 用来保存设置的标识：厂商号、产品号和名称。同型号的两个设备会共用设置。
    let key: String
    let name: String
    let vendorID: Int
    let productID: Int

    var id: String { key }

    /// 苹果的键盘（笔记本自带、妙控键盘）紧挨空格的一定是 ⌘，不用识别。
    /// 蓝牙连接时苹果的厂商号是 0x004C，USB 连接时是 0x05AC。
    var isApple: Bool { vendorID == 0x05AC || vendorID == 0x004C }

    static func makeKey(vendorID: Int, productID: Int, name: String) -> String {
        "\(vendorID):\(productID):\(name)"
    }
}

typealias MouseDevice = InputDevice

/// 列出已连接的鼠标或键盘，并记住最近一次是哪个设备有输入。
///
/// 系统给程序的按键、滚轮事件本身不带设备信息，所以另外监听各设备的原始输入：
/// 哪个设备刚有输入，紧接着到来的事件就算它的（M1、M2 按鼠标设置，K8 按键盘识别布局）。
/// 需要“输入监控”权限。在事件拦截线程上运行，和事件处理在同一个线程。
final class InputDeviceMonitor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let label: String
    private let deviceMatching: [[String: Int]]
    private let inputMatching: [[String: Int]]
    private let include: (InputDevice) -> Bool

    private var devices: [IOHIDDevice: InputDevice] = [:]
    /// 这次运行中有过输入的设备。键盘列表只显示打过字的设备，鼠标上的“键盘”接口（宏按键）不算。
    private var seenInput: Set<String> = []
    private var configured = false
    private var opened = false

    /// 最近一次有输入的设备。任何线程都可以读。
    let lastActive = Locked<InputDevice?>(nil)

    /// 设备列表变化时在主线程上调用。第二个参数是这次运行中有过输入的设备标识。
    var onDevicesChanged: (([InputDevice], Set<String>) -> Void)?

    private init(label: String, deviceMatching: [[String: Int]], inputMatching: [[String: Int]],
                 include: @escaping (InputDevice) -> Bool) {
        self.label = label
        self.deviceMatching = deviceMatching
        self.inputMatching = inputMatching
        self.include = include
    }

    static func mice() -> InputDeviceMonitor {
        InputDeviceMonitor(
            label: "鼠标",
            deviceMatching: [
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            ],
            // 只关心滚轮和按键，指针移动太频繁，不监听。
            inputMatching: [
                [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop, kIOHIDElementUsageKey: kHIDUsage_GD_Wheel],
                [kIOHIDElementUsagePageKey: kHIDPage_Consumer, kIOHIDElementUsageKey: kHIDUsage_Csmr_ACPan],
                [kIOHIDElementUsagePageKey: kHIDPage_Button],
            ],
            // 触控板不算鼠标（滚动和指针都由系统的触控板设置管）。
            include: { !isTrackpad(name: $0.name) }
        )
    }

    static func keyboards() -> InputDeviceMonitor {
        InputDeviceMonitor(
            label: "键盘",
            deviceMatching: [
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
                [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
            ],
            inputMatching: [
                [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad],
            ],
            include: { _ in true }
        )
    }

    /// 只有一个设备时不用猜。一个设备可能有好几个接口，按标识去重。
    var activeDevice: InputDevice? {
        let unique = Set(devices.values)
        if unique.count == 1 { return unique.first }
        return lastActive.get()
    }

    var activeKey: String? { activeDevice?.key }

    /// 开始监听。没有输入监控权限时会失败，授权后再调用一次即可。
    func start(on runLoop: CFRunLoop) {
        guard !opened else { return }
        if !configured {
            configure()
            configured = true
        }
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            opened = true
        } else {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            Log.app.error("无法打开\(self.label, privacy: .public)设备（需要输入监控权限）：\(result)")
        }
    }

    private func configure() {
        IOHIDManagerSetDeviceMatchingMultiple(manager, deviceMatching as CFArray)
        IOHIDManagerSetInputValueMatchingMultiple(manager, inputMatching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<InputDeviceMonitor>.fromOpaque(context).takeUnretainedValue().added(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<InputDeviceMonitor>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<InputDeviceMonitor>.fromOpaque(context).takeUnretainedValue().input(value)
        }, context)
    }

    private func added(_ device: IOHIDDevice) {
        guard let info = Self.describe(device), include(info) else { return }
        devices[device] = info
        Log.app.notice("\(self.label, privacy: .public)已连接：\(info.name, privacy: .public)")
        notify()
    }

    private func removed(_ device: IOHIDDevice) {
        guard let info = devices.removeValue(forKey: device) else { return }
        if lastActive.get()?.key == info.key { lastActive.set(nil) }
        notify()
    }

    private func input(_ value: IOHIDValue) {
        let device = IOHIDElementGetDevice(IOHIDValueGetElement(value))
        guard let info = devices[device] else { return }
        if lastActive.get() != info { lastActive.set(info) }
        if seenInput.insert(info.key).inserted { notify() }
    }

    private func notify() {
        let list = Array(Set(devices.values)).sorted { $0.name < $1.name }
        let seen = seenInput
        DispatchQueue.main.async { [onDevicesChanged] in onDevicesChanged?(list, seen) }
    }

    static func describe(_ device: IOHIDDevice) -> InputDevice? {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? L("未知设备")
        let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        return InputDevice(
            key: InputDevice.makeKey(vendorID: vendor, productID: product, name: name),
            name: name, vendorID: vendor, productID: product
        )
    }

    static func isTrackpad(name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("trackpad") || lower.contains("触控板")
    }
}
