// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MacShun

@Suite("M2、M3 滚轮")
struct ScrollTransformTests {
    private func settings(direction: Bool = true, linear: Bool = true, lines: Int = 3) -> MouseDeviceSettings {
        var s = MouseDeviceSettings()
        s.windowsScrollDirection = direction
        s.linearScroll = linear
        s.scrollLines = lines
        return s
    }

    private let down = ScrollAxis(lines: -2, fixed: -1.7, points: -17)

    @Test func reversesNaturalScrolling() {
        let r = ScrollTransform.apply(vertical: down, horizontal: .zero, invertedFromDevice: true,
                                      settings: settings(linear: false))
        #expect(r.vertical == ScrollAxis(lines: 2, fixed: 1.7, points: 17))
        #expect(r.horizontal == .zero)
    }

    @Test func keepsDirectionWhenNotInverted() {
        let r = ScrollTransform.apply(vertical: down, horizontal: .zero, invertedFromDevice: false,
                                      settings: settings(linear: false))
        #expect(r.vertical == down)
    }

    @Test func keepsNaturalWhenOptionOff() {
        let r = ScrollTransform.apply(vertical: down, horizontal: .zero, invertedFromDevice: true,
                                      settings: settings(direction: false, linear: false))
        #expect(r.vertical == down)
    }

    @Test func linearScrollUsesFixedLines() {
        let fast = ScrollAxis(lines: 9, fixed: 8.6, points: 86)
        let slow = ScrollAxis(lines: 1, fixed: 0.1, points: 1)
        let s = settings(direction: false, lines: 3)
        let expected = ScrollAxis(lines: 3, fixed: 3, points: 3 * ScrollTransform.pointsPerLine)
        #expect(ScrollTransform.apply(vertical: fast, horizontal: .zero, invertedFromDevice: false, settings: s).vertical == expected)
        #expect(ScrollTransform.apply(vertical: slow, horizontal: .zero, invertedFromDevice: false, settings: s).vertical == expected)
    }

    @Test func directionAndLinearTogether() {
        let r = ScrollTransform.apply(vertical: down, horizontal: .zero, invertedFromDevice: true,
                                      settings: settings(lines: 5))
        #expect(r.vertical == ScrollAxis(lines: 5, fixed: 5, points: 5 * ScrollTransform.pointsPerLine))
    }

    @Test func horizontalAxis() {
        let left = ScrollAxis(lines: -1, fixed: -1, points: -10)
        let r = ScrollTransform.apply(vertical: .zero, horizontal: left, invertedFromDevice: true,
                                      settings: settings(lines: 3))
        #expect(r.horizontal == ScrollAxis(lines: 3, fixed: 3, points: 30))
        #expect(r.vertical == .zero)
    }

    @Test func physicalDirectionForZoom() {
        let positive = ScrollAxis(lines: 1, fixed: 1, points: 10)
        #expect(ScrollTransform.isPhysicallyUp(positive, invertedFromDevice: false) == true)
        #expect(ScrollTransform.isPhysicallyUp(positive, invertedFromDevice: true) == false)
        #expect(ScrollTransform.isPhysicallyUp(.zero, invertedFromDevice: false) == nil)
    }
}
