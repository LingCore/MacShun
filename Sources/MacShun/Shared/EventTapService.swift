// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 在独立线程上拦截键盘和鼠标事件，交给 KeyboardEngine 和 MouseEngine 处理。
///
/// 放在独立线程上，是为了界面卡顿时不拖慢打字和滚动。拦截回调必须很快返回，
/// 超时的话系统会暂时停用拦截，这里收到停用通知后马上重新启用。
final class EventTapService {
    let keyboard: KeyboardEngine
    let mouse: MouseEngine

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private let ready = DispatchSemaphore(value: 0)

    /// 拦截是否已经成功建立。没有辅助功能权限时会失败。
    private(set) var isRunning = false

    init(keyboard: KeyboardEngine, mouse: MouseEngine) {
        self.keyboard = keyboard
        self.mouse = mouse
    }

    /// 启动拦截线程，并尝试打开鼠标设备。返回事件拦截是否成功；
    /// 失败通常是因为还没有辅助功能权限，授权后再调用一次。可以重复调用。
    @discardableResult
    func start() -> Bool {
        if thread == nil {
            let t = Thread { [weak self] in self?.threadMain() }
            t.name = "MacShun.EventTap"
            t.qualityOfService = .userInteractive
            thread = t
            t.start()
            ready.wait()
        }
        guard let runLoop else { return false }

        var created = false
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            if let self {
                created = self.tap != nil || self.createTap()
                self.mouse.devices.start(on: CFRunLoopGetCurrent())
                self.keyboard.devices.start(on: CFRunLoopGetCurrent())
            }
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        isRunning = created
        return created
    }

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        // 给运行循环一个永不触发的定时器，没有拦截时线程也不会退出。
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(runLoop, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    /// 在拦截线程上调用。
    private func createTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("无法建立事件拦截，可能还没有辅助功能权限")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.app.notice("事件拦截已启动")
        return true
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            keyboard.reset(proxy: proxy)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.app.notice("事件拦截被系统暂停，已重新启用")
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        if Synthetic.isSynthetic(event) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return keyboard.handle(type: type, event: event, proxy: proxy)
        case .scrollWheel, .otherMouseDown, .otherMouseUp:
            return mouse.handle(type: type, event: event, proxy: proxy)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<EventTapService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handle(proxy: proxy, type: type, event: event)
}
