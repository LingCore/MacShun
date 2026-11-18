// SPDX-License-Identifier: MIT

import CoreGraphics
import Testing
@testable import MacShun

@Suite("窗口多屏定位")
struct WindowPlacementTests {
    @Test func recentersOnAnOffsetDisplayWithoutChangingSize() {
        let frame = CGRect(x: 400, y: 300, width: 720, height: 580)
        let area = CGRect(x: -1280, y: 320, width: 1280, height: 670)
        let result = WindowPlacement.fittedFrame(frame, in: area, centered: true)
        #expect(result.size == frame.size)
        #expect(result.midX == area.midX && result.midY == area.midY)
    }

    @Test func preservesReachablePositionsAndFitsWindowsInsideSmallerWorkAreas() {
        let area = CGRect(x: 0, y: -700, width: 800, height: 660)
        let inside = CGRect(x: 22, y: -650, width: 740, height: 540)
        #expect(WindowPlacement.fittedFrame(inside, in: area, centered: false) == inside)

        let hangingOff = CGRect(x: 100, y: -560, width: 740, height: 540)
        let clamped = WindowPlacement.fittedFrame(hangingOff, in: area, centered: false)
        #expect(clamped.size == hangingOff.size)
        #expect(clamped.maxX == area.maxX && clamped.maxY == area.maxY)

        let oversized = CGRect(x: -80, y: -770, width: 900, height: 730)
        #expect(WindowPlacement.fittedFrame(oversized, in: area, centered: false) == area)
    }
}
