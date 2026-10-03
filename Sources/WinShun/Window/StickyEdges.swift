// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// 拖窗口经过两块屏幕相接的边时，让鼠标在边上停一下（Windows 也是这样），好分到这块屏幕靠那边的一半；
/// 继续往外推够一段距离才过去，快速甩过去基本感觉不到。只在能分屏的地方停，例如下边中间不停。
/// 纯计算，坐标是全局坐标（原点在主屏幕左上角，和 AX 一样）。
struct EdgeResistance {
    /// 往外推多远才放过去（点）
    static let breakThrough: CGFloat = 100
    /// 离开边这么远才重新计算推了多远，贴着边抖一下不算
    static let release: CGFloat = 8

    let screens: [CGRect]
    /// 鼠标现在的位置
    private(set) var cursor: CGPoint?
    /// 挡住以后已经往外推了多远
    private(set) var pushed: CGFloat = 0

    init(screens: [CGRect], cursor: CGPoint?) {
        self.screens = screens
        self.cursor = cursor
    }

    /// 鼠标这一下要移到 point（delta 是这一下实际移动的距离，不知道时传 .zero），返回鼠标应该在的位置。
    mutating func filter(_ point: CGPoint, delta: CGVector = .zero) -> CGPoint {
        let result = resolve(point, delta: delta)
        cursor = result
        return result
    }

    private mutating func resolve(_ point: CGPoint, delta: CGVector) -> CGPoint {
        guard let cursor, let from = screens.first(where: { $0.contains(cursor) }) else {
            pushed = 0
            return point
        }
        if from.contains(point) {
            let inset = min(point.x - from.minX, from.maxX - 1 - point.x, point.y - from.minY, from.maxY - 1 - point.y)
            if inset > Self.release { pushed = 0 }
            return point
        }
        guard screens.contains(where: { $0.contains(point) }) else { return point }
        // 挡在现在这块屏幕的边上
        let edge = CGPoint(x: min(max(point.x, from.minX), from.maxX - 1), y: min(max(point.y, from.minY), from.maxY - 1))
        guard WindowLayout.dragTarget(cursor: edge, screens: screens) != nil else {
            pushed = 0
            return point
        }
        let beyondX = abs(point.x - edge.x)
        let beyondY = abs(point.y - edge.y)
        var step = beyondX + beyondY
        // 挡住以后系统可能还按原来的位置算出几下，超出很多；按这一下实际移动的距离算
        let moved = (beyondX > 0 ? abs(delta.dx) : 0) + (beyondY > 0 ? abs(delta.dy) : 0)
        if moved > 0 { step = min(step, moved) }
        pushed += step
        if pushed >= Self.breakThrough {
            pushed = 0
            return point
        }
        return edge
    }
}

/// 拖窗口时把鼠标挡在两块屏幕相接的边上（挡不挡由 EdgeResistance 算）。
/// 在独立线程上拦截拖动事件，只在确定是在拖窗口时打开，平时不拦截任何事件。
final class StickyEdges {
    private let lock = NSLock()
    private var resistance: EdgeResistance?
    private var tap: CFMachPort?
    private var failed = false

    /// 开始挡。screens 是所有屏幕的整块区域（全局坐标）。主线程调用。
    func activate(screens: [CGRect]) {
        guard screens.count > 1 else { return }
        let cursor = CGEvent(source: nil)?.location
        lock.withLock { resistance = EdgeResistance(screens: screens, cursor: cursor) }
        guard let tap = tap ?? makeTap() else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 停止挡。主线程调用。
    func deactivate() {
        lock.withLock {
            resistance = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        }
    }

    private func makeTap() -> CFMachPort? {
        guard !failed else { return nil }
        let mask = [CGEventType.leftMouseDragged, .leftMouseUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let info = Unmanaged.passUnretained(self).toOpaque()
        // 越早越好：在系统把事件交给程序之前改掉
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: stickyEdgesCallback, userInfo: info)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: stickyEdgesCallback, userInfo: info)
        else {
            failed = true
            Log.app.error("分屏：无法拦截拖动事件，两块屏幕之间的边不会停")
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // 先存好再启动线程：拦截线程会读它
        self.tap = tap
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "WinShun.StickyEdges"
        thread.qualityOfService = .userInteractive
        thread.start()
        return tap
    }

    /// 在拦截线程上调用，要很快返回。
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 在锁里判断和重新打开，免得和主线程的 deactivate 交错
            lock.withLock { if resistance != nil, let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
        case .leftMouseDragged:
            let point = event.location
            let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            let target = lock.withLock { resistance?.filter(point, delta: delta) }
            if let target, target != point {
                CGWarpMouseCursorPosition(target)
                // 移动鼠标以后系统默认会停一会儿不理鼠标，这样马上恢复
                CGAssociateMouseAndMouseCursorPosition(1)
                event.location = target
            }
        case .leftMouseUp:
            lock.withLock {
                resistance = nil
                if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private func stickyEdgesCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<StickyEdges>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
}
