// SPDX-License-Identifier: MIT

import AppKit
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

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
struct CaptureImage: @unchecked Sendable {
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

        let fallbackSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let colorSpace = crop.colorSpace.flatMap { space -> CGColorSpace? in
            // 8 位 premultipliedLast 上下文不支持扩展动态范围（HDR/XDR）或不可输出的 RGB 色彩空间。
            guard space.model == .rgb, space.supportsOutput, !CGColorSpaceUsesExtendedRange(space) else { return nil }
            return space
        } ?? fallbackSpace
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: crop.width, height: crop.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: bitmapInfo)
            ?? CGContext(data: nil, width: crop.width, height: crop.height,
                         bitsPerComponent: 8, bytesPerRow: 0, space: fallbackSpace,
                         bitmapInfo: bitmapInfo) else { return nil }
        context.translateBy(x: -pixels.minX, y: pixels.maxY - CGFloat(image.height))
        context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        let cropArea = pointRect(pixels)
        context.draw(crop, in: cropArea)
        CaptureMark.drawSpotlights(marks, within: cropArea, in: context)
        for mark in marks where mark.kind != .spotlight { mark.draw(in: context, backdrop: self) }
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

    /// 使用 ImageIO 编码 PNG，避免 NSBitmapImageRep 额外开销且可安全在后台线程调用。
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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

        func stepped(_ delta: Int) -> Self {
            let all = Self.allCases
            guard let i = all.firstIndex(of: self) else { return self }
            return all[min(max(0, i + delta), all.count - 1)]
        }
    }

    var color: AnnotationColor = .red
    var width: Width = .medium
}

struct AnnotationMosaicStyle: Equatable {
    enum Mode: CaseIterable {
        case pixelate, blur

        var title: String {
            switch self {
            case .pixelate: L("像素马赛克")
            case .blur: L("高斯模糊")
            }
        }

        var symbol: String {
            switch self {
            case .pixelate: "checkerboard.rectangle"
            case .blur: "drop.halffull"
            }
        }
    }

    enum Level: Int, CaseIterable {
        case fine = 6, medium = 10, coarse = 16, heavy = 24

        var title: String { L("强度 %ld", rawValue) }

        func stepped(_ delta: Int) -> Self {
            let all = Self.allCases
            guard let i = all.firstIndex(of: self) else { return self }
            return all[min(max(0, i + delta), all.count - 1)]
        }
    }

    var mode: Mode = .pixelate
    var level: Level = .medium
}

struct AnnotationSpotlightStyle: Equatable {
    enum Shade: Int, CaseIterable {
        case light = 35, medium = 50, dark = 65, deep = 80

        var alpha: CGFloat { CGFloat(rawValue) / 100.0 }
        var title: String { L("遮罩 %ld%%", rawValue) }

        func stepped(_ delta: Int) -> Self {
            let all = Self.allCases
            guard let i = all.firstIndex(of: self) else { return self }
            return all[min(max(0, i + delta), all.count - 1)]
        }
    }

    var shade: Shade = .medium
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

        func stepped(_ delta: Int) -> Self {
            let all = Self.allCases
            guard let i = all.firstIndex(of: self) else { return self }
            return all[min(max(0, i + delta), all.count - 1)]
        }
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
    case mosaic(AnnotationMosaicStyle)
    case spotlight(AnnotationSpotlightStyle)

    var color: AnnotationColor? {
        switch self {
        case .stroke(let stroke): stroke.color
        case .lettering(let lettering, _): lettering.color
        case .fill(let color): color
        case .mosaic, .spotlight: nil
        }
    }

    var sizeTitle: String? {
        switch self {
        case .stroke(let stroke): stroke.width.title
        case .lettering(let lettering, _): lettering.size.title
        case .fill: nil
        case .mosaic(let mosaic): "\(mosaic.mode.title) · \(mosaic.level.title)"
        case .spotlight(let spotlight): spotlight.shade.title
        }
    }
}

struct CaptureMark: Equatable {
    enum Kind: CaseIterable {
        case arrow, line, rectangle, ellipse, pen, highlighter, polygon, mosaic, cover, spotlight, text, number

        var isLine: Bool { self == .line || self == .arrow }
        var isFreehand: Bool { self == .pen || self == .highlighter }
        var isBasicShape: Bool { self == .rectangle || self == .ellipse || self == .cover }
        var usesStroke: Bool { self != .cover && (isLine || isFreehand || isBasicShape || self == .polygon) }
        var usesLettering: Bool { self == .text || self == .number }
        var supportsSquareConstrain: Bool { self == .rectangle || self == .ellipse || self == .spotlight }

