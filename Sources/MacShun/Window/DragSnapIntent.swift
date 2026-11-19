// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 拖动吸附的纯状态机。光标始终自由移动；共享边缘只有停稳后才预览。
struct DragSnapIntent {
    // 初始交互参数，单位是全局逻辑点和秒；不使用设备原始 delta。
    static let dwell: TimeInterval = 0.18
    static let crossingGrace: TimeInterval = 0.25
    private static let approachSpeed: CGFloat = 300
    private static let motionTolerance: CGFloat = 6

    private let screens: [CGRect]
    private var screen: Int?
    private var lastPoint: CGPoint
    private var lastTime: TimeInterval
    private var protectedUntil: TimeInterval = 0
    private var candidate: WindowLayout.DragTarget?
    private var enteredAt: TimeInterval = 0
    private var anchor: CGPoint

    private(set) var target: WindowLayout.DragTarget?
    /// 没有新的鼠标事件时，也需要在这个时刻重新核对光标并更新预览。
    private(set) var deadline: TimeInterval?

    init(screens: [CGRect], cursor: CGPoint, time: TimeInterval) {
        self.screens = screens
        screen = WindowLayout.screenIndex(at: cursor, screens: screens)
        lastPoint = cursor
        lastTime = time
        anchor = cursor
    }

    mutating func update(cursor: CGPoint, time: TimeInterval) {
        let now = max(time, lastTime)
        let distance = hypot(cursor.x - lastPoint.x, cursor.y - lastPoint.y)
        let elapsed = now - lastTime
        lastPoint = cursor
        lastTime = now

        let currentScreen = WindowLayout.screenIndex(at: cursor, screens: screens)
        if currentScreen != screen {
            clearCandidate()
            screen = currentScreen
            protectedUntil = now + Self.crossingGrace
        }

        var next = WindowLayout.dragCandidate(cursor: cursor, screens: screens)
        // 已进入候选区后允许少量手抖，但只保留同一块屏幕的同一个目标。
        if next == nil, let candidate, candidate.isShared,
           WindowLayout.dragCandidate(cursor: cursor, screens: screens, sharedMargin: 12) == candidate {
            next = candidate
        }
        guard let next else {
            clearCandidate()
            return
        }
        if next != candidate {
            candidate = next
            enteredAt = now
            anchor = cursor
        }
        guard next.isShared else {
            target = next
            deadline = nil
            return
        }

        // 已预览时只按相对锚点的位移判断是否撤离，避免高回报率鼠标或松手瞬间微抖/时间戳持平导致误取消。
        let displaced = hypot(cursor.x - anchor.x, cursor.y - anchor.y) > Self.motionTolerance
        let fastApproach = target != next && elapsed > 0 && distance > 1.5 && (distance / elapsed) > Self.approachSpeed
        if displaced || fastApproach {
            enteredAt = now
            anchor = cursor
        }
        let readyAt = max(enteredAt + Self.dwell, protectedUntil)
        target = now >= readyAt ? next : nil
        deadline = target == nil ? readyAt : nil
    }

    /// 松手只允许提交已经预览且仍然有效的目标，不能靠 mouse-up 凭空激活一个目标。
    mutating func release(cursor: CGPoint, time: TimeInterval) -> WindowLayout.DragTarget? {
        let shown = target
        update(cursor: cursor, time: time)
        return shown == target ? shown : nil
    }

    private mutating func clearCandidate() {
        candidate = nil
        target = nil
        deadline = nil
    }
}
