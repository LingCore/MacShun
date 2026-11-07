// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import CoreText

enum CaptureMode: Equatable {
    case image, text

    var title: String {
        switch self {
        case .image: L("开始截图")
        case .text: L("识别屏幕文字")
        }
    }
}

/// 坐标始终是当前屏幕内的点（AppKit，左下为原点），只在裁切时换成图片像素。
struct CaptureImage {
    let image: CGImage
    let size: CGSize
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func pixelRect(_ selection: CGRect) -> CGRect {
        let area = selection.standardized.intersection(bounds)
        guard !area.isEmpty else { return .zero }
        let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
        // 转回屏幕点再换算时，非整数缩放可能把一个像素边界算成 41.00000000001。
        func edge(_ value: CGFloat) -> CGFloat {
            abs(value - value.rounded()) < 1e-7 ? value.rounded() : value
        }
        let left = floor(edge(area.minX * sx)), right = ceil(edge(area.maxX * sx))
        let top = floor(edge((size.height - area.maxY) * sy)), bottom = ceil(edge((size.height - area.minY) * sy))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    func pointRect(_ pixels: CGRect) -> CGRect {
        let sx = size.width / CGFloat(image.width), sy = size.height / CGFloat(image.height)
        return CGRect(x: pixels.minX * sx, y: (CGFloat(image.height) - pixels.maxY) * sy,
                      width: pixels.width * sx, height: pixels.height * sy)
    }

    /// 在整数像素网格上移动或改右/上边界，然后再转回屏幕点。
    func adjusted(_ selection: CGRect, dx: Int, dy: Int, resize: Bool) -> CGRect {
        var r = pixelRect(selection)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        if resize {
            let bottom = r.maxY
            r.size.width = min(w - r.minX, max(1, r.width + CGFloat(dx)))
            r.size.height = min(bottom, max(1, r.height + CGFloat(dy)))
            r.origin.y = bottom - r.height
        } else {
            r.origin.x = min(w - r.width, max(0, r.minX + CGFloat(dx)))
            r.origin.y = min(h - r.height, max(0, r.minY - CGFloat(dy)))
        }
        return pointRect(r)
    }

    func render(_ selection: CGRect, marks: [CaptureMark]) -> CGImage? {
        let pixels = pixelRect(selection)
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
        if marks.isEmpty { return crop }

        let colorSpace = crop.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: crop.width, height: crop.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        context.translateBy(x: -pixels.minX, y: pixels.maxY - CGFloat(image.height))
        context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        for mark in marks { mark.draw(in: context) }
        return context.makeImage()
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// WindowServer 返回从前到后的全局窗口矩形。裁到当前屏幕，转换为该屏内的点。
    static func localWindows(_ windows: [CGRect], in screen: CGRect) -> [CGRect] {
        windows.compactMap {
            let area = $0.intersection(screen)
            guard !area.isEmpty else { return nil }
            return CGRect(x: area.minX - screen.minX, y: screen.maxY - area.maxY,
                          width: area.width, height: area.height)
        }
    }
}

struct CaptureMark: Equatable {
    enum Kind: CaseIterable {
        case arrow, rectangle, cover, text, number

        var title: String {
            switch self {
            case .arrow: L("箭头")
            case .rectangle: L("矩形")
            case .cover: L("实心遮挡")
            case .text: L("文字标注")
            case .number: L("步骤序号")
            }
        }
        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .cover: "rectangle.fill"
            case .text: "text.cursor"
            case .number: "1.circle"
            }
        }
    }
    let kind: Kind
    var start: CGPoint
    var end: CGPoint
    var text = ""
    var number = 0

    static let fontSize: CGFloat = 18
    private static let typeface = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
    private static let white = CGColor(gray: 1, alpha: 1)
    private func lettering(_ value: String, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): Self.typeface,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
    }

    var bounds: CGRect {
        switch kind {
        case .number:
            let width = max(26, CGFloat(String(number).count * 11 + 8))
            return CGRect(x: start.x - width / 2, y: start.y - 13, width: width, height: 26)
        case .text:
            let maxWidth = max(1, end.x - start.x - 10)
            let setter = CTFramesetterCreateWithAttributedString(lettering(text, color: Self.white))
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
            let height = max(22, ceil(size.height) + 2) + 6
            return CGRect(x: start.x, y: start.y - height, width: min(maxWidth, ceil(size.width) + 1) + 10, height: height)
        default:
            return CaptureImage.rect(from: start, to: end)
        }
    }

    func hit(_ point: CGPoint) -> Bool {
        let box = bounds
        guard box.insetBy(dx: -5, dy: -5).contains(point) else { return false }
        switch kind {
        case .arrow:
            let dx = end.x - start.x, dy = end.y - start.y
            let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / max(1, dx * dx + dy * dy)))
            return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= 7
        case .rectangle: return !box.insetBy(dx: 5, dy: 5).contains(point)
        default: return true
        }
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return copy
    }

    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let rect = CaptureImage.rect(from: start, to: end)
        let ink = CGColor(srgbRed: 1, green: 0.22, blue: 0.14, alpha: 1)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(ink)
        switch kind {
        case .number:
            let box = bounds
            let badge = CGPath(roundedRect: box, cornerWidth: 13, cornerHeight: 13, transform: nil)
            context.addPath(badge)
            context.setFillColor(CGColor(srgbRed: 0.70, green: 0.13, blue: 0.08, alpha: 1))
            context.setStrokeColor(Self.white)
            context.setLineWidth(1.5)
            context.drawPath(using: .fillStroke)
            let line = CTLineCreateWithAttributedString(lettering(String(number), color: Self.white))
            let glyph = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: box.midX - glyph.midX, y: box.midY - glyph.midY)
            CTLineDraw(line, context)
        case .text:
            let box = bounds
            context.setFillColor(Self.white)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            let setter = CTFramesetterCreateWithAttributedString(lettering(text, color: CGColor(gray: 0.08, alpha: 1)))
            let path = CGPath(rect: box.insetBy(dx: 5, dy: 3), transform: nil)
            context.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
        case .cover:
            context.setShouldAntialias(false)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
        case .rectangle:
            context.stroke(rect)
        case .arrow:
            let dx = end.x - start.x, dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > 0 else { return }
            let head = min(14, length * 0.45)
            let base = CGPoint(x: end.x - dx / length * head, y: end.y - dy / length * head)
            context.move(to: start)
            context.addLine(to: base)
            context.strokePath()
            context.move(to: end)
            context.addLine(to: CGPoint(x: base.x - dy / length * head * 0.45, y: base.y + dx / length * head * 0.45))
            context.addLine(to: CGPoint(x: base.x + dy / length * head * 0.45, y: base.y - dx / length * head * 0.45))
            context.closePath()
            context.setFillColor(ink)
            context.fillPath()
        }
    }
}