        var title: String {
            switch self {
            case .arrow: L("箭头")
            case .line: L("直线")
            case .rectangle: L("矩形")
            case .ellipse: L("椭圆")
            case .pen: L("画笔")
            case .highlighter: L("荧光笔")
            case .polygon: L("锚点标注")
            case .mosaic: L("马赛克")
            case .cover: L("实心遮挡")
            case .spotlight: L("聚光灯")
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
            case .pen: "scribble"
            case .highlighter: "highlighter"
            case .polygon: "point.3.filled.connected.trianglepath.dotted"
            case .mosaic: "checkerboard.rectangle"
            case .cover: "rectangle.fill"
            case .spotlight: "lightbulb.max"
            case .text: "text.cursor"
            case .number: "1.circle"
            }
        }
        var shortcutHint: String? {
            switch self {
            case .rectangle: "1"
            case .ellipse: "2"
            case .arrow: "3"
            case .line: "4"
            case .pen: "5"
            case .highlighter: "6"
            case .text: "7"
            case .number: "8"
            case .mosaic: "9"
            case .spotlight: "0"
            default: nil
            }
        }
    }
    let kind: Kind
    var start: CGPoint
    var end: CGPoint
    var text = ""
    var number = 0
    var polygon: CapturePolygon?
    var freehandPoints: [CGPoint] = []
    var stroke = AnnotationStroke()
    var letteringStyle: AnnotationLettering?
    var fillColor: AnnotationColor = .black
    var mosaicStyle = AnnotationMosaicStyle()
    var spotlightStyle = AnnotationSpotlightStyle()
    var customLineStyle: AnnotationLineStyle?
    var lineShape: CaptureLineShape?
    var hasFixedTextWidth = false
    var textFormat = AnnotationTextFormat()

