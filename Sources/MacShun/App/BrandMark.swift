// SPDX-License-Identifier: MIT

import AppKit

/// 菜单栏里的 Mac顺 标志：和程序图标的小尺寸同一个造型——一笔画成的 ⌘，圈是圆角方环，
/// 右上角整个是一片实心叶子（菜单栏太小，方叶的叶尖和叶脉看不清）。
/// 做成模板图，系统会按菜单栏的深浅自动着色。
enum BrandMark {
    /// 18×18 点；尺寸按 Retina 的 36×36 像素设计：线宽 3px，每条线的两边都落在整像素上。
    static func menuBarImage(needsAttention: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let c: CGFloat = 9, h: CGFloat = 2.25, loop: CGFloat = 2.25, r: CGFloat = 1.5
            let path = commandPath(center: c, h: h, loop: loop, radius: r)
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let leaf = leafPath(center: c, h: h, loop: loop)

            if needsAttention {
                // 右下角挖掉一块，放一个实心圆点，提示还需要授权
                let dot = NSRect(x: 12, y: 12, width: 6, height: 6)
                NSGraphicsContext.current?.saveGraphicsState()
                let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
                clip.append(NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).reversed)
                clip.addClip()
                path.stroke()
                leaf.fill()
                NSGraphicsContext.current?.restoreGraphicsState()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                path.stroke()
                leaf.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("Mac顺")
        return image
    }

    /// 叶尖比其他环的外角再往外伸出的距离（点）；叶子的胖瘦（弧线控制点的位置，1 最胖）。和 scripts/make-icon.py 一致。
    static let leafTip: CGFloat = 0
    static let leafSlim: CGFloat = 0.9

    /// 叶子两条弧线的控制点：下沿、上沿。
    static func leafControls(center c: CGFloat, h: CGFloat, tip t: CGFloat) -> (NSPoint, NSPoint) {
        let k = leafSlim, span = t - h
        return (NSPoint(x: c + h + k * span, y: c - h - (1 - k) * span),
                NSPoint(x: c + h + (1 - k) * span, y: c - h - k * span))
    }

    /// 一笔画成的 ⌘：中间方框的四条边延伸出去，在四个角绕成边长 2×loop、圆角 radius 的环再回来；
    /// 右上角的环是整片叶子：两侧都是从叶柄到叶尖的整段弧线。
    /// 和 scripts/make-icon.py 里 cmd_path 的 ("solid", t) 是同一个画法。
    static func commandPath(center c: CGFloat, h: CGFloat, loop: CGFloat, radius r: CGFloat) -> NSBezierPath {
        let e = h + 2 * loop
        let t = e + leafTip                               // 叶尖的位置
        let rl = t - h
        let (b1, b2) = leafControls(center: c, h: h, tip: t)
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: c + x, y: c + y) }
        // 直线走到 a，以 b 为角点圆角转到 d
        func corner(_ a: NSPoint, _ b: NSPoint, _ d: NSPoint) {
            path.line(to: a)
            path.curve(to: d, controlPoint1: b, controlPoint2: b)
        }
        path.move(to: p(-h, -h))
        corner(p(-h, -e + r), p(-h, -e), p(-h - r, -e))
        corner(p(-e + r, -e), p(-e, -e), p(-e, -e + r))
        corner(p(-e, -h - r), p(-e, -h), p(-e + r, -h))
        corner(p(t - rl, -h), b1, p(t, -h - rl))         // 叶子下沿扫到叶尖
        corner(p(h + rl, -t), b2, p(h, -t + rl))         // 叶子上沿扫回叶柄
        corner(p(h, e - r), p(h, e), p(h + r, e))
        corner(p(e - r, e), p(e, e), p(e, e - r))
        corner(p(e, h + r), p(e, h), p(e - r, h))
        corner(p(-e + r, h), p(-e, h), p(-e, h + r))
        corner(p(-e, e - r), p(-e, e), p(-e + r, e))
        corner(p(-h - r, e), p(-h, e), p(-h, e - r))
        path.close()
        return path
    }

    /// 右上角叶子的实心填充，轮廓和 commandPath 里的叶子一致。
    static func leafPath(center c: CGFloat, h: CGFloat, loop: CGFloat) -> NSBezierPath {
        let t = h + 2 * loop + leafTip
        let stalk = NSPoint(x: c + h, y: c - h), tip = NSPoint(x: c + t, y: c - t)
        let (b1, b2) = leafControls(center: c, h: h, tip: t)
        let path = NSBezierPath()
        path.move(to: stalk)
        path.curve(to: tip, controlPoint1: b1, controlPoint2: b1)
        path.curve(to: stalk, controlPoint1: b2, controlPoint2: b2)
        path.close()
        return path
    }
}
