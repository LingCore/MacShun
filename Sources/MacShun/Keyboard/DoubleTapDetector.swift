// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// 识别“连按两下 Ctrl”（F1 呼出文件搜索）。只看事件，不拦截：Ctrl 照常发给系统。
///
/// 一下 = 单独按下 Ctrl（没有同时按着别的修饰键）并在 maxPress 内松开，中间没有按别的键；
/// 第一下松开后 maxGap 内又按了一下就算连按两下，第二下松开的那一刻触发。
/// 不在第二下按下时触发：按一下 Ctrl 接着按 Ctrl+V、Ctrl+C 这类快捷键时，第二下中间按了别的键，不算。
/// 中间按了别的键或别的修饰键都会重新计。
struct DoubleTapDetector {
    enum Input {
        /// Ctrl 按下或松开；flags 是事件带的修饰键
        case control(down: Bool, flags: CGEventFlags)
        /// 别的键按下，或者别的修饰键有变化
        case other
    }

    var maxPress: TimeInterval = 0.35
    var maxGap: TimeInterval = 0.4

    private enum State {
        case idle
        /// 第一下按下的时间
        case firstDown(TimeInterval)
        /// 第一下松开的时间
        case firstUp(TimeInterval)
        /// 第二下按下的时间
        case secondDown(TimeInterval)
    }

    private var state: State = .idle

    /// 正按着的这一下是什么时候按下的（第一下或第二下）
    var pressStart: TimeInterval? {
        switch state {
        case .firstDown(let start), .secondDown(let start): start
        default: nil
        }
    }

    /// 返回 true 表示这一下完成了“连按两下”。
    mutating func feed(_ input: Input, at time: TimeInterval) -> Bool {
        switch input {
        case .other:
            state = .idle
            return false

        case .control(let down, let flags):
            let others = flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn])
            if !others.isEmpty {
                state = .idle
                return false
            }
            switch (state, down) {
            case (.firstDown(let start), false):
                state = time - start <= maxPress ? .firstUp(time) : .idle
            case (.firstUp(let released), true):
                state = time - released <= maxGap ? .secondDown(time) : .firstDown(time)
            case (.secondDown(let start), false):
                state = .idle
                return time - start <= maxPress
            case (_, true):
                state = .firstDown(time)
            default:
                state = .idle
            }
            return false
        }
    }
}
