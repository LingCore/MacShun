// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing
@testable import WinShun

/// 1920×1080 的屏幕，菜单栏 25，可用区域从 y=25 开始
private let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)

@Suite("W1 分屏位置")
struct WindowLayoutPositionTests {
    @Test func halvesAndQuartersTileWithoutGaps() {
        let odd = CGRect(x: 0, y: 25, width: 1921, height: 1055)
        let left = WindowLayout.Position.leftHalf.frame(in: odd)
        let right = WindowLayout.Position.rightHalf.frame(in: odd)
        #expect(left.maxX == right.minX)
        #expect(left.width + right.width == 1921)
        let top = WindowLayout.Position.topLeft.frame(in: odd)
        let bottom = WindowLayout.Position.bottomLeft.frame(in: odd)
        #expect(top.maxY == bottom.minY)
        #expect(top.minY == 25 && bottom.maxY == 1080)
    }

    @Test func recognizesPositionsWithTolerance() {
        #expect(WindowLayout.position(of: CGRect(x: 0, y: 25, width: 960, height: 1055), in: area) == .leftHalf)
        // 终端按字符调整大小，差几个点
        #expect(WindowLayout.position(of: CGRect(x: 0, y: 25, width: 953, height: 1048), in: area) == .leftHalf)
        #expect(WindowLayout.position(of: area, in: area) == .maximized)
        #expect(WindowLayout.position(of: CGRect(x: 200, y: 200, width: 800, height: 600), in: area) == nil)
    }
}

@Suite("W1 Win+方向键")
struct WindowKeyTests {
    private func command(_ key: WindowLayout.Key, _ current: WindowLayout.Position?, screen: Int = 0, count: Int = 1) -> WindowLayout.Command {
        WindowLayout.command(for: key, current: current, screen: screen, screenCount: count)
    }

    @Test func normalWindow() {
        #expect(command(.left, nil) == .snap(.leftHalf, screen: 0))
        #expect(command(.right, nil) == .snap(.rightHalf, screen: 0))
        #expect(command(.up, nil) == .snap(.maximized, screen: 0))
        #expect(command(.down, nil) == .minimize)
    }

    @Test func halvesGoToQuartersAndBack() {
        #expect(command(.up, .leftHalf) == .snap(.topLeft, screen: 0))
        #expect(command(.down, .leftHalf) == .snap(.bottomLeft, screen: 0))
        #expect(command(.down, .topLeft) == .snap(.leftHalf, screen: 0))
        #expect(command(.up, .bottomRight) == .snap(.rightHalf, screen: 0))
        #expect(command(.up, .topLeft) == .snap(.maximized, screen: 0))
        #expect(command(.down, .bottomLeft) == .minimize)
    }

    @Test func oppositeArrowRestores() {
        #expect(command(.right, .leftHalf) == .restore)
        #expect(command(.left, .rightHalf) == .restore)
        #expect(command(.down, .maximized) == .restore)
        #expect(command(.right, .maximized) == .snap(.rightHalf, screen: 0))
    }

    @Test func movesAcrossDisplays() {
        // 两块屏幕：左边那块的右半边再按 → 到右边那块的左半边
        #expect(command(.right, .rightHalf, screen: 0, count: 2) == .snap(.leftHalf, screen: 1))
        #expect(command(.left, .leftHalf, screen: 1, count: 2) == .snap(.rightHalf, screen: 0))
        #expect(command(.left, .leftHalf, screen: 0, count: 2) == .none)     // 最左边那块没有地方去
        #expect(command(.right, .topRight, screen: 0, count: 2) == .snap(.topLeft, screen: 1))
        #expect(command(.right, .topLeft) == .snap(.topRight, screen: 0))
    }

    @Test func shortcutsOnlyWithWinKey() {
        #expect(KeyMapper.windowShortcut(keyCode: KeyCode.leftArrow, mods: [.win]) == .snap(.left))
        #expect(KeyMapper.windowShortcut(keyCode: KeyCode.rightArrow, mods: [.win, .shift]) == .moveToDisplay(left: false))
        #expect(KeyMapper.windowShortcut(keyCode: KeyCode.upArrow, mods: [.win, .shift]) == .stretchVertically)
        #expect(KeyMapper.windowShortcut(keyCode: KeyCode.leftArrow, mods: [.alt]) == nil)
        #expect(KeyMapper.windowShortcut(keyCode: KeyCode.leftArrow, mods: [.win, .ctrl]) == nil)
    }

