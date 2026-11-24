// SPDX-License-Identifier: MIT

import AppKit

enum PerformanceMenuBarImage {
    /// 用于跳过像素完全一致的菜单栏重绘；不含采样时间戳和刷新间隔，按当前样式的实际绘制粒度去重。
    struct VisualKey: Equatable {
        let visual: PerformanceConfig.VisualSignature
        let needsAttention: Bool
        let scale: Int
        let texts: [String]
        let iconLevels: [Int]
        let trendPoints: [[Int?]]
    }

    private struct Column {
        enum Content {
            case icon(PerformanceMetric)
            case trend([PerformanceMetric])
            case processors
        }

        let width: CGFloat
        let content: Content
    }

    private static let readoutLabelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    private static let readoutNumberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    private static let centeredParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return paragraph
    }()
    private static let textLabelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.black,
        .paragraphStyle: centeredParagraph,
    ]
    private static let textValueAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.black,
        .paragraphStyle: centeredParagraph,
    ]

    static func backingScale() -> CGFloat {
        max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    }

    static func width(for configuration: PerformanceConfig) -> CGFloat {
        let metrics = configuration.metrics
        guard !metrics.isEmpty else { return 18 }
        let style = configuration.menuBarStyle
        if style == .text {
            let columnWidth: CGFloat = 40, gap: CGFloat = 6, leading: CGFloat = 28
            return leading + CGFloat(metrics.count) * columnWidth + CGFloat(max(0, metrics.count - 1)) * gap
        }
        let combined = configuration.canCombineProcessors && configuration.combineProcessors
        let columns = chartColumns(for: metrics, style: style, combined: combined)
        let gap: CGFloat = 6
        let leading: CGFloat = style == .icons ? 23 : 22
        return columns.reduce(leading) { $0 + $1.width } + CGFloat(columns.count - 1) * gap
    }

    static func visualKey(
        snapshot: PerformanceSnapshot,
        history: PerformanceHistory = PerformanceHistory(),
        configuration: PerformanceConfig,
        needsAttention: Bool,
        scale: CGFloat = backingScale()
    ) -> VisualKey {
        let metrics = configuration.metrics
        let visual = configuration.visualSignature
        let quantizedScale = max(1, Int(scale.rounded()))
        guard !metrics.isEmpty else {
            return VisualKey(
                visual: visual, needsAttention: needsAttention,
                scale: quantizedScale, texts: [], iconLevels: [], trendPoints: []
            )
        }
        switch configuration.menuBarStyle {
        case .text:
            return VisualKey(
                visual: visual, needsAttention: needsAttention,
                scale: quantizedScale,
                texts: metrics.map { snapshot.text($0, compact: true) },
                iconLevels: [], trendPoints: []
            )
        case .icons:
            let combined = configuration.canCombineProcessors && configuration.combineProcessors
            let levels = metrics.map { metric in
                iconPixelLevel(for: metric, value: snapshot.value(metric), combined: combined, scale: CGFloat(quantizedScale))
            }
            return VisualKey(
                visual: visual, needsAttention: needsAttention,
                scale: quantizedScale, texts: [], iconLevels: levels, trendPoints: []
            )
        case .trend:
            let combined = configuration.canCombineProcessors && configuration.combineProcessors
            let texts = metrics.map { snapshot.text($0, compact: true) }
            let points = metrics.map { metric -> [Int?] in
                let samples = series(for: metric, snapshot: snapshot, history: history)
                let isCombinedProcessor = combined && (metric == .cpu || metric == .gpu)
                let scaleRange = isCombinedProcessor ? 0...100 : trendScale(samples)
                let height: CGFloat = isCombinedProcessor ? 19 : 8
                return samples.map { value in
                    guard let value, value.isFinite else { return nil }
                    let bounded = min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
                    let fraction = CGFloat((bounded - scaleRange.lowerBound) / (scaleRange.upperBound - scaleRange.lowerBound))
                    let y = (height - 2) * fraction
                    return Int((y * CGFloat(quantizedScale)).rounded())
                }
            }
            return VisualKey(
                visual: visual, needsAttention: needsAttention,
                scale: quantizedScale, texts: texts, iconLevels: [], trendPoints: points
            )
        }
    }

    private static func iconPixelLevel(for metric: PerformanceMetric, value: Double?, combined: Bool, scale: CGFloat) -> Int {
        guard let value, value.isFinite else { return -1 }
        switch metric {
        case .temperature:
            let fraction = CGFloat(min(100, max(0, value))) / 100
            return Int((6 * fraction * scale).rounded())
        case .cpu, .gpu, .memory:
            guard value > 0 else { return 0 }
            let dimension: CGFloat
            switch metric {
            case .cpu: dimension = 8
            case .gpu: dimension = combined ? 8 : 7
            case .memory: dimension = 11
            case .temperature: dimension = 6
            }
            return max(1, Int((dimension * CGFloat(min(100, value) / 100) * scale).rounded()))
        }
    }

    static func make(snapshot: PerformanceSnapshot, history: PerformanceHistory = PerformanceHistory(),
                     configuration: PerformanceConfig, needsAttention: Bool) -> NSImage {
        let metrics = configuration.metrics
        let brand = BrandMark.menuBarImage(needsAttention: needsAttention)
        let brandCG = BrandMark.menuBarCGImage(needsAttention: needsAttention)
        guard !metrics.isEmpty else { return brand }
        let style = configuration.menuBarStyle
        if style == .text { return makeText(snapshot: snapshot, metrics: metrics, brand: brand, brandCG: brandCG) }

        let combined = configuration.canCombineProcessors && configuration.combineProcessors
        let columns = chartColumns(for: metrics, style: style, combined: combined)
        let gap: CGFloat = 6
        let leading: CGFloat = style == .icons ? 23 : 22
        let width = columns.reduce(leading) { $0 + $1.width } + CGFloat(columns.count - 1) * gap
        return rasterize(size: NSSize(width: width, height: 22), flipped: true) { context in
            if let brandCG {
                context.saveGState()
                context.translateBy(x: 0, y: 20)
                context.scaleBy(x: 1, y: -1)
                context.draw(brandCG, in: CGRect(x: 0, y: 0, width: 18, height: 18))
                context.restoreGState()
            } else {
                brand.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setFillColor(gray: 0, alpha: 1)

            var x = leading
            for column in columns {
                context.saveGState()
                context.translateBy(x: x, y: 0)
                draw(column, style: style, snapshot: snapshot, history: history, in: context)
                context.restoreGState()
                x += column.width + gap
            }
        }
    }

    /// 预渲染成不可变 CGImage 模板图，避免 AppKit 与多屏状态栏副本每次重绘都重复跑闭包和文字排版。
    private static func rasterize(size: NSSize, flipped: Bool, draw: @escaping (CGContext) -> Void) -> NSImage {
        let scale = backingScale()
        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        if let cg = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            if flipped {
                cg.translateBy(x: 0, y: CGFloat(pixelHeight))
                cg.scaleBy(x: scale, y: -scale)
            } else {
                cg.scaleBy(x: scale, y: scale)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: flipped)
            draw(cg)
            NSGraphicsContext.restoreGraphicsState()
            if let cgImage = cg.makeImage() {
                let image = NSImage(cgImage: cgImage, size: size)
                image.isTemplate = true
                return image
            }
        }
        let fallback = NSImage(size: size, flipped: flipped) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(context)
            return true
        }
        fallback.isTemplate = true
        return fallback
    }

    private static func chartColumns(for metrics: [PerformanceMetric], style: PerformanceMenuBarStyle,
                                     combined: Bool) -> [Column] {
        let remaining = combined ? metrics.filter { $0 != .cpu && $0 != .gpu } : metrics
        var columns: [Column] = []
        if combined {
            columns.append(Column(width: style == .icons ? PerformanceMenuBarGlyphs.width : 58, content: .processors))
        }
        if style == .icons {
            columns += remaining.map { Column(width: PerformanceMenuBarGlyphs.width, content: .icon($0)) }
        } else {
            let count = (remaining.count + 1) / 2
            for index in 0..<count {
                let rows = stride(from: index, to: remaining.count, by: count).map { remaining[$0] }
                columns.append(Column(width: rows.contains(.temperature) ? 77 : 70, content: .trend(rows)))
            }
        }
        return columns
    }

    private static func draw(_ column: Column, style: PerformanceMenuBarStyle, snapshot: PerformanceSnapshot,
                             history: PerformanceHistory, in context: CGContext) {
        switch column.content {
        case .icon(let metric):
            context.translateBy(x: 0, y: 2)
            PerformanceMenuBarGlyphs.draw(metric, value: snapshot.value(metric), in: context)
        case .processors where style == .icons:
            context.translateBy(x: 0, y: 2)
            PerformanceMenuBarGlyphs.drawProcessors(cpu: snapshot.cpu, gpu: snapshot.gpu, in: context)
        case .processors:
            drawProcessorTrend(width: column.width, snapshot: snapshot, history: history, in: context)
        case .trend(let metrics):
            for (index, metric) in metrics.enumerated() {
                let y: CGFloat = metrics.count == 2 ? CGFloat(index) * 11 + 0.5 : 6
                drawReadout(metric.barLabel, value: snapshot.text(metric, compact: true),
                            trailing: column.width - 17, y: y)
                let rect = CGRect(x: column.width - 15, y: y + 1, width: 15, height: 8)
                let samples = series(for: metric, snapshot: snapshot, history: history)
                drawBaseline(rect, in: context)
                drawLine(samples, scale: trendScale(samples), rect: rect, in: context)
            }
        }
    }

    private static func drawProcessorTrend(width: CGFloat, snapshot: PerformanceSnapshot,
                                           history: PerformanceHistory, in context: CGContext) {
        drawReadout("C", value: snapshot.text(.cpu, compact: true), trailing: width - 17, y: 0.5)
        drawReadout("G", value: snapshot.text(.gpu, compact: true), trailing: width - 17, y: 11.5)
        let rect = CGRect(x: width - 15, y: 1.5, width: 15, height: 19)
        drawBaseline(rect, in: context)
        drawLine(series(for: .gpu, snapshot: snapshot, history: history), scale: 0...100,
                 rect: rect, dashed: true, in: context)
        drawLine(series(for: .cpu, snapshot: snapshot, history: history), scale: 0...100, rect: rect, in: context)
    }

    private static func drawReadout(_ name: String, value: String, trailing: CGFloat, y: CGFloat) {
        let label = NSAttributedString(string: name, attributes: readoutLabelAttributes)
        let number = NSAttributedString(string: value, attributes: readoutNumberAttributes)
        let baseline = y + 8.5
        label.draw(at: NSPoint(x: 0, y: baseline - 8))
        number.draw(at: NSPoint(x: (trailing - number.size().width).rounded(), y: baseline - 10))
    }

    private static func series(for metric: PerformanceMetric, snapshot: PerformanceSnapshot,
                               history: PerformanceHistory) -> [Double?] {
        let values = history.values(for: metric)
        return values.isEmpty ? [snapshot.value(metric)] : values
    }

    private static func trendScale(_ samples: [Double?]) -> ClosedRange<Double> {
        let available = samples.compactMap { $0 }.filter(\.isFinite)
        guard let low = available.min(), let high = available.max() else { return 0...100 }
        let span = max(30, high - low)
        let floor = max(0, min(max(100, high) - span, (low + high - span) / 2))
        return floor...(floor + span)
    }

    private static func drawBaseline(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setAlpha(0.22)
        context.fill(CGRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5))
        context.restoreGState()
    }

    private static func drawLine(_ samples: [Double?], scale: ClosedRange<Double>, rect: CGRect,
                                 dashed: Bool = false, in context: CGContext) {
        let padding = PerformanceHistory.capacity - samples.count
        let spacing = (rect.width - 2) / CGFloat(PerformanceHistory.capacity - 1)
        let points: [CGPoint?] = samples.enumerated().map { index, value in
            guard let value, value.isFinite else { return nil }
            let bounded = min(scale.upperBound, max(scale.lowerBound, value))
            let fraction = CGFloat((bounded - scale.lowerBound) / (scale.upperBound - scale.lowerBound))
            return CGPoint(x: rect.minX + 1 + CGFloat(padding + index) * spacing,
                           y: rect.maxY - 1 - (rect.height - 2) * fraction)
        }

        context.saveGState()
        context.setAlpha(dashed ? 0.75 : 1)
        context.setLineWidth(1)
        context.setLineJoin(.round)
        context.setLineCap(dashed ? .butt : .round)
        if dashed { context.setLineDash(phase: 0, lengths: [1.5, 1]) }
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            guard let point else { continue }
            let hasPrevious = index > 0 && points[index - 1] != nil
            let hasNext = index + 1 < points.count && points[index + 1] != nil
            if hasPrevious { path.addLine(to: point) } else { path.move(to: point) }
            if !hasPrevious && !hasNext || index == points.count - 1 {
                context.fillEllipse(in: CGRect(x: point.x - 0.65, y: point.y - 0.65, width: 1.3, height: 1.3))
            }
        }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// 保留原文字样式的尺寸和排版。
    private static func makeText(snapshot: PerformanceSnapshot, metrics: [PerformanceMetric], brand: NSImage, brandCG: CGImage?) -> NSImage {
        let columnWidth: CGFloat = 40, gap: CGFloat = 6, leading: CGFloat = 28
        let width = leading + CGFloat(metrics.count) * columnWidth + CGFloat(max(0, metrics.count - 1)) * gap
        return rasterize(size: NSSize(width: width, height: 22), flipped: false) { context in
            if let brandCG {
                context.draw(brandCG, in: CGRect(x: 0, y: 2, width: 18, height: 18))
            } else {
                brand.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18))
            }
            for (index, metric) in metrics.enumerated() {
                let x = leading + CGFloat(index) * (columnWidth + gap)
                let label = NSAttributedString(string: metric.barLabel, attributes: textLabelAttributes)
                let value = NSAttributedString(string: snapshot.text(metric, compact: true), attributes: textValueAttributes)
                label.draw(in: NSRect(x: x, y: 12, width: columnWidth, height: 11))
                value.draw(in: NSRect(x: x, y: 0, width: columnWidth, height: 14))
            }
        }
    }
}
