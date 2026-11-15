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

    func render(_ selection: CGRect, marks: [CaptureMark], polygon: CapturePolygon? = nil) -> CGImage? {
        let pixels = pixelRect(selection)
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
        if marks.isEmpty, polygon == nil { return crop }

        let colorSpace = crop.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: crop.width, height: crop.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: -pixels.minX, y: pixels.maxY - CGFloat(image.height))
        context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        let cropArea = pointRect(pixels)
        context.draw(crop, in: cropArea)
        for mark in marks { mark.draw(in: context) }
        if let polygon {
            // 对截图和所有标注一次性应用抗锯齿蒙版，避免重叠图层使斜边变厚。
            context.setBlendMode(.destinationOut)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addRect(cropArea.insetBy(dx: -1, dy: -1))
            context.addPath(polygon.path)
            context.drawPath(using: .eoFill)
        }
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

enum AnnotationColor: CaseIterable {
    case red, orange, green, blue, black, white

    var title: String {
        switch self {
        case .red: L("红色")
        case .orange: L("橙色")
        case .green: L("绿色")
        case .blue: L("蓝色")
        case .black: L("黑色")
        case .white: L("白色")
        }
    }

    private var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .red: (1, 0.22, 0.14)
        case .orange: (1, 0.56, 0)
        case .green: (0, 0.66, 0.32)
        case .blue: (0.05, 0.44, 0.96)
        case .black: (0, 0, 0)
        case .white: (1, 1, 1)
        }
    }

    var ink: CGColor {
        let (r, g, b) = rgb
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var contrastingInk: CGColor {
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = rgb
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return CGColor(gray: luminance > 0.179 ? 0 : 1, alpha: 1)
    }
}

struct AnnotationStroke: Equatable {
    enum Width: Int, CaseIterable {
        case thin = 1, medium = 3, thick = 5, heavy = 8

        var points: CGFloat { CGFloat(rawValue) }
        var title: String { L("线宽 %ld pt", rawValue) }
    }

    var color: AnnotationColor = .red
    var width: Width = .medium
}

struct AnnotationLettering: Equatable {
    enum Size: Int, CaseIterable {
        case small = 12, regular = 18, large = 24, extraLarge = 32, largest = 48

        var points: CGFloat { CGFloat(rawValue) }
        var title: String { L("字号 %ld pt", rawValue) }
        var typeface: CTFont { CTFontCreateUIFontForLanguage(.system, points, nil)! }
    }

    var color: AnnotationColor
    var size: Size = .regular
}

enum AnnotationStyle: Equatable {
    case stroke(AnnotationStroke)
    case lettering(AnnotationLettering)
    case fill(AnnotationColor)

    var color: AnnotationColor {
        switch self {
        case .stroke(let stroke): stroke.color
        case .lettering(let lettering): lettering.color
        case .fill(let color): color
        }
    }

    var sizeTitle: String? {
        switch self {
        case .stroke(let stroke): stroke.width.title
        case .lettering(let lettering): lettering.size.title
        case .fill: nil
        }
    }
}

struct CaptureMark: Equatable {
    enum Kind: CaseIterable {
        case arrow, rectangle, polygon, cover, text, number

        var usesStroke: Bool { self == .arrow || self == .rectangle || self == .polygon }
        var usesLettering: Bool { self == .text || self == .number }

        var title: String {
            switch self {
            case .arrow: L("箭头")
            case .rectangle: L("矩形")
            case .polygon: L("锚点标注")
            case .cover: L("实心遮挡")
            case .text: L("文字标注")
            case .number: L("步骤序号")
            }
        }
        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .polygon: "point.3.filled.connected.trianglepath.dotted"
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
    var polygon: CapturePolygon?
    var stroke = AnnotationStroke()
    var letteringStyle: AnnotationLettering?
    var fillColor: AnnotationColor = .black

    var lettering: AnnotationLettering { letteringStyle ?? AnnotationLettering(color: kind == .number ? .red : .black) }
    var style: AnnotationStyle? {
        if kind.usesStroke { return .stroke(stroke) }
        if kind.usesLettering { return .lettering(lettering) }
        if kind == .cover { return .fill(fillColor) }
        return nil
    }

    private func lettering(_ value: String, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): lettering.size.typeface,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
    }

    private var numberLine: CTLine {
        CTLineCreateWithAttributedString(lettering(String(number), color: lettering.color.contrastingInk))
    }

