// SPDX-License-Identifier: MIT

import CoreGraphics

/// 矩形选区四边与四角的缩放手柄。坐标系为 AppKit（左下原点，y 向上）。
enum CaptureSelectionHandle: Equatable, CaseIterable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// 矩形选区的边角命中、拖动缩放（支持翻转与比例锁定）、方圆约束与视觉边缘磁吸计算。
enum CaptureSelectionGeometry {
    static let defaultReach: CGFloat = 6
    static let defaultSnapTolerance: CGFloat = 4

    /// 命中选区四条整边或四角（四角优先于四边；极小选区时较近的一侧胜出）。
    static func handle(at point: CGPoint, in rect: CGRect, reach: CGFloat = defaultReach) -> CaptureSelectionHandle? {
        guard !rect.isEmpty else { return nil }
        guard point.x >= rect.minX - reach, point.x <= rect.maxX + reach,
              point.y >= rect.minY - reach, point.y <= rect.maxY + reach else { return nil }
        let distLeft = abs(point.x - rect.minX)
        let distRight = abs(point.x - rect.maxX)
        let distBottom = abs(point.y - rect.minY)
        let distTop = abs(point.y - rect.maxY)
        let nearLeft = distLeft <= reach
        let nearRight = distRight <= reach
        let nearBottom = distBottom <= reach
        let nearTop = distTop <= reach
        let left = nearLeft && (!nearRight || distLeft <= distRight)
        let right = nearRight && !left
        let bottom = nearBottom && (!nearTop || distBottom <= distTop)
        let top = nearTop && !bottom
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return nil
    }

