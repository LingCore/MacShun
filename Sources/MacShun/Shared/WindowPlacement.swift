// SPDX-License-Identifier: MIT

import AppKit

/// Window and pointer positions here use AppKit's global coordinate space, in points.
enum WindowPlacement {
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first {
                point.x >= $0.frame.minX && point.x <= $0.frame.maxX
                    && point.y >= $0.frame.minY && point.y <= $0.frame.maxY
            }
    }

    static func pointerScreen(at point: CGPoint) -> NSScreen? {
        screen(containing: point) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Keep the window in place on the same display when possible. Recenter it on a different display.
    static func place(_ window: NSWindow, on screen: NSScreen?, centered: Bool = false) {
        guard let screen else { return }
        let frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let target = fittedFrame(frame, in: screen.visibleFrame, centered: centered || !screen.frame.contains(center))
        if target != frame { window.setFrame(target, display: window.isVisible) }
    }

    static func fittedFrame(_ frame: CGRect, in area: CGRect, centered: Bool) -> CGRect {
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        let x = centered ? area.midX - width / 2 : min(max(frame.minX, area.minX), area.maxX - width)
        let y = centered ? area.midY - height / 2 : min(max(frame.minY, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
