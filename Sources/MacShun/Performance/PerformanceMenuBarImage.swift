// SPDX-License-Identifier: MIT

import AppKit

enum PerformanceMenuBarImage {
    private struct Column {
        enum Content {
            case icon(PerformanceMetric)
            case trend([PerformanceMetric])
            case processors
        }

        let width: CGFloat
        let content: Content
    }

    static func make(snapshot: PerformanceSnapshot, history: PerformanceHistory = PerformanceHistory(),
                     configuration: PerformanceConfig, needsAttention: Bool) -> NSImage {
        let metrics = configuration.metrics
        let brand = BrandMark.menuBarImage(needsAttention: needsAttention)
        guard !metrics.isEmpty else { return brand }
        let style = configuration.menuBarStyle
        if style == .text { return makeText(snapshot: snapshot, metrics: metrics, brand: brand) }

        let combined = configuration.canCombineProcessors && configuration.combineProcessors
        let columns = chartColumns(for: metrics, style: style, combined: combined)
        let gap: CGFloat = 6
        let leading: CGFloat = style == .icons ? 23 : 22
        let width = columns.reduce(leading) { $0 + $1.width } + CGFloat(columns.count - 1) * gap
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: true) { _ in
            brand.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18), from: .zero,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
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
            return true
        }
        image.isTemplate = true
        return image
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
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.black,
        ])
        let number = NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.black,
        ])
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
    private static func makeText(snapshot: PerformanceSnapshot, metrics: [PerformanceMetric], brand: NSImage) -> NSImage {
        let columnWidth: CGFloat = 40, gap: CGFloat = 6, leading: CGFloat = 28
        let width = leading + CGFloat(metrics.count) * columnWidth + CGFloat(max(0, metrics.count - 1)) * gap
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            brand.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            for (index, metric) in metrics.enumerated() {
                let x = leading + CGFloat(index) * (columnWidth + gap)
                let label = NSAttributedString(string: metric.barLabel, attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
                ])
                let value = NSAttributedString(string: snapshot.text(metric, compact: true), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
                ])
                label.draw(in: NSRect(x: x, y: 12, width: columnWidth, height: 11))
                value.draw(in: NSRect(x: x, y: 0, width: columnWidth, height: 14))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