    /// 拖动手柄调整选区，支持拖过对边自动翻转与可选宽高比锁定，结果始终限制在 bounds 内且至少 1×1。
    static func resized(
        from start: CGRect,
        handle: CaptureSelectionHandle,
        delta: CGSize,
        in bounds: CGRect,
        aspectRatio: CGFloat? = nil
    ) -> CGRect {
        guard bounds.width >= 1, bounds.height >= 1 else { return start }
        if let ratio = aspectRatio, ratio > 0 {
            return resizedLocked(from: start, handle: handle, delta: delta, in: bounds, ratio: ratio)
        }
        var left = start.minX
        var right = start.maxX
        var bottom = start.minY
        var top = start.maxY
        if handle.movesLeft { left = min(max(bounds.minX, left + delta.width), bounds.maxX) }
        if handle.movesRight { right = min(max(bounds.minX, right + delta.width), bounds.maxX) }
        if handle.movesBottom { bottom = min(max(bounds.minY, bottom + delta.height), bounds.maxY) }
        if handle.movesTop { top = min(max(bounds.minY, top + delta.height), bounds.maxY) }
        if left > right { swap(&left, &right) }
        if bottom > top { swap(&bottom, &top) }
        if right - left < 1 {
            if left + 1 <= bounds.maxX { right = left + 1 } else { left = right - 1 }
        }
        if top - bottom < 1 {
            if bottom + 1 <= bounds.maxY { top = bottom + 1 } else { bottom = top - 1 }
        }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private static func resizedLocked(
        from start: CGRect,
        handle: CaptureSelectionHandle,
        delta: CGSize,
        in bounds: CGRect,
        ratio: CGFloat
    ) -> CGRect {
        if handle.isCorner {
            let anchorX = handle.movesLeft ? start.maxX : start.minX
            let anchorY = handle.movesBottom ? start.maxY : start.minY
            let rawX = (handle.movesLeft ? start.minX : start.maxX) + delta.width
            let rawY = (handle.movesBottom ? start.minY : start.maxY) + delta.height
            let signX: CGFloat = rawX >= anchorX ? 1 : -1
            let signY: CGFloat = rawY >= anchorY ? 1 : -1
            let maxW = max(1, signX > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX)
            let maxH = max(1, signY > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY)
            var w = abs(rawX - anchorX)
            var h = abs(rawY - anchorY)
            if w / ratio >= h {
                h = w / ratio
            } else {
                w = h * ratio
            }
            if w > maxW { w = maxW; h = w / ratio }
            if h > maxH { h = maxH; w = h * ratio }
            w = max(1, min(w, maxW))
            h = max(1, min(h, maxH))
            let x = signX > 0 ? anchorX : anchorX - w
            let y = signY > 0 ? anchorY : anchorY - h
            return CGRect(x: x, y: y, width: w, height: h)
        }
        if handle == .left || handle == .right {
            let anchorX = handle == .left ? start.maxX : start.minX
            let rawX = (handle == .left ? start.minX : start.maxX) + delta.width
            let signX: CGFloat = rawX >= anchorX ? 1 : -1
            let maxW = max(1, signX > 0 ? bounds.maxX - anchorX : anchorX - bounds.minX)
            var w = min(max(1, abs(rawX - anchorX)), maxW)
            var h = w / ratio
            if h > bounds.height { h = bounds.height; w = min(maxW, h * ratio) }
            let x = signX > 0 ? anchorX : anchorX - w
            let y = min(max(bounds.minY, start.midY - h / 2), bounds.maxY - h)
            return CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
        }
        let anchorY = handle == .bottom ? start.maxY : start.minY
        let rawY = (handle == .bottom ? start.minY : start.maxY) + delta.height
        let signY: CGFloat = rawY >= anchorY ? 1 : -1
        let maxH = max(1, signY > 0 ? bounds.maxY - anchorY : anchorY - bounds.minY)
        var h = min(max(1, abs(rawY - anchorY)), maxH)
        var w = h * ratio
        if w > bounds.width { w = bounds.width; h = min(maxH, w / ratio) }
        let x = min(max(bounds.minX, start.midX - w / 2), bounds.maxX - w)
        let y = signY > 0 ? anchorY : anchorY - h
        return CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
    }

    /// 按可选宽高比从起点拖到终点构造选区，限制在 bounds 内。
    static func rect(from start: CGPoint, to end: CGPoint, in bounds: CGRect, aspectRatio: CGFloat? = nil) -> CGRect {
        let clampedEnd = CGPoint(x: min(max(bounds.minX, end.x), bounds.maxX),
                                 y: min(max(bounds.minY, end.y), bounds.maxY))
        guard let ratio = aspectRatio, ratio > 0 else {
            return CGRect(x: min(start.x, clampedEnd.x), y: min(start.y, clampedEnd.y),
                          width: abs(clampedEnd.x - start.x), height: abs(clampedEnd.y - start.y))
        }
        let dx = clampedEnd.x - start.x
        let dy = clampedEnd.y - start.y
        let signX: CGFloat = dx >= 0 ? 1 : -1
        let signY: CGFloat = dy >= 0 ? 1 : -1
        let maxW = max(0, signX > 0 ? bounds.maxX - start.x : start.x - bounds.minX)
        let maxH = max(0, signY > 0 ? bounds.maxY - start.y : start.y - bounds.minY)
        var w = abs(dx)
        var h = abs(dy)
        if w / ratio >= h {
            h = w / ratio
        } else {
            w = h * ratio
        }
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        let x = signX > 0 ? start.x : start.x - w
        let y = signY > 0 ? start.y : start.y - h
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Shift 按住画正方形/正圆时把终点约束为 1:1，并限制在 bounds 内。
    static func squareEnd(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGPoint {
        let clamped = CGPoint(x: min(max(bounds.minX, end.x), bounds.maxX),
                              y: min(max(bounds.minY, end.y), bounds.maxY))
        let dx = clamped.x - start.x
        let dy = clamped.y - start.y
        let signX: CGFloat = dx >= 0 ? 1 : -1
        let signY: CGFloat = dy >= 0 ? 1 : -1
        let maxW = signX > 0 ? bounds.maxX - start.x : start.x - bounds.minX
        let maxH = signY > 0 ? bounds.maxY - start.y : start.y - bounds.minY
        let side = min(max(abs(dx), abs(dy)), min(maxW, maxH))
        return CGPoint(x: start.x + signX * side, y: start.y + signY * side)
    }

    /// 将单个坐标轻度磁吸到候选视觉边缘（tolerance 内取最近值）。
    static func snap(_ value: CGFloat, to guides: [CGFloat], tolerance: CGFloat = defaultSnapTolerance) -> CGFloat {
        var best = value
        var bestDist = tolerance
        for g in guides {
            let d = abs(g - value)
            if d <= bestDist {
                bestDist = d
                best = g
            }
        }
        return best
    }

    /// 将一个正在缩放的矩形的移动边磁吸到候选水平/垂直边缘。
    static func snapResized(
        _ rect: CGRect,
        handle: CaptureSelectionHandle,
        xGuides: [CGFloat],
        yGuides: [CGFloat],
        in bounds: CGRect,
        tolerance: CGFloat = defaultSnapTolerance
    ) -> CGRect {
        var left = rect.minX
        var right = rect.maxX
        var bottom = rect.minY
        var top = rect.maxY
        if handle.movesLeft { left = snap(left, to: xGuides, tolerance: tolerance) }
        if handle.movesRight { right = snap(right, to: xGuides, tolerance: tolerance) }
        if handle.movesBottom { bottom = snap(bottom, to: yGuides, tolerance: tolerance) }
        if handle.movesTop { top = snap(top, to: yGuides, tolerance: tolerance) }
        left = min(max(bounds.minX, left), bounds.maxX)
        right = min(max(bounds.minX, right), bounds.maxX)
        bottom = min(max(bounds.minY, bottom), bounds.maxY)
        top = min(max(bounds.minY, top), bounds.maxY)
        guard right - left >= 1, top - bottom >= 1 else { return rect }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