    @Test func mapperSendsWinArrowToSnapping() {
        var config = KeyboardConfig()
        config.layout = .windows
        let mapper = KeyMapper(config: config)
        var context = KeyContext(appKind: .normal, isBrowser: false, clipboardEnabled: true) { .text }
        // Windows 键盘上 Win 键是 ⌘
        #expect(mapper.action(keyCode: KeyCode.leftArrow, flags: .maskCommand, context: context) != .command(.window(.snap(.left))))
        context.windowShortcuts = true
        #expect(mapper.action(keyCode: KeyCode.leftArrow, flags: .maskCommand, context: context) == .command(.window(.snap(.left))))
        // ⌥+← 是按词移动，不能抢
        #expect(mapper.action(keyCode: KeyCode.leftArrow, flags: .maskAlternate, context: context) != .command(.window(.snap(.left))))
        // 远程桌面里留给远程的电脑
        context.appKind = .excluded
        #expect(mapper.action(keyCode: KeyCode.leftArrow, flags: .maskCommand, context: context) == .pass)
    }
}

@Suite("W1 恢复和换屏幕")
struct WindowRestoreTests {
    @Test func restoresRememberedFrame() {
        let remembered = CGRect(x: 300, y: 200, width: 900, height: 700)
        #expect(WindowLayout.restoredFrame(remembered: remembered, in: area) == remembered)
    }

    @Test func rememberedFrameOnAnotherScreenIsMovedIn() {
        let other = CGRect(x: 2500, y: 200, width: 900, height: 700)
        let restored = WindowLayout.restoredFrame(remembered: other, in: area)
        #expect(area.contains(restored))
        #expect(restored.size == other.size)
    }

    @Test func unknownFrameIsCenteredTwoThirds() {
        let restored = WindowLayout.restoredFrame(remembered: nil, in: area)
        #expect(restored.width == 1280)
        #expect(abs(restored.midX - area.midX) <= 1 && abs(restored.midY - area.midY) <= 1)
    }

    @Test func moveToOtherDisplayKeepsRelativePosition() {
        let small = CGRect(x: 1920, y: 0, width: 1280, height: 720)
        let frame = CGRect(x: 1920 - 800, y: 25, width: 800, height: 600)  // 贴着右上角
        let moved = WindowLayout.moved(frame, from: area, to: small)
        #expect(moved.maxX == small.maxX && moved.minY == small.minY)
        #expect(moved.size == frame.size)
        // 放不下就缩小
        let big = CGRect(x: 0, y: 25, width: 1800, height: 1000)
        #expect(small.contains(WindowLayout.moved(big, from: area, to: small)))
    }
}

@Suite("W2 拖到屏幕边缘")
struct WindowDragTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func edgesAndCorners() {
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 0, y: 500), screen: screen) == .leftHalf)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 1919, y: 500), screen: screen) == .rightHalf)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 900, y: 0), screen: screen) == .maximized)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 0, y: 10), screen: screen) == .topLeft)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 1919, y: 1079), screen: screen) == .bottomRight)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 900, y: 1079), screen: screen) == nil)   // 下边中间不分屏
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 900, y: 500), screen: screen) == nil)
    }

    @Test func edgeSharedWithAnotherScreenSnapsOnlyRightAtTheEdge() {
        let shared: WindowLayout.Edges = [.right]   // 右边挨着另一块屏幕
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 1919, y: 500), screen: screen, sharedEdges: shared) == .rightHalf)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 1916, y: 500), screen: screen, sharedEdges: shared) == nil)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 3, y: 500), screen: screen, sharedEdges: shared) == .leftHalf)
    }

    @Test func unsnapKeepsCursorOverTitleBar() {
        let snapped = CGRect(x: 0, y: 25, width: 960, height: 1055)
        let cursor = CGPoint(x: 480, y: 40)   // 标题栏正中
        let frame = WindowLayout.unsnappedFrame(current: snapped, restoreSize: CGSize(width: 800, height: 600), cursor: cursor)
        #expect(frame.size == CGSize(width: 800, height: 600))
        #expect(frame.midX == cursor.x)
        #expect(frame.minY == snapped.minY)
    }
}

/// 两块屏幕：左边 1920×1080，右边矮一些（1280×720），底边对齐。和用户的屏幕排列一样。
private let tall = CGRect(x: 0, y: 0, width: 1920, height: 1080)
private let short = CGRect(x: 1920, y: 360, width: 1280, height: 720)
private let pair = [tall, short]

@Suite("W2 两块屏幕之间")
struct TwoScreenDragTests {
    @Test func sharedEdgesFollowTheCursor() {
        // 左边屏幕的右边只有下面一段挨着右边屏幕
        #expect(WindowLayout.sharedEdges(at: CGPoint(x: 1919, y: 100), of: tall, among: pair) == [])
        #expect(WindowLayout.sharedEdges(at: CGPoint(x: 1919, y: 700), of: tall, among: pair) == [.right])
        #expect(WindowLayout.sharedEdges(at: CGPoint(x: 1920, y: 700), of: short, among: pair) == [.left])
        #expect(WindowLayout.sharedEdges(at: CGPoint(x: 2500, y: 360), of: short, among: pair) == [.left])   // 上边外面没有屏幕
    }

