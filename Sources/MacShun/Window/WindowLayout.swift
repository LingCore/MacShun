// SPDX-License-Identifier: MIT

import CoreGraphics

/// 分屏（W1–W3）的几何计算和 Win+方向键的规则。纯函数，方便测试。
///
/// 坐标一律用辅助功能接口（AX）的坐标：原点在主屏幕左上角，y 向下。屏幕区域指去掉菜单栏和程序坞的可用区域。
enum WindowLayout {
    /// 分屏的位置
    enum Position: String, CaseIterable {
        case leftHalf, rightHalf, topLeft, topRight, bottomLeft, bottomRight, maximized

        /// 在这块区域里的大小和位置。宽高是奇数时左边、上边少一点，拼起来不留缝。
        func frame(in area: CGRect) -> CGRect {
            let halfWidth = (area.width / 2).rounded(.down)
            let halfHeight = (area.height / 2).rounded(.down)
            let left = CGRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height)
            let right = CGRect(x: area.minX + halfWidth, y: area.minY, width: area.width - halfWidth, height: area.height)
            switch self {
            case .leftHalf: return left
            case .rightHalf: return right
            case .topLeft: return CGRect(x: left.minX, y: area.minY, width: left.width, height: halfHeight)
            case .topRight: return CGRect(x: right.minX, y: area.minY, width: right.width, height: halfHeight)
            case .bottomLeft: return CGRect(x: left.minX, y: area.minY + halfHeight, width: left.width, height: area.height - halfHeight)
            case .bottomRight: return CGRect(x: right.minX, y: area.minY + halfHeight, width: right.width, height: area.height - halfHeight)
            case .maximized: return area
            }
        }