    static let textInset = CGSize(width: 5, height: 3)
    private static let textSizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 128
        return cache
    }()
    private static let mosaicCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        return cache
    }()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var textLayoutWidth: CGFloat { max(1, end.x - start.x - 2 * Self.textInset.width) }

    var lineStyle: AnnotationLineStyle {
        customLineStyle ?? AnnotationLineStyle(ends: kind == .arrow ? .end : .none)
    }

    var lettering: AnnotationLettering { letteringStyle ?? AnnotationLettering(color: kind == .number ? .red : .black) }
    var annotationFont: NSFont {
        .systemFont(ofSize: lettering.size.points, weight: kind == .text && textFormat.bold ? .bold : .regular)
    }

    var effectiveStrokeWidth: CGFloat {
        kind == .highlighter ? stroke.width.points * 3.4 + 6 : stroke.width.points
    }

    var style: AnnotationStyle? {
        if kind.usesStroke { return .stroke(stroke) }
        if kind.usesLettering { return .lettering(lettering, text: kind == .text ? textFormat : nil) }
        if kind == .cover { return .fill(fillColor) }
        if kind == .mosaic { return .mosaic(mosaicStyle) }
        if kind == .spotlight { return .spotlight(spotlightStyle) }
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

    private var freehandPath: CGPath {
        let pts = freehandPoints.count >= 2 ? freehandPoints : [start, end]
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1 ..< pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        if let last = pts.last { path.addLine(to: last) }
        return path
    }

    var bounds: CGRect {
        switch kind {
        case .line, .arrow: return linePath(from: start, to: end).boundingBoxOfPath
        case .pen, .highlighter: return freehandPath.boundingBoxOfPath
        case .polygon: return polygon?.bounds ?? .null
        case .cover: return polygon?.bounds ?? CaptureImage.rect(from: start, to: end)
        case .mosaic, .spotlight: return CaptureImage.rect(from: start, to: end)
        case .number: return badgeBounds(for: CTLineGetBoundsWithOptions(numberLine, .useGlyphPathBounds))
        case .text:
            let maxWidth = textLayoutWidth
            let cacheKey = "\(lettering.size.rawValue)|\(textFormat.bold ? 1 : 0)|\(Int((maxWidth * 10).rounded()))|\(text)" as NSString
            let size: CGSize
            if let cached = Self.textSizeCache.object(forKey: cacheKey) {
                size = cached.sizeValue
            } else {
                // 结尾的空行也参与测量，编辑和导出时保留相同的段落高度。
                let content = text.last?.isNewline == true ? text + " " : text
                let setter = textFramesetter(content, alignment: .left)
                let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                    CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
                Self.textSizeCache.setObject(NSValue(size: measured), forKey: cacheKey)
                size = measured
            }
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
        let margin = effectiveStrokeWidth / 2 + 2
        let shaft = bounds.insetBy(dx: -margin, dy: -margin)
        guard kind.isLine else { return shaft }
        let heads = arrowHeads
        return [heads.start, heads.end].compactMap { $0 }.reduce(shaft) {
            $0.union($1.path.boundingBoxOfPath.insetBy(dx: -margin, dy: -margin))
        }
    }

    func hit(_ point: CGPoint) -> Bool {
        let box = bounds
        let tolerance = (kind == .cover || kind == .mosaic || kind == .spotlight) ? 5 : effectiveStrokeWidth / 2 + 4
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
        case .pen, .highlighter:
            guard box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            return freehandPath.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
                                     lineJoin: .round, miterLimit: 10).contains(point)
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
        case .mosaic, .spotlight:
            return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default: return box.insetBy(dx: -5, dy: -5).contains(point)
        }
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        if let polygon { return replacingPolygon(with: polygon.offsetBy(dx: dx, dy: dy)) }
        var copy = self
        copy.start = CGPoint(x: start.x + dx, y: start.y + dy)
        copy.end = CGPoint(x: end.x + dx, y: end.y + dy)
        copy.lineShape = lineShape?.translated(dx: dx, dy: dy)
        if !copy.freehandPoints.isEmpty {
            copy.freehandPoints = copy.freehandPoints.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        return copy
    }

    /// 渲染所有聚光灯的联合暗色遮罩层（位于普通标注之下，使多个高亮区域并存）。
    static func drawSpotlights(_ marks: [CaptureMark], within area: CGRect, in context: CGContext) {
        let spotlights = marks.filter { $0.kind == .spotlight }
        guard !spotlights.isEmpty else { return }
        let alpha = spotlights.last?.spotlightStyle.shade.alpha ?? AnnotationSpotlightStyle.Shade.medium.alpha
        context.saveGState()
        context.addRect(area.insetBy(dx: -1, dy: -1))
        for mark in spotlights {
            let rect = mark.bounds.intersection(area)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let radius = min(6, min(rect.width, rect.height) / 4)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.setFillColor(CGColor(gray: 0, alpha: alpha))
        context.drawPath(using: .eoFill)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
        context.setLineWidth(1)
        for mark in spotlights {
            let rect = mark.bounds.intersection(area)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let radius = min(6, min(rect.width, rect.height) / 4)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func mosaicTileImage(backdrop: CaptureImage, rect: CGRect) -> (image: CGImage, drawRect: CGRect)? {
        let pixels = backdrop.pixelRect(rect)
        guard !pixels.isEmpty, let crop = backdrop.image.cropping(to: pixels) else { return nil }
        let drawRect = backdrop.pointRect(pixels)
        let imgID = ObjectIdentifier(backdrop.image as AnyObject).hashValue
        let modeTag = mosaicStyle.mode == .pixelate ? "p" : "b"
        let key = "\(imgID)|\(Int(pixels.minX))|\(Int(pixels.minY))|\(Int(pixels.width))|\(Int(pixels.height))|\(modeTag)|\(mosaicStyle.level.rawValue)" as NSString
        if let cached = Self.mosaicCache.object(forKey: key) {
            return (cached, drawRect)
        }
        let scale = max(1, CGFloat(backdrop.image.width) / max(1, backdrop.size.width))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered: CGImage?
        switch mosaicStyle.mode {
        case .pixelate:
            let cellPx = max(2, Int((CGFloat(mosaicStyle.level.rawValue) * scale).rounded()))
            let cols = max(1, Int(ceil(CGFloat(crop.width) / CGFloat(cellPx))))
            let rows = max(1, Int(ceil(CGFloat(crop.height) / CGFloat(cellPx))))
            guard let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
            ctx.interpolationQuality = .low
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            rendered = ctx.makeImage()
        case .blur:
            let downscale = min(1.0, 240.0 / CGFloat(max(crop.width, crop.height)))
            let bw = max(2, Int((CGFloat(crop.width) * downscale).rounded()))
            let bh = max(2, Int((CGFloat(crop.height) * downscale).rounded()))
            guard let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
            ctx.interpolationQuality = .low
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: bw, height: bh))
            guard let small = ctx.makeImage() else { return nil }
            let ci = CIImage(cgImage: small)
            let sigma = Double(mosaicStyle.level.rawValue) * Double(scale) * Double(downscale) * 0.75
            let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: max(1.5, sigma)).cropped(to: ci.extent)
            rendered = Self.ciContext.createCGImage(blurred, from: ci.extent)
        }
        guard let result = rendered else { return nil }
        Self.mosaicCache.setObject(result, forKey: key)
        return (result, drawRect)
    }

    func draw(in context: CGContext, backdrop: CaptureImage? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        let rect = CaptureImage.rect(from: start, to: end)
        let ink = stroke.color.ink
        context.setLineWidth(effectiveStrokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(ink)
        switch kind {
        case .pen:
            context.addPath(freehandPath)
            context.strokePath()
        case .highlighter:
            context.setStrokeColor(ink.copy(alpha: 0.36) ?? ink)
            context.addPath(freehandPath)
            context.strokePath()
        case .mosaic:
            guard !rect.isEmpty else { return }
            context.clip(to: rect)
            if let backdrop, let tile = mosaicTileImage(backdrop: backdrop, rect: rect) {
                context.interpolationQuality = mosaicStyle.mode == .pixelate ? .none : .medium
                context.draw(tile.image, in: tile.drawRect)
            } else {
                context.setFillColor(CGColor(gray: 0.5, alpha: 0.9))
                context.fill(rect)
            }
        case .spotlight:
            // 由 CaptureMark.drawSpotlights 统一绘制联合暗色遮罩。
            break
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
