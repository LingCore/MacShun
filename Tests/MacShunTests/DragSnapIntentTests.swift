// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import MacShun

@Suite("W2 自由跨屏与吸附意图")
struct DragSnapIntentTests {
    private let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           CGRect(x: 1920, y: 360, width: 1280, height: 720)]
    private let edge = CGPoint(x: 1916, y: 700)

    private func drag() -> DragSnapIntent {
        DragSnapIntent(screens: screens, cursor: CGPoint(x: 1800, y: 700), time: 0)
    }

    @Test func sharedEdgeNeedsDwellAndReleaseMatchesPreview() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        #expect(intent.target == nil)
        #expect(intent.deadline != nil)
        // 与计时器一样：手停住，没有新的拖动位移，停留到期仍能预览。
        intent.update(cursor: edge, time: 0.29)
        #expect(intent.target == .init(position: .rightHalf, screen: 0, isShared: true))
        #expect(intent.release(cursor: edge, time: 0.30) == intent.target)
    }

    @Test func passingAcrossTheBoundaryNeverArmsEitherScreen() {
        var intent = drag()
        for (x, time) in [(1900.0, 0.01), (1916, 0.02), (1923, 0.03), (1940, 0.04)] {
            intent.update(cursor: CGPoint(x: x, y: 700), time: time)
            #expect(intent.target == nil)
        }
        #expect(intent.release(cursor: CGPoint(x: 1940, y: 700), time: 0.05) == nil)
    }

    @Test func crossingAndReturningCancelsTheSourcePreview() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        intent.update(cursor: edge, time: 0.29)
        #expect(intent.target?.screen == 0)
        intent.update(cursor: CGPoint(x: 1923, y: 700), time: 0.30)
        #expect(intent.target == nil)
        intent.update(cursor: edge, time: 0.31)
        intent.update(cursor: edge, time: 0.50)
        #expect(intent.target == nil)
        intent.update(cursor: edge, time: 0.57)
        #expect(intent.target?.screen == 0)
    }

    @Test func destinationSharedEdgeCanBeChosenAfterPausing() {
        var intent = drag()
        let destination = CGPoint(x: 1924, y: 700)
        intent.update(cursor: destination, time: 0.1)
        intent.update(cursor: destination, time: 0.29)
        #expect(intent.target == nil) // 刚跨过来，不因瞬间停顿吸到目标屏左半边。
        intent.update(cursor: destination, time: 0.36)
        #expect(intent.target == .init(position: .leftHalf, screen: 1, isShared: true))
    }

    @Test func releaseRechecksTheLastPositionEvenWithoutAFinalDraggedEvent() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        intent.update(cursor: edge, time: 0.29)
        #expect(intent.release(cursor: CGPoint(x: 1921, y: 700), time: 0.30) == nil)
    }

    @Test func leavingTheZoneAtReleaseDoesNotSnapBack() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        intent.update(cursor: edge, time: 0.29)
        #expect(intent.release(cursor: CGPoint(x: 1880, y: 700), time: 0.5) == nil)
    }

    @Test func releaseCannotCreateAPreviewThatWasNeverShown() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        #expect(intent.release(cursor: edge, time: 0.5) == nil)
    }

    @Test func movingQuicklyAlongTheEdgeRestartsDwell() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        let lower = CGPoint(x: edge.x, y: 760)
        intent.update(cursor: lower, time: 0.25)
        intent.update(cursor: lower, time: 0.30)
        #expect(intent.target == nil)
        intent.update(cursor: lower, time: 0.44)
        #expect(intent.target?.position == .rightHalf)
    }

    @Test func changingFromAHalfToACornerNeedsFreshDwell() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        intent.update(cursor: edge, time: 0.29)
        let corner = CGPoint(x: edge.x, y: 1050)
        intent.update(cursor: corner, time: 0.3)
        #expect(intent.target == nil)
        intent.update(cursor: corner, time: 0.49)
        #expect(intent.target?.position == .bottomRight)
    }

    @Test func slightJitterRetainsPreviewButWithdrawalCancelsIt() {
        var intent = drag()
        intent.update(cursor: edge, time: 0.1)
        intent.update(cursor: edge, time: 0.29)
        intent.update(cursor: CGPoint(x: 1911, y: 700), time: 0.4)
        #expect(intent.target?.position == .rightHalf)
        intent.update(cursor: CGPoint(x: 1906, y: 700), time: 0.5)
        #expect(intent.target == nil)
        #expect(intent.deadline == nil)
    }

    @Test func exposedPartOfAnUnevenDisplayEdgeStillSnapsImmediately() {
        var intent = drag()
        intent.update(cursor: CGPoint(x: 1916, y: 100), time: 0.01)
        #expect(intent.target == .init(position: .rightHalf, screen: 0, isShared: false))
    }

    @Test func outerTopEdgeIsNotDelayedJustBecauseAnotherEdgeIsShared() {
        let aligned = [screens[0], CGRect(x: 1920, y: 0, width: 1280, height: 1080)]
        var intent = DragSnapIntent(screens: aligned, cursor: CGPoint(x: 1880, y: 100), time: 0)
        intent.update(cursor: CGPoint(x: 1880, y: 0), time: 0.01)
        #expect(intent.target == .init(position: .topRight, screen: 0, isShared: false))
    }

    @Test func verticalCrossingCancelsAPreviewAndKeepsBothDirectionsFree() {
        let vertical = [screens[0], CGRect(x: 0, y: 1080, width: 1920, height: 1080)]
        var intent = DragSnapIntent(screens: vertical, cursor: CGPoint(x: 960, y: 1075), time: 0)
        intent.update(cursor: CGPoint(x: 960, y: 1085), time: 0.01)
        #expect(intent.target == nil)
        intent.update(cursor: CGPoint(x: 960, y: 1075), time: 0.02)
        #expect(intent.target == nil)
        intent.update(cursor: CGPoint(x: 960, y: 1060), time: 0.03)
        #expect(intent.deadline == nil)
    }

    @Test func thirdDisplayAndNegativeCoordinatesUseTheCorrectScreen() {
        let three = [CGRect(x: -1280, y: -360, width: 1280, height: 1440)] + screens
        var intent = DragSnapIntent(screens: three, cursor: CGPoint(x: 100, y: 500), time: 0)
        let left = CGPoint(x: -4, y: 500)
        intent.update(cursor: left, time: 0.1)
        intent.update(cursor: left, time: 0.36)
        #expect(intent.target == .init(position: .rightHalf, screen: 0, isShared: true))
    }
}
