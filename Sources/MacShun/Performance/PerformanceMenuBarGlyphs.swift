// SPDX-License-Identifier: MIT

import AppKit

/// 所有仪表共用 17 × 18 pt 网格。直边用填充轮廓，避免居中描边跨在两个像素之间。
enum PerformanceMenuBarGlyphs {
    static let width: CGFloat = 17

    static func draw(_ metric: PerformanceMetric, value: Double?, in context: CGContext) {
        switch metric {
        case .cpu:
            chip(in: context)
            processorGauge(in: chipBody, value: value, context: context)
        case .gpu:
            // 左侧挡板、板身和底部金手指组成显卡轮廓。
            context.fill(CGRect(x: 0, y: 1, width: 2, height: 16))
            context.fill(CGRect(x: 5, y: 14, width: 7, height: 3))
            let board = CGRect(x: 1, y: 2, width: 16, height: 13)
            frame(board, radius: 2, in: context)
            processorGauge(in: board, value: value, context: context)
        case .memory:
            // 触点的中间缺口在原尺寸仍可分辨。
            context.fill(CGRect(x: 2, y: 13, width: 6, height: 3))
            context.fill(CGRect(x: 10, y: 13, width: 5, height: 3))
            frame(CGRect(x: 0, y: 3, width: 17, height: 11), radius: 2, in: context)
            gauge(CGRect(x: 3, y: 6, width: 11, height: 5), value: value, vertical: false, in: context)
        case .temperature:
            thermometer(value, in: context)
        }
    }

    static func drawProcessors(cpu: Double?, gpu: Double?, in context: CGContext) {
        chip(in: context)
        gauge(CGRect(x: 5, y: 5, width: 3, height: 8), value: cpu, vertical: true, in: context)
        gauge(CGRect(x: 9, y: 5, width: 3, height: 8), value: gpu, vertical: true, in: context)
    }

    private static let chipBody = CGRect(x: 2, y: 2, width: 13, height: 14)
    private static let gaugeInset: CGFloat = 3

    private static func chip(in context: CGContext) {
        for x in [5, 10] {
            context.fill(CGRect(x: x, y: 0, width: 2, height: 3))
            context.fill(CGRect(x: x, y: 15, width: 2, height: 3))
        }
        for y in [6, 10] {
            context.fill(CGRect(x: 0, y: y, width: 3, height: 2))
            context.fill(CGRect(x: 14, y: y, width: 3, height: 2))
        }
        frame(chipBody, radius: 3, in: context)
    }

    private static func processorGauge(in body: CGRect, value: Double?, context: CGContext) {
        gauge(body.insetBy(dx: gaugeInset, dy: gaugeInset), value: value, vertical: true, in: context)
    }

    private static func scale(in context: CGContext) -> CGFloat {
        max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 0)).width))
    }

    private static func wall(in context: CGContext) -> CGFloat {
        let pixels = scale(in: context)
        return floor(1.5 * pixels) / pixels
    }

    private static func frame(_ rect: CGRect, radius: CGFloat, in context: CGContext) {
        let inset = wall(in: context)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset,
                               cornerHeight: radius - inset, transform: nil))
        context.fillPath(using: .evenOdd)
    }

    private static func thermometer(_ value: Double?, in context: CGContext) {
        context.addPath(thermometerPath(inset: 0))
        context.addPath(thermometerPath(inset: wall(in: context)))
        context.fillPath(using: .evenOdd)

        // 管壁、液柱和球泡由同一轮廓内缩而成，液面始终裁在轨道内。
        context.saveGState()
        context.addPath(thermometerPath(inset: gaugeInset))
        context.clip()
        let track = CGRect(x: 3, y: 1 + gaugeInset, width: 11, height: 17 - 2 * gaugeInset)
        context.setAlpha(0.26)
        context.fill(track)
        context.setAlpha(1)
        if let value, value.isFinite {
            let pixels = scale(in: context)
            let bulbTop: CGFloat = 10
            let fraction = CGFloat(min(100, max(0, value))) / 100
            let level = bulbTop - ((bulbTop - track.minY) * fraction * pixels).rounded() / pixels
            context.fill(CGRect(x: track.minX, y: level, width: track.width, height: track.maxY - level))
        } else {
            context.fill(CGRect(x: 7, y: 8, width: 3, height: 1))
        }
        context.restoreGState()
    }

    private static func thermometerPath(inset: CGFloat) -> CGPath {
        let left = 4 + inset, right = 13 - inset, top = 1 + inset
        let shoulder = 9 + inset / 3
        let bulbLeft = 3 + inset, bulbRight = 14 - inset, bottom = 18 - inset
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: shoulder))
        path.addLine(to: CGPoint(x: left, y: 5.5))
        path.addQuadCurve(to: CGPoint(x: 8.5, y: top), control: CGPoint(x: left, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: 5.5), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: bulbRight, y: 12.5), control: CGPoint(x: bulbRight, y: shoulder + 1))
        path.addQuadCurve(to: CGPoint(x: 8.5, y: bottom), control: CGPoint(x: bulbRight, y: bottom))
        path.addQuadCurve(to: CGPoint(x: bulbLeft, y: 12.5), control: CGPoint(x: bulbLeft, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: shoulder), control: CGPoint(x: bulbLeft, y: shoulder + 1))
        path.closeSubpath()
        return path
    }

    private static func gauge(_ track: CGRect, value: Double?, vertical: Bool, in context: CGContext) {
        context.setAlpha(0.26)
        context.fill(track)
        context.setAlpha(1)
        guard let value, value.isFinite else {
            context.fill(CGRect(x: floor(track.midX - 1), y: floor(track.midY), width: 2, height: 1))
            return
        }
        guard value > 0 else { return }
        let pixels = scale(in: context)
        let dimension = vertical ? track.height : track.width
        let length = max(1, (dimension * CGFloat(min(100, value) / 100) * pixels).rounded()) / pixels
        var fill = track
        if vertical {
            fill.origin.y = track.maxY - length
            fill.size.height = length
        } else {
            fill.size.width = length
        }
        context.fill(fill)
    }
}