    private func badgeBounds(for glyph: CGRect) -> CGRect {
        let height = ceil(lettering.size.points * 1.44)
        let width = max(height, ceil(glyph.width + lettering.size.points * 0.65))
        return CGRect(x: start.x - width / 2, y: start.y - height / 2, width: width, height: height)
    }

    var bounds: CGRect {
        switch kind {
        case .polygon: return polygon?.bounds ?? .null
        case .number: return badgeBounds(for: CTLineGetBoundsWithOptions(numberLine, .useGlyphPathBounds))
        case .text:
            let maxWidth = max(1, end.x - start.x - 10)
            let setter = CTFramesetterCreateWithAttributedString(lettering(text, color: lettering.color.ink))
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
            let height = max(ceil(lettering.size.points * 1.22), ceil(size.height) + 2) + 6
            return CGRect(x: start.x, y: start.y - height, width: min(maxWidth, ceil(size.width) + 1) + 10, height: height)
        default:
            return CaptureImage.rect(from: start, to: end)
        }
    }

    private var arrowHead: (base: CGPoint, path: CGPath)? {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let head = min(8 + 2 * stroke.width.points, length * 0.45)
        let base = CGPoint(x: end.x - dx / length * head, y: end.y - dy / length * head)
        let wing = head * 0.45
        let path = CGMutablePath()
        path.addLines(between: [end,
            CGPoint(x: base.x - dy / length * wing, y: base.y + dx / length * wing),
            CGPoint(x: base.x + dy / length * wing, y: base.y - dx / length * wing)])
        path.closeSubpath()
        return (base, path)
    }

    var selectionBounds: CGRect {
        guard kind.usesStroke else { return bounds.insetBy(dx: -3, dy: -3) }
        let margin = stroke.width.points / 2 + 2
        let shaft = bounds.insetBy(dx: -margin, dy: -margin)
        if kind == .arrow, let head = arrowHead { return shaft.union(head.path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)) }
        return shaft
    }

    func hit(_ point: CGPoint) -> Bool {
        let box = bounds
        let tolerance = stroke.width.points / 2 + 4
        switch kind {
        case .arrow:
            if let head = arrowHead, head.path.contains(point) { return true }
            let dx = end.x - start.x, dy = end.y - start.y
            let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / max(1, dx * dx + dy * dy)))
            return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= tolerance
        case .rectangle:
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !box.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .polygon:
            guard let polygon, box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            return polygon.contains(point) || polygon.path.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
                                                                lineJoin: .round, miterLimit: 10).contains(point)
        default: return box.insetBy(dx: -5, dy: -5).contains(point)
        }
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        if let polygon { return Self(polygon: polygon.offsetBy(dx: dx, dy: dy), stroke: stroke) }
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        return copy
    }

    func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let rect = CaptureImage.rect(from: start, to: end)
        let ink = stroke.color.ink
        context.setLineWidth(stroke.width.points)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(ink)
        switch kind {
        case .number:
            let line = numberLine
            let glyph = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let box = badgeBounds(for: glyph)
            let radius = box.height / 2
            let badge = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(badge)
            context.setFillColor(lettering.color.ink)
            context.setStrokeColor(lettering.color.contrastingInk)
            context.setLineWidth(1.5)
            context.drawPath(using: .fillStroke)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: box.midX - glyph.midX, y: box.midY - glyph.midY)
            CTLineDraw(line, context)
        case .text:
            let box = bounds
            context.setFillColor(lettering.color.contrastingInk)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
            let setter = CTFramesetterCreateWithAttributedString(lettering(text, color: lettering.color.ink))
            let path = CGPath(rect: box.insetBy(dx: 5, dy: 3), transform: nil)
            context.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
        case .cover:
            context.setShouldAntialias(false)
            context.setFillColor(fillColor.ink)
            context.fill(rect)
        case .rectangle:
            context.stroke(rect)
        case .polygon:
            if let polygon {
                context.addPath(polygon.path)
                context.strokePath()
            }
        case .arrow:
            guard let head = arrowHead else { return }
            if hypot(end.x - head.base.x, end.y - head.base.y) <= stroke.width.points / 2 {
                context.setLineCap(.butt)
            }
            context.move(to: start)
            context.addLine(to: head.base)
            context.strokePath()
            context.addPath(head.path)
            context.setFillColor(ink)
            context.fillPath()
        }
    }
}

extension CaptureMark {
    init(polygon: CapturePolygon, stroke: AnnotationStroke = AnnotationStroke()) {
        let bounds = polygon.bounds
        self.init(kind: .polygon, start: bounds.origin, end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                  polygon: polygon, stroke: stroke)
    }
}
