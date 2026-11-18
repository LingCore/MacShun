// SPDX-License-Identifier: MIT

import AppKit
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

/// 坐标始终是当前屏幕内的点（AppKit，左下为原点），裁切和取色时换成图片像素。
struct CaptureImage {
    let image: CGImage
    let size: CGSize
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func pixel(at point: CGPoint) -> CGPoint? {
        guard point.x >= 0, point.x < size.width, point.y >= 0, point.y <= size.height else { return nil }
        let x = floor(point.x * (CGFloat(image.width) / size.width))
        let y = floor((size.height - point.y) * (CGFloat(image.height) / size.height))
        return CGPoint(x: min(x, CGFloat(image.width - 1)), y: min(y, CGFloat(image.height - 1)))
    }

    /// 将光标放在目标像素的中心，Retina 下连续微调也不会落在像素边界上。
    func nudgedPointer(_ point: CGPoint, dx: Int, dy: Int) -> CGPoint {
        let clamped = CGPoint(x: min(max(point.x, 0), size.width.nextDown), y: min(max(point.y, 0), size.height))
        let pixel = pixel(at: clamped) ?? .zero
        let x = min(max(0, pixel.x + CGFloat(dx)), CGFloat(image.width - 1))
        let y = min(max(0, pixel.y - CGFloat(dy)), CGFloat(image.height - 1))
        let rect = pointRect(CGRect(x: x, y: y, width: 1, height: 1))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

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

struct AnnotationLineStyle: Equatable {
    enum Ends: CaseIterable {
        case none, start, end, both

        var title: String {
            switch self {
            case .none: L("无箭头")
            case .start: L("起点箭头")
            case .end: L("终点箭头")
            case .both: L("双向箭头")
            }
        }

        var symbol: String {
            switch self {
            case .none: "line.diagonal"
            case .start: "arrow.left"
            case .end: "arrow.right"
            case .both: "arrow.left.and.right"
            }
        }
    }

    enum Head: CaseIterable {
        case filled, outline, open

        var title: String {
            switch self {
            case .filled: L("实心箭头")
            case .outline: L("空心箭头")
            case .open: L("开口箭头")
            }
        }

        var symbol: String {
            switch self {
            case .filled: "arrowtriangle.right.fill"
            case .outline: "arrowtriangle.right"
            case .open: "chevron.right"
            }
        }
    }

    var ends: Ends = .none
    var head: Head = .filled
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

struct AnnotationTextFormat: Equatable {
    enum Alignment: CaseIterable {
        case left, center, right

        var title: String {
            switch self {
            case .left: L("左对齐")
            case .center: L("居中对齐")
            case .right: L("右对齐")
            }
        }

        var symbol: String {
            switch self {
            case .left: "text.alignleft"
            case .center: "text.aligncenter"
            case .right: "text.alignright"
            }
        }

        var appKitAlignment: NSTextAlignment {
            switch self {
            case .left: .left
            case .center: .center
            case .right: .right
            }
        }

        var paragraphStyle: CTParagraphStyle {
            var alignment: CTTextAlignment = switch self {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            return withUnsafePointer(to: &alignment) { pointer in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                      value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
        }
    }

    var alignment: Alignment = .left
    var bold = false
    var showsBackground = true
}

enum AnnotationStyle: Equatable {
    case stroke(AnnotationStroke)
    case lettering(AnnotationLettering, text: AnnotationTextFormat? = nil)
    case fill(AnnotationColor)

    var color: AnnotationColor {
        switch self {
        case .stroke(let stroke): stroke.color
        case .lettering(let lettering, _): lettering.color
        case .fill(let color): color
        }
    }

    var sizeTitle: String? {
        switch self {
        case .stroke(let stroke): stroke.width.title
        case .lettering(let lettering, _): lettering.size.title
        case .fill: nil
        }
    }
}

struct CaptureMark: Equatable {
    enum Kind: CaseIterable {
        case arrow, line, rectangle, ellipse, polygon, cover, text, number

        var isLine: Bool { self == .line || self == .arrow }
        var isBasicShape: Bool { self == .rectangle || self == .ellipse || self == .cover }
        var usesStroke: Bool { self != .cover && (isLine || isBasicShape || self == .polygon) }
        var usesLettering: Bool { self == .text || self == .number }

        var title: String {
            switch self {
            case .arrow: L("箭头")
            case .line: L("直线")
            case .rectangle: L("矩形")
            case .ellipse: L("椭圆")
            case .polygon: L("锚点标注")
            case .cover: L("实心遮挡")
            case .text: L("文字标注")
            case .number: L("步骤序号")
            }
        }
        var symbol: String {
            switch self {
            case .arrow: "arrow.up.right"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .ellipse: "oval"
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
    var customLineStyle: AnnotationLineStyle?
    var lineShape: CaptureLineShape?
    var hasFixedTextWidth = false
    var textFormat = AnnotationTextFormat()

    static let textInset = CGSize(width: 5, height: 3)
    private var textLayoutWidth: CGFloat { max(1, end.x - start.x - 2 * Self.textInset.width) }

    var lineStyle: AnnotationLineStyle {
        customLineStyle ?? AnnotationLineStyle(ends: kind == .arrow ? .end : .none)
    }

    var lettering: AnnotationLettering { letteringStyle ?? AnnotationLettering(color: kind == .number ? .red : .black) }
    var annotationFont: NSFont {
        .systemFont(ofSize: lettering.size.points, weight: kind == .text && textFormat.bold ? .bold : .regular)
    }

    var style: AnnotationStyle? {
        if kind.usesStroke { return .stroke(stroke) }
        if kind.usesLettering { return .lettering(lettering, text: kind == .text ? textFormat : nil) }
        if kind == .cover { return .fill(fillColor) }
        return nil
    }

    mutating func applyLettering(_ lettering: AnnotationLettering, text format: AnnotationTextFormat?) {
        if let format {
            if format.alignment != textFormat.alignment, !hasFixedTextWidth, !text.isEmpty {
                // 对现有文字框重新对齐时，沿用它当前可见的宽度。
                end.x = bounds.maxX
                hasFixedTextWidth = true
            }
            textFormat = format
        }
        letteringStyle = lettering
    }

    private func textFramesetter(_ value: String, alignment: AnnotationTextFormat.Alignment) -> CTFramesetter {
        CTFramesetterCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            .font: annotationFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): lettering.color.ink,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): alignment.paragraphStyle
        ]))
    }

    private var numberLine: CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): lettering.size.typeface,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): lettering.color.contrastingInk
        ]))
    }

    private func badgeBounds(for glyph: CGRect) -> CGRect {
        let height = ceil(lettering.size.points * 1.44)
        let width = max(height, ceil(glyph.width + lettering.size.points * 0.65))
        return CGRect(x: start.x - width / 2, y: start.y - height / 2, width: width, height: height)
    }

    var bounds: CGRect {
        switch kind {
        case .line, .arrow: return linePath(from: start, to: end).boundingBoxOfPath
        case .polygon: return polygon?.bounds ?? .null
        case .cover: return polygon?.bounds ?? CaptureImage.rect(from: start, to: end)
        case .number: return badgeBounds(for: CTLineGetBoundsWithOptions(numberLine, .useGlyphPathBounds))
        case .text:
            let maxWidth = textLayoutWidth
            // 结尾的空行也参与测量，编辑和导出时保留相同的段落高度。
            let content = text.last?.isNewline == true ? text + " " : text
            let setter = textFramesetter(content, alignment: .left)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
            let height = max(ceil(lettering.size.points * 1.22), ceil(size.height) + 2) + 2 * Self.textInset.height
            let usesFullWidth = hasFixedTextWidth || textFormat.alignment != .left
            let width = usesFullWidth ? maxWidth : min(maxWidth, ceil(size.width) + 1)
            return CGRect(x: start.x, y: start.y - height, width: width + 2 * Self.textInset.width, height: height)
        default:
            return CaptureImage.rect(from: start, to: end)
        }
    }

    private struct ArrowGeometry {
        let base: CGPoint
        let path: CGPath
        let length: CGFloat
    }

    private func arrowHead(tip: CGPoint, opposite: CGPoint) -> ArrowGeometry? {
        let dx = tip.x - opposite.x, dy = tip.y - opposite.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }
        let head = min(8 + 2 * stroke.width.points, length * 0.45)
        let base = CGPoint(x: tip.x - dx / length * head, y: tip.y - dy / length * head)
        let wing = head * 0.45
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: base.x - dy / length * wing, y: base.y + dx / length * wing),
                                tip, CGPoint(x: base.x + dy / length * wing, y: base.y - dx / length * wing)])
        if lineStyle.head != .open { path.closeSubpath() }
        return ArrowGeometry(base: base, path: path, length: head)
    }

    private var arrowHeads: (start: ArrowGeometry?, end: ArrowGeometry?) {
        guard lineShape?.isClosed != true else { return (nil, nil) }
        let ends = lineStyle.ends
        let firstTangent: CGPoint, lastTangent: CGPoint
        if let curves = curveSegments, let first = curves.first, let last = curves.last {
            let weight = curves.reduce(0) { $0 + $1.weight }
            firstTangent = first.tangentGuide(atStart: true, totalWeight: weight)
            lastTangent = last.tangentGuide(atStart: false, totalWeight: weight)
        } else {
            let nodes = lineNodes
            firstTangent = tangentGuide(in: nodes, from: 0, step: 1)
            lastTangent = tangentGuide(in: nodes, from: nodes.count - 1, step: -1)
        }
        return (ends == .start || ends == .both ? arrowHead(tip: start, opposite: firstTangent) : nil,
                ends == .end || ends == .both ? arrowHead(tip: end, opposite: lastTangent) : nil)
    }

    private func tangentGuide(in nodes: [CGPoint], from endpoint: Int, step: Int) -> CGPoint {
        let origin = nodes[endpoint]
        var guide = nodes[endpoint + step]
        let dx = guide.x - origin.x, dy = guide.y - origin.y
        let length = hypot(dx, dy)
        var index = endpoint + step * 2
        // 同一直线上的节点不改变箭头可用的线段长度。
        while nodes.indices.contains(index) {
            let node = nodes[index]
            let advance = (node.x - guide.x) * dx + (node.y - guide.y) * dy
            let cross = (node.x - origin.x) * dy - (node.y - origin.y) * dx
            guard advance > 0, abs(cross) <= length * 0.00001 else { break }
            guide = node
            index += step
        }
        return guide
    }

    var selectionBounds: CGRect {
        guard kind.usesStroke else { return bounds.insetBy(dx: -3, dy: -3) }
        let margin = stroke.width.points / 2 + 2
        let shaft = bounds.insetBy(dx: -margin, dy: -margin)
        guard kind.isLine else { return shaft }
        let heads = arrowHeads
        return [heads.start, heads.end].compactMap { $0 }.reduce(shaft) {
            $0.union($1.path.boundingBoxOfPath.insetBy(dx: -margin, dy: -margin))
        }
    }

    func hit(_ point: CGPoint) -> Bool {
        let box = bounds
        let tolerance = kind == .cover ? 5 : stroke.width.points / 2 + 4
        switch kind {
        case .arrow, .line:
            let heads = arrowHeads
            for head in [heads.start, heads.end].compactMap({ $0 }) {
                if lineStyle.head != .open, head.path.contains(point) { return true }
                if head.path.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
                                  lineJoin: .round, miterLimit: 10).contains(point) { return true }
            }
            return linePath(from: start, to: end).copy(strokingWithWidth: tolerance * 2,
                       lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        case .rectangle:
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !box.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .ellipse:
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && ellipsePath.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
                                    lineJoin: .round, miterLimit: 10).contains(point)
        case .polygon, .cover:
            guard box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            guard let polygon else { return kind == .cover }
            return polygon.contains(point) || polygon.path.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
                                                                lineJoin: .round, miterLimit: 10).contains(point)
        default: return box.insetBy(dx: -5, dy: -5).contains(point)
        }
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        if let polygon { return replacingPolygon(with: polygon.offsetBy(dx: dx, dy: dy)) }
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        copy.lineShape = lineShape?.translated(dx: dx, dy: dy)
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
            if textFormat.showsBackground {
                context.setFillColor(lettering.color.contrastingInk)
                context.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath()
            }
            let setter = textFramesetter(text, alignment: textFormat.alignment)
            var content = box.insetBy(dx: Self.textInset.width, dy: Self.textInset.height)
            content.size.width = textLayoutWidth
            let path = CGPath(rect: content, transform: nil)
            context.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), context)
        case .cover:
            context.setShouldAntialias(false)
            context.setFillColor(fillColor.ink)
            if let polygon {
                context.addPath(polygon.path)
                context.drawPath(using: .eoFill)
            } else {
                context.fill(rect)
            }
        case .rectangle:
            context.stroke(rect)
        case .ellipse:
            context.addPath(ellipsePath)
            context.strokePath()
        case .polygon:
            if let polygon {
                context.addPath(polygon.path)
                context.strokePath()
            }
        case .arrow, .line:
            guard start != end || lineShape != nil else { return }
            let heads = arrowHeads
            let headStyle = lineStyle.head
            let startPoint = headStyle == .open ? start : heads.start?.base ?? start
            let endPoint = headStyle == .open ? end : heads.end?.base ?? end
            let visibleHeads = [heads.start, heads.end].compactMap { $0 }
            if !visibleHeads.isEmpty, headStyle != .filled || visibleHeads.contains(where: { $0.length <= stroke.width.points / 2 }) {
                context.setLineCap(.butt)
            }
            if case .curve = lineShape {
                context.saveGState()
                if headStyle != .open, !visibleHeads.isEmpty {
                    // 沿完整曲线画线杆，在封闭箭头内挖去线杆，保持曲率及空心样式。
                    context.addRect(selectionBounds)
                    for head in visibleHeads { context.addPath(head.path) }
                    context.clip(using: .evenOdd)
                    context.setLineCap(.butt)
                }
                context.addPath(linePath(from: start, to: end))
                context.strokePath()
                context.restoreGState()
            } else {
                context.addPath(linePath(from: startPoint, to: endPoint))
                context.strokePath()
            }
            for head in visibleHeads { context.addPath(head.path) }
            context.setFillColor(ink)
            context.setLineCap(.round)
            context.drawPath(using: headStyle == .filled ? .fill : .stroke)
        }
    }
}

extension CaptureMark {
    init(polygon: CapturePolygon, stroke: AnnotationStroke = AnnotationStroke()) {
        let bounds = polygon.bounds
        self.init(kind: .polygon, start: bounds.origin, end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                  polygon: polygon, stroke: stroke)
    }

    func replacingPolygon(with shape: CapturePolygon) -> Self {
        let bounds = shape.bounds
        var updated = self
        updated.polygon = shape
        updated.start = bounds.origin
        updated.end = CGPoint(x: bounds.maxX, y: bounds.maxY)
        return updated
    }
}
