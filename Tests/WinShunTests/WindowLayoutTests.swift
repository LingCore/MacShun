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

    @Test func edgeSharedWithAnotherScreenDoesNotSnap() {
        let free: WindowLayout.Edges = [.left, .top, .bottom]   // 右边挨着另一块屏幕
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 1919, y: 500), screen: screen, freeEdges: free) == nil)
        #expect(WindowLayout.dragTarget(cursor: CGPoint(x: 0, y: 500), screen: screen, freeEdges: free) == .leftHalf)
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
