// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 在独立线程上拦截键盘和鼠标事件，交给 KeyboardEngine 和 MouseEngine 处理。
///
/// 放在独立线程上，是为了界面卡顿时不拖慢打字和滚动。拦截回调必须很快返回，
/// 超时的话系统会暂时停用拦截，这里收到停用通知后马上重新启用。
final class EventTapService {
    private final class TapHandles: @unchecked Sendable {
        var keepAlive: CFRunLoopTimer?
        var tap: CFMachPort?
        var tapSource: CFRunLoopSource?

        func invalidateTap() {
            if let tapSource {
                if let current = CFRunLoopGetCurrent() {
                    CFRunLoopRemoveSource(current, tapSource, .commonModes)
                }
                CFRunLoopSourceInvalidate(tapSource)
                self.tapSource = nil
            }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                self.tap = nil
            }
        }
    }

    let keyboard: KeyboardEngine
    let mouse: MouseEngine

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let handles = TapHandles()
    private let ready = DispatchSemaphore(value: 0)
    private let runningState = Locked(false)

    /// 拦截是否已经成功建立。没有辅助功能权限时会失败。
    var isRunning: Bool { runningState.get() }
    /// 拦截状态发生变化时在主线程回调（例如拦截端口失效且重建失败时通知界面与重试逻辑）。
    var onStateChanged: ((Bool) -> Void)?

    init(keyboard: KeyboardEngine, mouse: MouseEngine) {
        self.keyboard = keyboard
        self.mouse = mouse
    }

    deinit {
        stop()
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

        let created = Locked(false)
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            autoreleasepool {
                if let self {
                    let active = self.ensureTapActive()
                    created.set(active)
                    self.mouse.devices.start(on: CFRunLoopGetCurrent())
                    self.keyboard.devices.start(on: CFRunLoopGetCurrent())
                }
            }
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        if done.wait(timeout: .now() + 1.0) == .timedOut {
            Log.app.error("启动事件拦截超时，拦截线程可能暂时繁忙")
            return runningState.get()
        }
        let active = created.get()
        updateRunning(active)
        return active
    }

    /// 异步核对并在必要时重建事件拦截（用于睡眠唤醒或切回用户会话后自愈，不阻塞主线程）。
    func verifyActive() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            autoreleasepool {
                guard let self else { return }
                let active = self.ensureTapActive()
                self.mouse.devices.start(on: CFRunLoopGetCurrent())
                self.keyboard.devices.start(on: CFRunLoopGetCurrent())
                self.updateRunning(active)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// 停止事件拦截与设备监听，并退出拦截线程（可从 deinit 安全调用，不依赖 [weak self]）。
    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        thread = nil
        updateRunning(false)
        let handles = self.handles
        let mouseDevices = self.mouse.devices
        let keyboardDevices = self.keyboard.devices
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            autoreleasepool {
                let current = CFRunLoopGetCurrent()!
                handles.invalidateTap()
                mouseDevices.stop(from: current)
                keyboardDevices.stop(from: current)
                if let keepAlive = handles.keepAlive {
                    CFRunLoopRemoveTimer(current, keepAlive, .commonModes)
                    handles.keepAlive = nil
                }
                CFRunLoopStop(current)
            }
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        _ = done.wait(timeout: .now() + 1.0)
    }

    private func updateRunning(_ active: Bool) {
        let changed = runningState.update { old in
            guard old != active else { return false }
            old = active
            return true
        }
        if changed, let callback = onStateChanged {
            DispatchQueue.main.async { callback(active) }
        }
    }

    private func threadMain() {
        let current = CFRunLoopGetCurrent()
        runLoop = current
        // 给运行循环一个永不触发的定时器，没有拦截时线程也不会退出。
        let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        handles.keepAlive = keepAlive
        CFRunLoopAddTimer(current, keepAlive, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    /// 在拦截线程上调用：校验现有拦截端口是否仍有效并处于启用状态，失效则重建。
    private func ensureTapActive() -> Bool {
        if let tap = handles.tap {
            if CFMachPortIsValid(tap) {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                if CGEvent.tapIsEnabled(tap: tap) {
                    return true
                }
            }
            handles.invalidateTap()
        }
        return createTap()
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
        handles.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        handles.tapSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.app.notice("事件拦截已启动")
        return true
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            keyboard.reset(proxy: proxy)
            mouse.reset()
            let active = ensureTapActive()
            updateRunning(active)
            if active {
                Log.app.notice("事件拦截被系统暂停，已重新启用")
            } else {
                Log.app.error("事件拦截被系统暂停，且重新启用或重建失败")
            }
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
        case .scrollWheel:
            keyboard.cancelDoubleControl()
            return mouse.handle(type: type, event: event, proxy: proxy)
        case .otherMouseDown:
            keyboard.cancelDoubleControl()
            return mouse.handle(type: type, event: event, proxy: proxy)
        case .otherMouseUp:
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
    return autoreleasepool {
        let service = Unmanaged<EventTapService>.fromOpaque(userInfo).takeUnretainedValue()
        return service.handle(proxy: proxy, type: type, event: event)
    }
}