        /// 分到这一半以后，另一半（贴靠助手在那里列出其他窗口）
        var opposite: Position? {
            switch self {
            case .leftHalf: .rightHalf
            case .rightHalf: .leftHalf
            default: nil
            }
        }
    }

    /// 窗口现在在哪个分屏位置。终端这类按字符调整大小的程序对不齐，每条边允许差一点。
    static func position(of frame: CGRect, in area: CGRect, tolerance: CGFloat = 16) -> Position? {
        Position.allCases.first { position in
            let target = position.frame(in: area)
            return abs(frame.minX - target.minX) <= tolerance && abs(frame.minY - target.minY) <= tolerance
                && abs(frame.maxX - target.maxX) <= tolerance && abs(frame.maxY - target.maxY) <= tolerance
        }
    }

    enum Key {
        case left, right, up, down
    }

    enum Command: Equatable {
        /// 分到某块屏幕（从左到右的序号）的某个位置
        case snap(Position, screen: Int)
        /// 恢复分屏之前的大小和位置
        case restore
        case minimize
        case none
    }

    /// Windows 11 的 Win+方向键：
    /// - 普通窗口：← → 分到左右半边，↑ 最大化，↓ 最小化；
    /// - 左半边：↑ ↓ 变成左上、左下四分之一，→ 恢复原来的大小，← 移到左边那块屏幕的右半边；右半边对称；
    /// - 四分之一：往同一侧再按一次移到隔壁屏幕，往另一侧移到对面的四分之一，↑ ↓ 回到半边（或最大化、最小化）；
    /// - 最大化：← → 分到半边，↓ 恢复。
    static func command(for key: Key, current: Position?, screen: Int, screenCount: Int) -> Command {
        let hasLeft = screen > 0
        let hasRight = screen < screenCount - 1
        switch (current, key) {
        case (nil, .left): return .snap(.leftHalf, screen: screen)
        case (nil, .right): return .snap(.rightHalf, screen: screen)
        case (nil, .up): return .snap(.maximized, screen: screen)
        case (nil, .down): return .minimize

        case (.leftHalf, .left): return hasLeft ? .snap(.rightHalf, screen: screen - 1) : .none
        case (.leftHalf, .right): return .restore
        case (.leftHalf, .up): return .snap(.topLeft, screen: screen)
        case (.leftHalf, .down): return .snap(.bottomLeft, screen: screen)

        case (.rightHalf, .right): return hasRight ? .snap(.leftHalf, screen: screen + 1) : .none
        case (.rightHalf, .left): return .restore
        case (.rightHalf, .up): return .snap(.topRight, screen: screen)
        case (.rightHalf, .down): return .snap(.bottomRight, screen: screen)

        case (.topLeft, .left): return hasLeft ? .snap(.topRight, screen: screen - 1) : .none
        case (.topLeft, .right): return .snap(.topRight, screen: screen)
        case (.topLeft, .up): return .snap(.maximized, screen: screen)
        case (.topLeft, .down): return .snap(.leftHalf, screen: screen)

        case (.topRight, .right): return hasRight ? .snap(.topLeft, screen: screen + 1) : .none
        case (.topRight, .left): return .snap(.topLeft, screen: screen)
        case (.topRight, .up): return .snap(.maximized, screen: screen)
        case (.topRight, .down): return .snap(.rightHalf, screen: screen)

        case (.bottomLeft, .left): return hasLeft ? .snap(.bottomRight, screen: screen - 1) : .none
        case (.bottomLeft, .right): return .snap(.bottomRight, screen: screen)
        case (.bottomLeft, .up): return .snap(.leftHalf, screen: screen)
        case (.bottomLeft, .down): return .minimize

        case (.bottomRight, .right): return hasRight ? .snap(.bottomLeft, screen: screen + 1) : .none
        case (.bottomRight, .left): return .snap(.bottomLeft, screen: screen)
        case (.bottomRight, .up): return .snap(.rightHalf, screen: screen)
        case (.bottomRight, .down): return .minimize

        case (.maximized, .left): return .snap(.leftHalf, screen: screen)
        case (.maximized, .right): return .snap(.rightHalf, screen: screen)
        case (.maximized, .up): return .none
        case (.maximized, .down): return .restore
        }
    }

    /// 恢复时用的大小和位置：记得分屏前的样子就用它（不在这块屏幕上时挪进来），不记得就居中放一个三分之二大小的窗口。
    static func restoredFrame(remembered: CGRect?, in area: CGRect) -> CGRect {
        guard let remembered else {
            let size = CGSize(width: (area.width * 2 / 3).rounded(), height: (area.height * 2 / 3).rounded())
            return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height).integral
        }
        if area.intersects(remembered) && area.contains(CGPoint(x: remembered.midX, y: remembered.midY)) {
            return remembered
        }
        // 在另一块屏幕上记的：挪到这块屏幕中间，放不下就缩小
        let width = min(remembered.width, area.width)
        let height = min(remembered.height, area.height)
        return clamped(CGRect(x: (area.midX - width / 2).rounded(.down), y: (area.midY - height / 2).rounded(.down),
                              width: width, height: height), to: area)
    }

    /// Win+Shift+←/→：移到另一块屏幕，在屏幕里的相对位置不变，放不下就缩小。
    static func moved(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        let relativeX = source.width > frame.width ? (frame.minX - source.minX) / (source.width - frame.width) : 0
        let relativeY = source.height > frame.height ? (frame.minY - source.minY) / (source.height - frame.height) : 0
        let x = target.minX + (target.width - width) * min(max(relativeX, 0), 1)
        let y = target.minY + (target.height - height) * min(max(relativeY, 0), 1)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    /// 挪进区域里面；比区域大的那一边贴着区域的左边、上边。
    static func clamped(_ frame: CGRect, to area: CGRect) -> CGRect {
        var result = frame
        if result.maxX > area.maxX { result.origin.x = area.maxX - result.width }
        if result.minX < area.minX { result.origin.x = area.minX }
        if result.maxY > area.maxY { result.origin.y = area.maxY - result.height }
        if result.minY < area.minY { result.origin.y = area.minY }
        return result
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    /// 拖动窗口时，鼠标碰到屏幕哪条边、哪个角就分到哪里：左右边是半边，上边是最大化，四个角是四分之一。
    /// screen 是整块屏幕（含菜单栏），不是可用区域。
    /// sharedEdges 是鼠标这个位置和别的屏幕挨着的边：鼠标要贴在最边上才算（拖过去时会在那里停一下，见 EdgeResistance），
    /// 只是路过、离边还有几个点时不算。
    static func dragTarget(cursor: CGPoint, screen: CGRect, sharedEdges: Edges = [],
                           margin: CGFloat = 5, corner: CGFloat = 60) -> Position? {
        func reach(_ edge: Edges) -> CGFloat { sharedEdges.contains(edge) ? 0 : margin }
        let nearLeft = cursor.x <= screen.minX + reach(.left)
        let nearRight = cursor.x >= screen.maxX - 1 - reach(.right)
        let nearTop = cursor.y <= screen.minY + reach(.top)
        let nearBottom = cursor.y >= screen.maxY - 1 - reach(.bottom)
        let inTopCorner = cursor.y <= screen.minY + corner
        let inBottomCorner = cursor.y >= screen.maxY - corner
        let inLeftCorner = cursor.x <= screen.minX + corner
        let inRightCorner = cursor.x >= screen.maxX - corner

        if nearLeft { return inTopCorner ? .topLeft : inBottomCorner ? .bottomLeft : .leftHalf }
        if nearRight { return inTopCorner ? .topRight : inBottomCorner ? .bottomRight : .rightHalf }
        if nearTop { return inLeftCorner ? .topLeft : inRightCorner ? .topRight : .maximized }
        if nearBottom { return inLeftCorner ? .bottomLeft : inRightCorner ? .bottomRight : nil }
        return nil
    }

    /// 有好几块屏幕时：拖到这个位置会分到第几块屏幕的哪里。screens 是整块屏幕。
    static func dragTarget(cursor: CGPoint, screens: [CGRect]) -> (position: Position, screen: Int)? {
        // 先找正好在里面的屏幕：鼠标在两块屏幕交界处时别算到隔壁那块
        guard let index = screens.firstIndex(where: { $0.contains(cursor) })
                ?? screens.firstIndex(where: { $0.insetBy(dx: -1, dy: -1).contains(cursor) }) else { return nil }
        let screen = screens[index]
        let shared = sharedEdges(at: cursor, of: screen, among: screens)
        return dragTarget(cursor: cursor, screen: screen, sharedEdges: shared).map { ($0, index) }
    }

    /// 鼠标在这块屏幕的这个位置时，哪些边外面还有屏幕（鼠标能从那里过去）。
    /// 按鼠标的位置看，不按整条边：两块屏幕高矮不一样时，一条边可能只有一段挨着别的屏幕。
    static func sharedEdges(at cursor: CGPoint, of screen: CGRect, among screens: [CGRect]) -> Edges {
        let x = min(max(cursor.x, screen.minX), screen.maxX - 1)
        let y = min(max(cursor.y, screen.minY), screen.maxY - 1)
        func covered(_ point: CGPoint) -> Bool { screens.contains { $0 != screen && $0.contains(point) } }
        var edges: Edges = []
        if covered(CGPoint(x: screen.minX - 1, y: y)) { edges.insert(.left) }
        if covered(CGPoint(x: screen.maxX, y: y)) { edges.insert(.right) }
        if covered(CGPoint(x: x, y: screen.minY - 1)) { edges.insert(.top) }
        if covered(CGPoint(x: x, y: screen.maxY)) { edges.insert(.bottom) }
        return edges
    }

    /// 拖动一个分了屏的窗口时恢复原来的大小：鼠标在标题栏上的相对位置不变，窗口跟着鼠标走。
    static func unsnappedFrame(current: CGRect, restoreSize: CGSize, cursor: CGPoint) -> CGRect {
        let ratio = current.width > 0 ? (cursor.x - current.minX) / current.width : 0.5
        let x = cursor.x - restoreSize.width * min(max(ratio, 0), 1)
        let y = current.minY
        return CGRect(x: x, y: y, width: restoreSize.width, height: restoreSize.height).integral
    }
}
