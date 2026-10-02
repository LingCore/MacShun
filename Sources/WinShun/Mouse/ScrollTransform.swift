// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 一个方向上的滚动量。系统同时给出三种单位，改的时候三个都要改。
struct ScrollAxis: Equatable {
    /// 行数（整数，已经被系统加速过）
    var lines: Int64
    /// 行数（小数）
    var fixed: Double
    /// 像素
    var points: Int64

    static let zero = ScrollAxis(lines: 0, fixed: 0, points: 0)

    var sign: Int64 {
        if fixed != 0 { return fixed > 0 ? 1 : -1 }
        if lines != 0 { return lines > 0 ? 1 : -1 }
        if points != 0 { return points > 0 ? 1 : -1 }
        return 0
    }

    var negated: ScrollAxis {
        ScrollAxis(lines: -lines, fixed: -fixed, points: -points)
    }
}

/// 滚轮事件的换算（M2、M3）。只处理一格一格的滚轮，触控板和妙控鼠标不经过这里。
enum ScrollTransform {
    /// 按行滚动时每行对应的像素，和系统的默认值一致。
    static let pointsPerLine: Int64 = 10

    /// - Parameters:
    ///   - vertical: 竖直方向（Axis1）
    ///   - horizontal: 水平方向（Axis2）
    ///   - invertedFromDevice: 系统是否因为“自然滚动”把方向反过来了
    static func apply(
        vertical: ScrollAxis, horizontal: ScrollAxis,
        invertedFromDevice: Bool, settings: MouseDeviceSettings
    ) -> (vertical: ScrollAxis, horizontal: ScrollAxis) {
        var v = vertical
        var h = horizontal

        // Windows 的方向：滚轮往下转，内容往上走（看到下面的内容）。
        // macOS 开着“自然滚动”时方向是反的，这里再反回来。
        if settings.windowsScrollDirection && invertedFromDevice {
            v = v.negated
            h = h.negated
        }

        if settings.linearScroll {
            v = linear(v, lines: settings.scrollLines)
            h = linear(h, lines: settings.scrollLines)
        }
        return (v, h)
    }

    /// 不管转得多快，每一格都滚固定的行数。
    static func linear(_ axis: ScrollAxis, lines: Int) -> ScrollAxis {
        let s = axis.sign
        guard s != 0 else { return axis }
        let n = Int64(lines) * s
        return ScrollAxis(lines: n, fixed: Double(n), points: n * pointsPerLine)
    }

    /// Ctrl+滚轮缩放时，判断滚轮实际转的方向。返回 true 表示往上转（远离自己）。
    static func isPhysicallyUp(_ axis: ScrollAxis, invertedFromDevice: Bool) -> Bool? {
        let s = axis.sign
        guard s != 0 else { return nil }
        return invertedFromDevice ? s < 0 : s > 0
    }
}
