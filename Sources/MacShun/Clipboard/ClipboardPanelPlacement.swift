// SPDX-License-Identifier: MIT

import AppKit

struct ClipboardPanelPlacement {
    static let screenInset: CGFloat = 8
    private static let minimumHeight: CGFloat = 240

    let frame: CGRect
    let opensAbove: Bool

    init(anchor: CGRect, gap: CGFloat, visibleFrame: CGRect) {
        let area = visibleFrame.insetBy(dx: Self.screenInset, dy: Self.screenInset)
        let size = ClipboardPanel.size
        let below = anchor.minY - gap
        let above = anchor.maxY + gap
        let roomBelow = min(size.height, below - area.minY)
        let roomAbove = min(size.height, area.maxY - above)

        // 有足够空间时优先向下，否则选能显示更多内容的一侧。
        opensAbove = roomAbove > roomBelow
        let room = opensAbove ? roomAbove : roomBelow
        let height = min(max(room, Self.minimumHeight), area.height)
        let proposed = CGRect(x: anchor.minX, y: opensAbove ? above : below - height,
                              width: size.width, height: height)
        frame = WindowPlacement.fittedFrame(proposed, in: area, centered: false)
    }
}