    @Test func targetsAroundTheBoundary() {
        func target(_ x: CGFloat, _ y: CGFloat) -> String? {
            WindowLayout.dragTarget(cursor: CGPoint(x: x, y: y), screens: pair).map { "\($0.position.rawValue)@\($0.screen)" }
        }
        #expect(target(1916, 100) == "rightHalf@0")   // 上面那段外面没有屏幕，和普通的边一样
        #expect(target(1916, 700) == nil)             // 挨着别的屏幕，离边还有几个点
        #expect(target(1919, 700) == "rightHalf@0")   // 停在边上
        #expect(target(1920, 700) == "leftHalf@1")    // 停在右边屏幕的左边上，不算到左边屏幕
        #expect(target(1920, 1079) == "bottomLeft@1")
        #expect(target(2500, 360) == "maximized@1")
    }

    @Test func cursorStopsAtTheBoundaryThenBreaksThrough() {
        var edge = EdgeResistance(screens: pair, cursor: CGPoint(x: 1900, y: 700))
        #expect(edge.filter(CGPoint(x: 1915, y: 700), delta: CGVector(dx: 15, dy: 0)) == CGPoint(x: 1915, y: 700))
        #expect(edge.filter(CGPoint(x: 1925, y: 700), delta: CGVector(dx: 10, dy: 0)) == CGPoint(x: 1919, y: 700))
        // 贴着边上下移动，光标沿着边走
        #expect(edge.filter(CGPoint(x: 1927, y: 760), delta: CGVector(dx: 8, dy: 60)) == CGPoint(x: 1919, y: 760))
        var position = CGPoint(x: 1919, y: 760)
        var steps = 0
        while position.x < 1920 && steps < 50 {
            position = edge.filter(CGPoint(x: position.x + 8, y: 760), delta: CGVector(dx: 8, dy: 0))
            steps += 1
        }
        #expect(position == CGPoint(x: 1927, y: 760))
        #expect(steps == Int(EdgeResistance.breakThrough / 8) - 1)
        // 过去以后往回拖，停在右边屏幕的左边上
        #expect(edge.filter(CGPoint(x: 1915, y: 760), delta: CGVector(dx: -12, dy: 0)) == CGPoint(x: 1920, y: 760))
    }

    @Test func movingAwayResetsThePush() {
        var edge = EdgeResistance(screens: pair, cursor: CGPoint(x: 1919, y: 700))
        for _ in 0 ..< 10 { _ = edge.filter(CGPoint(x: 1928, y: 700), delta: CGVector(dx: 9, dy: 0)) }
        #expect(edge.pushed == 90)
        _ = edge.filter(CGPoint(x: 1916, y: 700), delta: CGVector(dx: -3, dy: 0))   // 贴着边抖一下不算
        #expect(edge.pushed == 90)
        _ = edge.filter(CGPoint(x: 1880, y: 700), delta: CGVector(dx: -36, dy: 0))
        #expect(edge.pushed == 0)
    }

    @Test func fastFlickPassesStraightThrough() {
        var edge = EdgeResistance(screens: pair, cursor: CGPoint(x: 1850, y: 700))
        #expect(edge.filter(CGPoint(x: 2050, y: 700), delta: CGVector(dx: 200, dy: 0)) == CGPoint(x: 2050, y: 700))
    }

    @Test func eventsComputedBeforeTheStopCountOnlyTheirOwnMove() {
        var edge = EdgeResistance(screens: pair, cursor: CGPoint(x: 1919, y: 700))
        // 系统按挡住之前的位置算出来的一下：位置超出 60，这一下只移动了 5
        #expect(edge.filter(CGPoint(x: 1979, y: 700), delta: CGVector(dx: 5, dy: 0)) == CGPoint(x: 1919, y: 700))
        #expect(edge.pushed == 5)
    }

    @Test func noStopWhereThereIsNothingToSnap() {
        // 上下两块屏幕：下边中间拖过去不分屏，也不停
        let top = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let bottom = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        var edge = EdgeResistance(screens: [top, bottom], cursor: CGPoint(x: 960, y: 1075))
        #expect(edge.filter(CGPoint(x: 960, y: 1085), delta: CGVector(dx: 0, dy: 10)) == CGPoint(x: 960, y: 1085))
        // 往上拖到上面那块屏幕的下边……反过来是下面那块的上边：最大化，要停
        #expect(edge.filter(CGPoint(x: 960, y: 1075), delta: CGVector(dx: 0, dy: -10)) == CGPoint(x: 960, y: 1080))
    }
}
