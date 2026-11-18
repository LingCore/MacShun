// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class CaptureCanvas: NSView, NSTextViewDelegate {
    let photo: CaptureImage
    let mode: CaptureMode
    let windowRects: [CGRect]
    private(set) var selection: CGRect? {
        didSet { if oldValue != selection { stopRedaction() } }
    }
    private(set) var polygon: CapturePolygon?
    private enum AnchorSelection { case region(Int), annotation(Int), curveControl }
    private var selectedAnchor: AnchorSelection?
    private var selectedAnnotationNode: Int? {
        if case .annotation(let index) = selectedAnchor { return index }
        return nil
    }
    private var anchorPoints: [CGPoint]?
    private var anchorPointer: CGPoint?
    private var drawingStroke = AnnotationStroke()
    private var lineStyle = AnnotationLineStyle()
    private var arrowStyle = AnnotationLineStyle(ends: .end)
    private var lineMode: AnnotationLineMode = .straight
    private var arrowMode: AnnotationLineMode = .straight
    private var polylineNodes: [CGPoint] = []
    private var snapAngles = false
    private var textStyle = AnnotationLettering(color: .black)
    private var textFormat = AnnotationTextFormat()
    private var numberStyle = AnnotationLettering(color: .red)
    private var coverColor: AnnotationColor = .black
    var isPlacingPolygonMark: Bool { anchorPoints != nil && tool == .polygon }
    private var anchorHint: String {
        L("点击添加锚点 · Shift 吸附 15° · 点首点或按 Enter 闭合 · Delete 撤回 · Esc 退出")
    }
    private(set) var annotations: CaptureAnnotations
    var marks: [CaptureMark] { annotations.marks }
    let isDocument: Bool
    private var selectedMark: Int?
    private var textInput: AnnotationTextInput?
    private var editingMark: CaptureMark?
    private var editingIndex: Int?
    var isEditingText: Bool { textInput != nil }
    private let dimensions = NSTextField(labelWithString: "")
    private var tool: CaptureMark.Kind?
    private var hovered: CGRect?
    let toolbar: CaptureToolbar
    private let hint = NSView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let selectionHint: String
    private var tracking: NSTrackingArea?
    private let loupe: CaptureLoupe?
    private let keyboardCursorScale: CGFloat
    private var pointer: CGPoint?
    private var keyboardPointer: (pixelCenter: CGPoint, systemPosition: CGPoint)?
    private var keyboardCursorLayer: CALayer?
    private var keyboardCursorStyle: NSCursor?
    private var hidSystemCursor = false
    private var heldDirection: (key: CGKeyCode, modifiers: NSEvent.ModifierFlags, startsAt: CFTimeInterval,
                                originalPolygon: CapturePolygon?)?
    private var directionLink: CADisplayLink?
    var hasHeldDirection: Bool { heldDirection != nil }
    private enum Redaction {
        case scanning(UUID), ready([CGRect]), failed
    }
    private var redaction: Redaction?
    private var redactionScan: DispatchWorkItem?

    /// 坐标是各边相对选区的位置（0、0.5 或 1）。
    private static let handles = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 1)
    ]
    private enum TextEdge { case left, right }
    private enum Drag {
        case select, move(CGRect, CapturePolygon?), resize(CGRect, CGPoint)
        case mark(CaptureMark.Kind, overMark: Int? = nil)
        case moveSelectionVertex(Int, CapturePolygon)
        case moveMark(Int, CaptureMark, vertex: Int? = nil)
        case resizeTextBox(Int, CaptureMark, TextEdge)

        var annotationIndex: Int? {
            switch self {
            case .moveMark(let index, _, _), .resizeTextBox(let index, _, _): index
            default: nil
            }
        }
    }
    private var drag: Drag?
    var isDragging: Bool { drag != nil }
    private var nudgedWhileSelecting = false
    private var start = CGPoint.zero
    private var draft: CaptureMark?
    var onChooseDisplay: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCopyColor: (() -> Void)?
    var canSampleDisplay: (() -> Bool)?
    var onNudgePointer: ((_ dx: Int, _ dy: Int) -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRestoreRegion: (() -> Void)?
    var onChooseAnchorMode: (() -> Void)?
    var onPolygonMarkPlacementChanged: ((Bool) -> Void)?

    init(photo: CaptureImage, mode: CaptureMode, windowRects: [CGRect], document: CaptureAnnotations? = nil, canRestore: Bool = false) {
        isDocument = document != nil
        annotations = document ?? CaptureAnnotations()
        toolbar = CaptureToolbar(document: document != nil)
        loupe = document == nil && mode == .image ? CaptureLoupe() : nil
        keyboardCursorScale = loupe == nil ? 1 : CaptureCursorImage.magnification(in: UserDefaults(suiteName: "com.apple.universalaccess"))
        self.photo = photo
        self.mode = mode
        self.windowRects = windowRects
        var text = mode == .text ? L("拖选文字或点选窗口，松开即复制 · Esc 取消") : L("拖选区域或点选窗口 · WASD 微调 · P 锚点选区 · Esc 取消")
        if canRestore, mode == .image { text += L(" · R 恢复上次选区") }
        selectionHint = text
        super.init(frame: photo.bounds)
        hintLabel.font = .systemFont(ofSize: 14, weight: .medium)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        hint.layer?.cornerRadius = 8
        hint.addSubview(hintLabel)
        setHint(selectionHint)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dimensions.textColor = .white
        dimensions.alignment = .center
        dimensions.wantsLayer = true
        dimensions.layer?.cornerRadius = 5
        dimensions.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        dimensions.isHidden = true
        if isDocument { selection = photo.bounds }
        else {
            if loupe != nil { wantsLayer = true }
            addSubview(hint)
            addSubview(dimensions)
            addSubview(toolbar)
            if let loupe { addSubview(loupe) }
        }
        toolbar.isHidden = !isDocument
        toolbar.perform = { [weak self] action in self?.perform(action) }
        toolbar.changeStyle = { [weak self] style in self?.changeAnnotationStyle(style) }
        toolbar.changeLineStyle = { [weak self] style in self?.changeLineStyle(style) }
        toolbar.changeLineMode = { [weak self] mode in self?.changeLineMode(mode) }
        if isDocument { refresh() }
        setAccessibilityLabel(mode.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { redactionScan?.cancel() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target?.isDescendant(of: hint) == true || target === hint || target === dimensions ? self : target
    }

    func clearSelection(keepingPointer: Bool = false) {
        if heldDirection?.originalPolygon != nil { stopDirectionRepeat() }
        endAnchors()
        polylineNodes.removeAll()
        polygon = nil
        selectedAnchor = nil
        selection = nil
        finishText(commit: false)
        annotations = CaptureAnnotations()
        selectedMark = nil
        draft = nil
        tool = nil
        drag = nil
        nudgedWhileSelecting = false
        hovered = nil
        if !keepingPointer {
            pointer = nil
            endKeyboardPointer()
            stopDirectionRepeat()
        }
        refresh()
    }

    private func refresh() {
        let placingAnchors = anchorPoints != nil
        var dimensionsFit = false
        hint.isHidden = isPlacingPolygonMark || (!placingAnchors && (selection != nil || drag != nil))
        toolbar.isHidden = !isDocument && (mode == .text || selection == nil || drag != nil || (placingAnchors && !isPlacingPolygonMark))
        if !toolbar.isHidden {
            toolbar.update(tool: tool, canUndo: annotations.canUndo, canRedo: annotations.canRedo,
                           canScroll: canScroll, hasMarks: !marks.isEmpty, redactionStatus: redactionStatus, hasPolygon: polygon != nil,
                           anchorStatus: isPlacingPolygonMark ? anchorHint : nil,
                           pathStatus: polylineNodes.isEmpty ? nil : L("单击加点 · 点起点闭合 · Enter 完成 · Esc 取消"),
                           canRemoveAnchor: anchorPoints?.isEmpty == false || !polylineNodes.isEmpty,
                           style: activeAnnotationStyle,
                           lineStyle: activeLineStyle,
                           lineMode: activeLineMode, allowsPolyline: tool == .line,
                           styleOnly: !isDocument && isPlacingPolygonMark)
        }
        if !isDocument, isPlacingPolygonMark {
            toolbar.fit(within: bounds.width - 12)
            toolbar.setFrameOrigin(CGPoint(x: floor(bounds.midX - toolbar.frame.width / 2),
                                           y: max(6, bounds.maxY - toolbar.frame.height - 16)))
        } else if !isDocument, !placingAnchors, let rect = selection {
            toolbar.fit(within: bounds.width - 12)
            let size = toolbar.frame.size, gap: CGFloat = 10
            let x = max(6, min(rect.maxX - size.width, bounds.maxX - size.width - 6))
            var y = rect.minY - size.height - gap
            if y < 6 { y = min(rect.maxY + gap, bounds.maxY - size.height - 6) }
            var origin = CGPoint(x: x.rounded(), y: y.rounded())
            let annotationVertices = (editableLine?.editableNodes ?? selectedAnnotation?.editableNodes)?.filter {
                CaptureLineShape.clamped($0, in: rect) == $0
            } ?? []
            let vertices = (editableSelectionPolygon?.vertices ?? []) + annotationVertices
            let vertexTargets = vertices.map {
                CGRect(x: $0.x - 8, y: $0.y - 8, width: 16, height: 16)
            }
            if !toolbar.isHidden, vertexTargets.contains(where: { $0.intersects(CGRect(origin: origin, size: size)) }) {
                let right = max(6, bounds.maxX - size.width - 6).rounded()
                let top = max(6, bounds.maxY - size.height - 6).rounded()
                let middle = ((6 + top) / 2).rounded()
                let gaps = vertexTargets.flatMap {
                    [floor($0.minY - size.height - 1), ceil($0.maxY + 1)]
                }.filter { (6...top).contains($0) }
                let alternatives = ([origin.y, 6, top, middle] + gaps).lazy.flatMap { y in
                    [origin.x, 6, right].map { CGPoint(x: $0, y: y) }
                }
                if let free = alternatives.first(where: { p in
                    !vertexTargets.contains { $0.intersects(CGRect(origin: p, size: size)) }
                }) { origin = free }
            }
            if case .ready(let boxes) = redaction,
               boxes.contains(where: { $0.intersects(CGRect(origin: origin, size: size)) }) {
                let left = max(6, min(rect.minX, bounds.maxX - size.width - 6)).rounded()
                let bottom = max(6, rect.minY - size.height - gap).rounded()
                let top = min(rect.maxY + gap, bounds.maxY - size.height - 6).rounded()
                let alternatives = [CGPoint(x: left, y: y.rounded()), CGPoint(x: origin.x, y: bottom),
                                    CGPoint(x: left, y: bottom), CGPoint(x: origin.x, y: top), CGPoint(x: left, y: top)]
                if let free = alternatives.first(where: { p in !boxes.contains { $0.intersects(CGRect(origin: p, size: size)) } }) {
                    origin = free
                }
            }
            toolbar.setFrameOrigin(origin)
            toolbar.setPrimaryRowOnTop(origin.y < rect.minY)
            let px = photo.pixelRect(rect)
            dimensions.stringValue = "\(Int(px.width)) × \(Int(px.height)) px"
            dimensions.sizeToFit()
            let w = dimensions.frame.width + 12, h = dimensions.frame.height + 4
            let labelX = min(max(4, rect.minX), bounds.maxX - w - 4)
            var labelOrigins = [CGPoint(x: labelX, y: rect.maxY + 6), CGPoint(x: labelX, y: rect.minY - h - 6)]
            if rect.width >= w + 12, rect.height >= h + 12 {
                labelOrigins.append(CGPoint(x: rect.minX + 6, y: rect.maxY - h - 6))
                labelOrigins.append(CGPoint(x: rect.minX + 6, y: rect.minY + 6))
            }
            let obstacles = toolbar.visibleCardFrames.map { $0.insetBy(dx: -4, dy: -4) } + vertexTargets
            let labelSize = CGSize(width: w, height: h)
            if let frame = labelOrigins.map({ CGRect(origin: $0, size: labelSize).integral }).first(where: {
                let frame = $0
                return bounds.insetBy(dx: 4, dy: 4).contains(frame) && !obstacles.contains { $0.intersects(frame) }
            }) {
                dimensions.frame = frame
                dimensionsFit = true
            }
        }
        dimensions.isHidden = !dimensionsFit || mode == .text || isEditingText || redaction != nil || anchorPoints != nil
        updateLoupe()
        needsDisplay = true
    }

    private func updateLoupe() {
        guard let loupe else { return }
        guard let pointer, let pixel = photo.pixel(at: pointer), !isEditingText, anchorPoints == nil,
              tool == nil, redaction == nil, canSampleDisplay?() != false else {
            loupe.isHidden = true
            return
        }
        let toolbarCards = toolbar.visibleCardFrames
        if toolbarCards.contains(where: { $0.contains(pointer) }) {
            loupe.isHidden = true
            return
        }
        if let selection, drag == nil,
           !(polygon?.contains(pointer) ?? selection.insetBy(dx: -1, dy: -1).contains(pointer)) {
            loupe.isHidden = true
            return
        }
        let obstacles = (toolbarCards + [dimensions, hint].filter { !$0.isHidden }.map(\.frame))
            .map { $0.insetBy(dx: -6, dy: -6) }
        guard let frame = CaptureLoupe.frame(near: pointer, in: bounds, avoiding: obstacles,
                                            scale: window?.backingScaleFactor ?? 1) else {
            loupe.isHidden = true
            return
        }
        if loupe.sample?.pixel != pixel { loupe.sample = CaptureLoupeSample(image: photo.image, pixel: pixel) }
        loupe.canCopy = drag == nil
        if loupe.frame.size != frame.size { loupe.needsDisplay = true }
        if loupe.frame != frame { loupe.frame = frame }
        loupe.isHidden = loupe.sample == nil
    }

    func colorToCopy(at point: CGPoint) -> String? {
        pointer = effectivePointer(at: point)
        updateLoupe()
        guard let loupe, !loupe.isHidden, loupe.canCopy else { return nil }
        return loupe.displayedColor
    }

    func setColorFormat(_ format: CaptureColorFormat) { loupe?.colorFormat = format }

    func showColorCopied() { loupe?.copied = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pixels = photo.pixelRect(dirtyRect)
        if isDocument, let tile = photo.image.cropping(to: pixels) {
            ctx.draw(tile, in: photo.pointRect(pixels))
        } else { ctx.draw(photo.image, in: bounds) }
        let area = anchorPoints == nil || isPlacingPolygonMark ? selection ?? hovered : nil
        ctx.saveGState()
        ctx.addRect(bounds)
        if let area {
            if let polygon { ctx.addPath(polygon.path) } else { ctx.addRect(area) }
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.39))
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
        if let anchorPoints, !isPlacingPolygonMark {
            drawAnchors(anchorPoints, in: ctx)
            return
        }
        guard let area, !area.isEmpty else { return }
        ctx.saveGState()
        if let polygon {
            ctx.addPath(polygon.path)
            ctx.clip(using: .evenOdd)
        } else {
            ctx.clip(to: area)
        }
        let draggedMark = draft == nil ? nil : drag?.annotationIndex
        for (i, mark) in marks.enumerated() where i != editingIndex && i != draggedMark {
            if mark.selectionBounds.intersects(dirtyRect) { mark.draw(in: ctx) }
        }
        draft?.draw(in: ctx)
        if let anchorPoints {
            drawAnchors(anchorPoints, in: ctx)
        } else if !polylineNodes.isEmpty {
            drawPolyline(in: ctx)
        } else if let selectedPolygon = draft?.polygon ?? selectedAnnotation?.polygon {
            drawVertices(selectedPolygon.vertices, color: NSColor.systemBlue.cgColor, in: ctx, activeIndex: selectedAnnotationNode)
        } else if let selectedLine = editableLine {
            drawLineHandles(draft ?? selectedLine, in: ctx)
        } else if let box = editableTextBox, drag == nil || draft?.kind == .text {
            drawTextBoxHandles((draft ?? box).bounds, in: ctx)
        } else if let i = selectedMark, marks.indices.contains(i), editingIndex == nil, drag == nil,
                  tool?.usesStroke != true, tool?.usesLettering != true {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(marks[i].selectionBounds)
            ctx.restoreGState()
        }
        if redaction != nil {
            for box in redactionCandidates where box.intersects(dirtyRect) {
                let border = box.insetBy(dx: 0.75, dy: 0.75)
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
                ctx.setLineWidth(3)
                ctx.stroke(border)
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(border)
            }
        }
        ctx.restoreGState()
        if isDocument { return }
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        if let polygon {
            ctx.addPath(polygon.path)
            ctx.strokePath()
            if let editableSelectionPolygon {
                let active: Int?
                if case .region(let index) = selectedAnchor { active = index } else { active = nil }
                drawVertices(editableSelectionPolygon.vertices, color: NSColor.systemBlue.cgColor, in: ctx,
                             activeIndex: active)
            }
        } else {
            ctx.stroke(area.insetBy(dx: 1, dy: 1))
        }
        if polygon == nil, selection != nil, tool == nil, redaction == nil, drag == nil, mode == .image {
            for h in Self.handles {
                let p = anchor(h, in: area)
                let box = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: box)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: box)
            }
        }
    }

    private func anchor(_ handle: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + handle.x * rect.width, y: rect.minY + handle.y * rect.height)
    }

    private func setHint(_ text: String) {
        hintLabel.stringValue = text
        let width = max(1, min(bounds.width - 32, ceil(hintLabel.intrinsicContentSize.width) + 8))
        let height = hintLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 200)).height ?? 20
        hintLabel.frame = CGRect(x: 12, y: 6, width: width, height: height).integral
        hint.frame = CGRect(x: (bounds.width - width - 24) / 2, y: bounds.maxY - height - 60,
                            width: width + 24, height: height + 12).integral
    }

    private func canCloseAnchors(at point: CGPoint) -> Bool {
        guard let anchorPoints, anchorPoints.count >= 3, let first = anchorPoints.first else { return false }
        return hypot(first.x - point.x, first.y - point.y) <= 9 * screenPoint
    }

    private func newAnchor(at raw: CGPoint) -> CGPoint? {
        guard let anchorPoints, bounds.contains(raw) else { return nil }
        let limits: CGRect
        if isPlacingPolygonMark {
            guard let selection, containsSelection(raw) else { return nil }
            limits = selection
        } else {
            limits = bounds
        }
        let point = anchorPoints.last.map { CaptureLineShape.point(raw, from: $0, in: limits, snap: snapAngles) } ?? raw
        guard !anchorPoints.contains(point), !isPlacingPolygonMark || polygon?.contains(point) != false else { return nil }
        return point
    }

    private var screenPoint: CGFloat { isDocument ? convert(CGSize(width: 1, height: 1), from: nil).width : 1 }

    private func drawAnchors(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        let handleColor = NSColor.systemBlue.cgColor
        let color = isPlacingPolygonMark ? drawingStroke.color.ink : handleColor
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(isPlacingPolygonMark ? drawingStroke.width.points : 2)
        ctx.move(to: first)
        for point in points.dropFirst() { ctx.addLine(to: point) }
        let closing = anchorPointer.map { canCloseAnchors(at: $0) } == true
        if closing { ctx.addLine(to: first) }
        else if let anchorPointer, let next = newAnchor(at: anchorPointer) { ctx.addLine(to: next) }
        ctx.strokePath()
        drawVertices(points, color: handleColor, in: ctx, placing: true, activeIndex: closing ? 0 : nil)
    }

    private func drawVertices(_ points: [CGPoint], color: CGColor, in ctx: CGContext,
                              placing: Bool = false, activeIndex: Int? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let scale = screenPoint
        ctx.setLineWidth(1.5 * scale)
        for (index, point) in points.enumerated() {
            let active = index == activeIndex
            let radius = (active || (placing && index == 0) ? 5 : 3.5) * scale
            let box = CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
            ctx.setFillColor(active ? color : NSColor.white.cgColor)
            ctx.setStrokeColor(active && !placing ? NSColor.white.cgColor : color)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
        }
    }

    private func drawLineHandles(_ mark: CaptureMark, in ctx: CGContext) {
        let color = NSColor.systemBlue.cgColor
        if let segments = mark.curveSegments {
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(screenPoint)
            ctx.setLineDash(phase: 0, lengths: [3 * screenPoint, 3 * screenPoint])
            for segment in segments {
                ctx.addLines(between: [segment.start, segment.firstControl])
                ctx.addLines(between: [segment.end, segment.secondControl])
            }
            ctx.strokePath()
            ctx.restoreGState()
            drawVertices(segments.flatMap { [$0.firstControl, $0.secondControl] }, color: color, in: ctx)
        }
        drawVertices(mark.lineNodes, color: color, in: ctx, activeIndex: selectedAnnotationNode)
    }

    private func drawTextBoxHandles(_ box: CGRect, in ctx: CGContext) {
        let scale = screenPoint
        let color = NSColor.systemBlue.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(scale)
        ctx.setLineDash(phase: 0, lengths: [4 * scale, 3 * scale])
        ctx.stroke(box.insetBy(dx: scale / 2, dy: scale / 2))
        ctx.setFillColor(color)
        for x in [box.minX - 3 * scale, box.maxX - 2 * scale] {
            let grip = CGRect(x: x, y: box.midY - 7 * scale, width: 5 * scale, height: 14 * scale)
            ctx.addPath(CGPath(roundedRect: grip, cornerWidth: grip.width / 2, cornerHeight: grip.width / 2, transform: nil))
        }
        ctx.fillPath()
    }

    private func canClosePolyline(at point: CGPoint) -> Bool {
        guard polylineNodes.count >= 3, let first = polylineNodes.first, first != polylineNodes.last else { return false }
        return hypot(first.x - point.x, first.y - point.y) <= 9 * screenPoint
    }

    private func polylinePoint(at raw: CGPoint) -> CGPoint? {
        guard let selection, containsSelection(raw) else { return nil }
        guard let previous = polylineNodes.last else { return raw }
        let point = CaptureLineShape.point(raw, from: previous, in: selection, snap: snapAngles)
        return point != previous && polygon?.contains(point) != false ? point : nil
    }

    private func polylineMark(_ nodes: [CGPoint], closed: Bool) -> CaptureMark? {
        guard nodes.count >= 2, let first = nodes.first, let last = nodes.last else { return nil }
        return CaptureMark(kind: .line, start: first, end: last, stroke: drawingStroke, customLineStyle: lineStyle,
                           lineShape: .polyline(interior: Array(nodes.dropFirst().dropLast()), closed: closed))
    }

    private func drawPolyline(in context: CGContext) {
        let closing = pointer.map(canClosePolyline(at:)) == true
        var points = polylineNodes
        if !closing, let pointer, let next = polylinePoint(at: pointer) { points.append(next) }
        polylineMark(points, closed: closing)?.draw(in: context)
        drawVertices(polylineNodes, color: NSColor.systemBlue.cgColor, in: context, placing: true,
                     activeIndex: closing ? 0 : nil)
    }

    func finishPolyline(closed: Bool = false) {
        guard !polylineNodes.isEmpty else { return }
        if let mark = polylineMark(polylineNodes, closed: closed) {
            annotations.change { $0.append(mark) }
            selectedMark = marks.indices.last
        }
        polylineNodes.removeAll()
        refresh()
    }

    private func addPolylineNode(at point: CGPoint, clicks: Int) {
        if canClosePolyline(at: point) { finishPolyline(closed: true); return }
        if let node = polylinePoint(at: point) { polylineNodes.append(node) }
        if clicks > 1 { finishPolyline(); return }
        refresh()
    }

    func beginAnchors() {
        guard !isDocument, mode == .image, marks.isEmpty, drag == nil else { return }
        stopRedaction()
        selectedMark = nil
        selectedAnchor = nil
        tool = nil
        hovered = nil
        anchorPoints = []
        anchorPointer = nil
        setHint(anchorHint)
        refresh()
        window?.makeFirstResponder(self)
    }

    private func endAnchors() {
        guard anchorPoints != nil else { return }
        let wasMark = isPlacingPolygonMark
        anchorPoints = nil
        anchorPointer = nil
        if wasMark {
            tool = nil
            onPolygonMarkPlacementChanged?(false)
        }
        if !isDocument { setHint(selectionHint) }
    }

    private func closeAnchors() {
        guard let anchorPoints, let result = CapturePolygon(anchorPoints) else { NSSound.beep(); return }
        let wasMark = isPlacingPolygonMark
        endAnchors()
        if wasMark {
            annotations.change { $0.append(CaptureMark(polygon: result, stroke: drawingStroke)) }
            selectedMark = marks.indices.last
        } else {
            annotations = CaptureAnnotations()
            setSelectionPolygon(result)
        }
        refresh()
    }

    private func removeLastAnchor() {
        if anchorPoints?.isEmpty == false {
            anchorPoints?.removeLast()
            anchorPointer = pointer
        }
        refresh()
    }

    private func containsSelection(_ point: CGPoint) -> Bool {
        polygon?.contains(point) ?? (selection?.contains(point) == true)
    }

    private func setSelectionPolygon(_ shape: CapturePolygon) {
        polygon = shape
        selection = shape.bounds
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func hover(at point: CGPoint) {
        guard pointer != point else { return }
        pointer = point
        if bounds.contains(point) {
            let next = cursor(at: point)
            if NSCursor.current !== next { next.set() }
        }
        updateLoupe()
        if anchorPoints != nil {
            anchorPointer = point
            needsDisplay = true
            return
        }
        if !polylineNodes.isEmpty { needsDisplay = true; return }
        guard selection == nil, drag == nil else { return }
        let rect = windowRects.first(where: { $0.contains(point) })
        if hovered != rect { hovered = rect; needsDisplay = true }
    }

    func effectivePointer(at systemPosition: CGPoint) -> CGPoint {
        // macOS 的光标位置可能按整点取整，Retina 取色仍保留实际选中的像素。
        if let keyboardPointer, keyboardPointer.systemPosition == systemPosition { return keyboardPointer.pixelCenter }
        endKeyboardPointer()
        return systemPosition
    }

    private func point(_ event: NSEvent) -> CGPoint { effectivePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        snapAngles = event.modifierFlags.contains(.shift)
        hover(at: point(event))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        endKeyboardPointer()
        loupe?.isHidden = true
        hovered = nil
        anchorPointer = nil
        needsDisplay = true
    }
    override func cursorUpdate(with event: NSEvent) { cursor(at: point(event)).set() }

    /// 显示哪个缩放指针和按下后拖哪个手柄，都由同一个命中区决定。
    private func handle(at p: CGPoint, in rect: CGRect) -> CGPoint? {
        guard !isDocument, polygon == nil, tool == nil, mode == .image else { return nil }
        let nearest = Self.handles.min {
            let a = anchor($0, in: rect), b = anchor($1, in: rect)
            return hypot(a.x - p.x, a.y - p.y) < hypot(b.x - p.x, b.y - p.y)
        }
        guard let nearest else { return nil }
        let a = anchor(nearest, in: rect)
        return abs(p.x - a.x) <= 6 && abs(p.y - a.y) <= 6 ? nearest : nil
    }

    private func resizeCursor(_ h: CGPoint) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch (h.x, h.y) {
            case (0, 0): position = .bottomLeft
            case (0, 1): position = .topLeft
            case (1, 0): position = .bottomRight
            case (1, 1): position = .topRight
            case (0, _): position = .left
            case (1, _): position = .right
            case (_, 0): position = .bottom
            default: position = .top
            }
            return .frameResize(position: position, directions: [.inward, .outward])
        }
        if h.x == 0.5 { return .resizeUpDown }
        if h.y == 0.5 { return .resizeLeftRight }
        return .crosshair
    }

    private var selectedAnnotation: CaptureMark? {
        guard tool == nil, redaction == nil, let selectedMark, marks.indices.contains(selectedMark) else { return nil }
        return marks[selectedMark]
    }

    private var activeAnnotationStyle: AnnotationStyle? {
        if let editingMark { return editingMark.style }
        if tool?.usesStroke == true { return .stroke(drawingStroke) }
        if tool == .text { return editableTextBox?.style ?? .lettering(textStyle, text: textFormat) }
        if tool == .number { return .lettering(numberStyle) }
        if tool == .cover { return .fill(coverColor) }
        return selectedAnnotation?.style
    }

    private var activeLineStyle: AnnotationLineStyle? {
        if tool == .line { return lineStyle }
        if tool == .arrow { return arrowStyle }
        guard let mark = selectedAnnotation, mark.kind.isLine, mark.lineShape?.isClosed != true else { return nil }
        return mark.lineStyle
    }

    private var activeLineMode: AnnotationLineMode? {
        if tool == .line { return lineMode }
        if tool == .arrow { return arrowMode }
        return nil
    }

    private var editableLine: CaptureMark? {
        guard redaction == nil, let selectedMark, marks.indices.contains(selectedMark) else { return nil }
        let mark = marks[selectedMark]
        guard mark.kind.isLine, tool == nil || (tool == mark.kind && mark.lineShape != nil) else { return nil }
        return mark
    }

    private var editableTextBox: CaptureMark? {
        guard (tool == nil || tool == .text), redaction == nil, !isEditingText,
              let selectedMark, marks.indices.contains(selectedMark), marks[selectedMark].kind == .text else { return nil }
        return marks[selectedMark]
    }

    private func textEdge(at point: CGPoint, in box: CGRect) -> TextEdge? {
        let tolerance = 7 * screenPoint
        guard point.y >= box.minY - tolerance, point.y <= box.maxY + tolerance else { return nil }
        let left = abs(point.x - box.minX), right = abs(point.x - box.maxX)
        guard min(left, right) <= tolerance else { return nil }
        return left <= right ? .left : .right
    }

    private func changeLineMode(_ mode: AnnotationLineMode) {
        guard drag == nil, activeLineMode != mode else { return }
        finishPolyline()
        if tool == .line { lineMode = mode }
        else if tool == .arrow, mode != .polyline { arrowMode = mode }
        else { return }
        selectedMark = nil
        selectedAnchor = nil
        refresh()
        window?.makeFirstResponder(self)
    }

    private func changeLineStyle(_ style: AnnotationLineStyle) {
        guard drag == nil, activeLineStyle != style else { return }
        switch tool {
        case .line: lineStyle = style
        case .arrow: arrowStyle = style
        default:
            guard let selectedMark, selectedAnnotation?.kind.isLine == true else { return }
            annotations.change { $0[selectedMark].customLineStyle = style }
        }
        refresh()
        window?.makeFirstResponder(self)
    }

    private func changeAnnotationStyle(_ style: AnnotationStyle) {
        guard drag == nil, activeAnnotationStyle != nil else { return }
        switch style {
        case .stroke(let stroke):
            drawingStroke = stroke
            if selectedAnnotation?.kind.usesStroke == true, let selectedMark {
                annotations.change { $0[selectedMark].stroke = stroke }
            }
        case .lettering(let lettering, let format):
            guard style != activeAnnotationStyle else { return }
            if let input = textInput, var mark = editingMark {
                mark.applyLettering(lettering, text: format)
                editingMark = mark
                if editingIndex == nil, let format {
                    textStyle = lettering
                    textFormat = format
                }
                updateTextAppearance(input, mark: mark)
                fitTextInput()
            } else if let mark = editableTextBox ?? selectedAnnotation, mark.kind.usesLettering, let selectedMark {
                var updated = mark
                updated.applyLettering(lettering, text: format)
                let fitted = fitAnnotation(updated)
                annotations.change { $0[selectedMark] = fitted }
            } else if tool == .text, let format {
                textStyle = lettering
                textFormat = format
            } else if tool == .number {
                numberStyle = lettering
            }
        case .fill(let color):
            if tool == .cover {
                coverColor = color
            } else if selectedAnnotation?.kind == .cover, let selectedMark {
                annotations.change { $0[selectedMark].fillColor = color }
            }
        }
        refresh()
        window?.makeFirstResponder(textInput ?? self)
    }

    private var editableSelectionPolygon: CapturePolygon? {
        guard !isDocument, mode == .image, tool == nil, redaction == nil, !isEditingText,
              anchorPoints == nil else { return nil }
        switch drag {
        case nil, .moveSelectionVertex: return polygon
        default: return nil
        }
    }

    private func vertex(at point: CGPoint, in vertices: [CGPoint]?) -> Int? {
        guard let vertices else { return nil }
        let radius = 7 * screenPoint
        return vertices.enumerated().map { (index, vertex) in (index, hypot(vertex.x - point.x, vertex.y - point.y)) }
            .filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }

    private func annotationVertex(at point: CGPoint) -> Int? {
        vertex(at: point, in: editableLine?.lineHandles ?? selectedAnnotation?.polygon?.vertices)
    }

    private func canEditNodes(of mark: CaptureMark) -> Bool {
        if tool == nil { return true }
        guard tool == mark.kind else { return false }
        switch activeLineMode {
        case .straight: return mark.lineShape == nil || mark.isPolyline
        case .polyline: return mark.isPolyline
        case .curve: return mark.curveSegments != nil
        case nil: return mark.kind.isBasicShape
        }
    }

    private func annotationEdge(at point: CGPoint, in mark: CaptureMark) -> CaptureLineShape.SegmentHit? {
        guard canEditNodes(of: mark), let selection else { return nil }
        let tolerance = max(6 * screenPoint, mark.stroke.width.points / 2 + 2 * screenPoint)
        guard let edge = mark.nearestEditableSegment(to: point, within: tolerance),
              CaptureLineShape.clamped(edge.point, in: selection) == edge.point else { return nil }
        if let polygon, !polygon.contains(edge.point), polygon.nearestEdge(to: edge.point, within: 0.001) == nil {
            return nil
        }
        return edge
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        if !isDocument, !toolbar.isHidden, toolbar.frame.contains(p), toolbar.hitTest(p) != nil { return .arrow }
        if anchorPoints != nil { return canCloseAnchors(at: p) ? .pointingHand : .crosshair }
        if !polylineNodes.isEmpty { return canClosePolyline(at: p) ? .pointingHand : .crosshair }
        switch drag {
        case .move, .moveSelectionVertex, .moveMark: return .closedHand
        case .resizeTextBox: return .resizeLeftRight
        case .resize(_, let h): return resizeCursor(h)
        case .select, .mark: return .crosshair
        case nil: break
        }
        guard let selection else { return .crosshair }
        if redaction != nil { return redactionCandidate(at: p) == nil ? .arrow : .pointingHand }
        if let mark = editableTextBox, textEdge(at: p, in: mark.bounds) != nil { return .resizeLeftRight }
        if annotationVertex(at: p) != nil || vertex(at: p, in: editableSelectionPolygon?.vertices) != nil { return .openHand }
        if let h = handle(at: p, in: selection) { return resizeCursor(h) }
        if editableSelectionPolygon?.nearestEdge(to: p, within: 6) != nil { return .openHand }
        if let mark = selectedAnnotation ?? editableLine, annotationEdge(at: p, in: mark) != nil { return .openHand }
        guard containsSelection(p) else { return .crosshair }
        if tool == .text || textInput?.frame.contains(p) == true { return .iBeam }
        if tool != nil { return .crosshair }
        return !isDocument || marks.contains { $0.hit(p) } ? .openHand : .arrow
    }

    override func mouseDown(with event: NSEvent) {
        if heldDirection?.originalPolygon != nil { stopDirectionRepeat() }
        onChooseDisplay?()
        guard finishText(commit: true) else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = point(event)
        pointer = start
        snapAngles = event.modifierFlags.contains(.shift)
        selectedAnchor = nil
        if anchorPoints != nil {
            anchorPointer = start
            if canCloseAnchors(at: start) {
                closeAnchors()
            } else if let next = newAnchor(at: start) {
                anchorPoints?.append(next)
                anchorPointer = nil
                refresh()
            }
            needsDisplay = true
            cursor(at: start).set()
            return
        }
        if !polylineNodes.isEmpty { addPolylineNode(at: start, clicks: event.clickCount); return }
        if redaction != nil {
            if let box = redactionCandidate(at: start) {
                annotations.change {
                    $0.append(CaptureMark(kind: .cover, start: box.origin, end: CGPoint(x: box.maxX, y: box.maxY)))
                }
                refresh()
                cursor(at: start).set()
            }
            return
        }
        if event.clickCount != 2, let index = selectedMark, let mark = editableTextBox,
           let edge = textEdge(at: start, in: mark.bounds) {
            drag = .resizeTextBox(index, mark, edge)
            refresh()
            cursor(at: start).set()
            return
        }
        if let index = selectedMark, let vertex = annotationVertex(at: start) {
            let mark = marks[index]
            let control = mark.curveSegments != nil && vertex >= mark.lineNodes.count
            if !control || event.clickCount != 2 || annotationEdge(at: start, in: mark) == nil {
                if control { selectedAnchor = .curveControl }
                else if mark.editableNodes != nil { selectedAnchor = .annotation(vertex) }
                drag = .moveMark(index, mark, vertex: vertex)
                refresh()
                cursor(at: start).set()
                return
            }
        }
        let editablePolygon = editableSelectionPolygon
        if let polygon = editablePolygon, let vertex = vertex(at: start, in: polygon.vertices) {
            selectedMark = nil
            selectedAnchor = .region(vertex)
            drag = .moveSelectionVertex(vertex, polygon)
            refresh()
            cursor(at: start).set()
            return
        }
        let inside = containsSelection(start)
        let drawingMode = activeLineMode
        let hit = marks.indices.reversed().first { index in
            let mark = marks[index]
            guard drawingMode == nil || canEditNodes(of: mark) else { return false }
            return (inside && mark.hit(start)) || annotationEdge(at: start, in: mark) != nil
        }
        if inside, let hit {
            let mark = marks[hit]
            if (event.clickCount == 2 && mark.kind.usesLettering) || (tool == .text && mark.kind == .text) {
                beginText(mark, index: hit)
                return
            }
        }
        let regionEdge = editablePolygon?.nearestEdge(to: start, within: 6)
        if event.clickCount == 2, let hit,
           let edge = annotationEdge(at: start, in: marks[hit]), edge.distance <= (regionEdge?.distance ?? .infinity),
           let updated = marks[hit].insertingNode(on: edge) {
            if tool?.isBasicShape == true { tool = nil }
            selectedMark = hit
            selectedAnchor = .annotation(updated.editableNodes?.firstIndex(of: edge.point) ?? edge.index + 1)
            annotations.change { $0[hit] = updated }
            refresh()
            cursor(at: start).set()
            return
        }
        selectedMark = nil
        if event.clickCount == 2, let edge = regionEdge, let original = editablePolygon,
           let updated = original.insertingVertex(edge.point, after: edge.index) {
            selectedAnchor = .region(edge.index + 1)
            setSelectionPolygon(updated)
            annotations.recordPolygonChange(from: original, to: updated)
            refresh()
            cursor(at: start).set()
            return
        }
        let editingLine = hit.map {
            drawingMode == .polyline || drawingMode == .curve || (drawingMode == .straight && marks[$0].isPolyline)
        } ?? false
        if let selection, let tool, inside, !editingLine {
            switch tool {
            case .text:
                let x = min(start.x, selection.maxX - min(selection.width, 80))
                let y = max(start.y, selection.minY + min(selection.height, 30))
                beginText(CaptureMark(kind: .text, start: CGPoint(x: x, y: y),
                                      end: CGPoint(x: min(x + 360, selection.maxX), y: y),
                                      letteringStyle: textStyle, textFormat: textFormat), index: nil)
                return
            case .number:
                if let hit, marks[hit].kind == .number {
                    selectedMark = hit
                    drag = .moveMark(hit, marks[hit])
                } else {
                    let mark = fitAnnotation(CaptureMark(kind: .number, start: start, end: start,
                                                         number: annotations.nextNumber, letteringStyle: numberStyle))
                    annotations.change { $0.append(mark) }
                    selectedMark = marks.indices.last
                }
            case .line where lineMode == .polyline:
                addPolylineNode(at: start, clicks: event.clickCount)
                return
            default:
                let overMark = hit.flatMap { index in
                    drawingMode == .straight || (tool.isBasicShape && marks[index].kind == tool) ? index : nil
                }
                drag = .mark(tool, overMark: overMark)
            }
        } else if let selection, let handle = handle(at: start, in: selection) {
            drag = .resize(selection, handle)
        } else if let hit {
            selectedMark = hit
            let vertex = canEditNodes(of: marks[hit]) ? vertex(at: start, in: marks[hit].editableNodes) : nil
            if let vertex { selectedAnchor = .annotation(vertex) }
            drag = .moveMark(hit, marks[hit], vertex: vertex)
        } else if isDocument {
            refresh()
            return
        } else if let selection, inside || regionEdge != nil {
            drag = .move(selection, polygon)
        } else {
            clearSelection(keepingPointer: true)
            drag = .select
        }
        refresh()
        cursor(at: start).set()
    }

    private func updateDrag(to raw: CGPoint) {
        guard let drag else { return }
        pointer = raw
        let p = CGPoint(x: min(max(0, raw.x), bounds.width), y: min(max(0, raw.y), bounds.height))
        switch drag {
        case .select:
            selection = CaptureImage.rect(from: start, to: p)
        case .move(let old, let oldPolygon):
            let x = min(max(0, old.minX + (p.x - start.x)), bounds.width - old.width)
            let y = min(max(0, old.minY + (p.y - start.y)), bounds.height - old.height)
            if let oldPolygon {
                let dx = x - old.minX, dy = y - old.minY
                setSelectionPolygon(dx == 0 && dy == 0 ? oldPolygon : oldPolygon.offsetBy(dx: dx, dy: dy))
            } else {
                selection = CGRect(origin: CGPoint(x: x, y: y), size: old.size)
            }
        case .resize(let old, let h):
            let dx = p.x - start.x, dy = p.y - start.y
            let x0 = h.x == 0 ? max(0, min(old.maxX - 1, old.minX + dx)) : old.minX
            let x1 = h.x == 1 ? min(bounds.maxX, max(old.minX + 1, old.maxX + dx)) : old.maxX
            let y0 = h.y == 0 ? max(0, min(old.maxY - 1, old.minY + dy)) : old.minY
            let y1 = h.y == 1 ? min(bounds.maxY, max(old.minY + 1, old.maxY + dy)) : old.maxY
            selection = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case .moveSelectionVertex(let vertex, let original):
            let old = original.vertices[vertex]
            let target = CGPoint(x: old.x + (raw.x - start.x), y: old.y + (raw.y - start.y))
            let updated = raw == start ? original : original.movingVertex(vertex, to: target, in: bounds, snap: snapAngles)
            if let updated { setSelectionPolygon(updated) }
        case .resizeTextBox(_, let original, let edge):
            guard let r = selection else { return }
            let box = original.bounds
            let dx = p.x - start.x
            let minimum = min(box.width, max(36, ceil(original.lettering.size.points) + 2 * CaptureMark.textInset.width))
            var updated = original
            updated.start.x = box.minX
            updated.end.x = box.maxX
            switch edge {
            case .left: updated.start.x = min(box.maxX - minimum, max(r.minX, box.minX + dx))
            case .right: updated.end.x = max(box.minX + minimum, min(r.maxX, box.maxX + dx))
            }
            if dx == 0 || (updated.start.x == box.minX && updated.end.x == box.maxX) {
                draft = nil
            } else {
                updated.hasFixedTextWidth = true
                let top = min(r.maxY, max(updated.start.y, r.minY + updated.bounds.height))
                draft = updated.translated(dx: 0, dy: top - updated.start.y)
            }
        case .moveMark(_, let original, let vertex):
            guard let r = selection else { return }
            if p == start { draft = original; break }
            if let vertex {
                let old = original.polygon?.vertices[vertex] ?? original.lineHandles[vertex]
                let target = CGPoint(x: old.x + (p.x - start.x), y: old.y + (p.y - start.y))
                if let shape = original.polygon {
                    if let updated = shape.movingVertex(vertex, to: target, in: r, snap: snapAngles, clippedTo: polygon) {
                        draft = original.replacingPolygon(with: updated)
                    }
                } else {
                    let clamped = CaptureLineShape.clamped(target, in: r)
                    guard polygon?.contains(clamped) != false else { return }
                    let updated = original.reshapedLine(handle: vertex, to: clamped, in: r, snap: snapAngles)
                    if polygon?.contains(updated.lineHandles[vertex]) != false { draft = updated }
                }
                break
            }
            let box = original.kind.isLine ? original.lineHandles.reduce(original.bounds) {
                $0.union(CGRect(origin: $1, size: .zero))
            } : original.bounds
            let dx = min(max(p.x - start.x, r.minX - box.minX), max(0, r.maxX - box.maxX))
            let dy = min(max(p.y - start.y, r.minY - box.minY), max(0, r.maxY - box.maxY))
            draft = original.translated(dx: dx, dy: dy)
        case .mark(let kind, let overMark):
            guard let r = selection else { return }
            if overMark != nil, hypot(p.x - start.x, p.y - start.y) < 3 * screenPoint {
                draft = nil
                break
            }
            let end = CaptureLineShape.point(p, from: start, in: r, snap: kind.isLine && snapAngles)
            draft = CaptureMark(kind: kind, start: start, end: end,
                                stroke: kind.usesStroke ? drawingStroke : AnnotationStroke(),
                                fillColor: kind == .cover ? coverColor : .black,
                                customLineStyle: kind.isLine ? activeLineStyle : nil,
                                lineShape: activeLineMode == .curve ? .curve(from: start, to: end, in: r) : nil)
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        snapAngles = event.modifierFlags.contains(.shift)
        updateDrag(to: point(event))
    }

    func nudgePointer(to point: CGPoint, systemPosition: CGPoint) {
        keyboardPointer = (point, systemPosition)
        showKeyboardCursor(at: point)
        if drag != nil {
            if case .select = drag { nudgedWhileSelecting = nudgedWhileSelecting || pointer != point }
            updateDrag(to: point)
            return
        }
        hover(at: point)
    }

    private func showKeyboardCursor(at point: CGPoint) {
        guard let layer else { return }
        let style = cursor(at: point)
        if keyboardCursorStyle !== style {
            let backingScale = window?.backingScaleFactor ?? 1
            guard let image = CaptureCursorImage(cursor: style, magnification: keyboardCursorScale, backingScale: backingScale) else {
                restoreSystemCursor()
                return
            }
            let cursorLayer = keyboardCursorLayer ?? CALayer()
            cursorLayer.zPosition = 1
            cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "anchorPoint": NSNull(), "contents": NSNull()]
            cursorLayer.contentsScale = backingScale
            cursorLayer.magnificationFilter = .nearest
            cursorLayer.bounds = CGRect(origin: .zero, size: image.size)
            cursorLayer.anchorPoint = image.anchor
            cursorLayer.contents = image.bitmap
            if keyboardCursorLayer == nil {
                layer.addSublayer(cursorLayer)
                if let window, window.screen?.frame.intersects(window.frame) == true {
                    NSCursor.hide()
                    hidSystemCursor = true
                }
            }
            keyboardCursorLayer = cursorLayer
            keyboardCursorStyle = style
        }
        if let cursorLayer = keyboardCursorLayer {
            let offset = CGPoint(x: cursorLayer.anchorPoint.x * cursorLayer.bounds.width,
                                 y: cursorLayer.anchorPoint.y * cursorLayer.bounds.height)
            let backing = convertToBacking(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
            let origin = convertFromBacking(CGPoint(x: backing.x.rounded(), y: backing.y.rounded()))
            cursorLayer.position = CGPoint(x: origin.x + offset.x, y: origin.y + offset.y)
        }
    }

    func restoreSystemCursor() {
        keyboardCursorLayer?.removeFromSuperlayer()
        keyboardCursorLayer = nil
        keyboardCursorStyle = nil
        if hidSystemCursor {
            NSCursor.unhide()
            hidSystemCursor = false
        }
    }

    func endKeyboardPointer() {
        keyboardPointer = nil
        restoreSystemCursor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDirectionRepeat()
            endKeyboardPointer()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        let p = point(event)
        snapAngles = event.modifierFlags.contains(.shift)
        updateDrag(to: p)
        switch drag {
        case .select:
            if !nudgedWhileSelecting, hypot(p.x - start.x, p.y - start.y) < 3 {
                selection = windowRects.first(where: { $0.contains(start) }) ?? bounds
            }
            if selection?.isEmpty == true { selection = nil }
        case .mark(_, let overMark):
            if let draft, draft.start != draft.end {
                annotations.change { $0.append(draft) }
                selectedMark = marks.indices.last
            } else if let overMark {
                selectedMark = overMark
            }
        case .moveMark(let index, _, _), .resizeTextBox(let index, _, _):
            if let draft { annotations.change { $0[index] = draft } }
        case .moveSelectionVertex(_, let original), .move(_, .some(let original)):
            if let polygon { annotations.recordPolygonChange(from: original, to: polygon) }
        default: break
        }
        self.drag = nil
        nudgedWhileSelecting = false
        draft = nil
        refresh()
        cursor(at: p).set()
        if mode == .text, selection != nil { onCopy?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !polylineNodes.isEmpty { finishPolyline() }
        else if anchorPoints != nil { endAnchors(); refresh() }
        else if !isDocument { onCancel?() }
    }

    func restoreRegion(_ rect: CGRect, polygon: CapturePolygon? = nil) {
        clearSelection()
        self.polygon = polygon
        selection = polygon?.bounds ?? rect.intersection(photo.bounds)
        refresh()
    }

    private func beginText(_ mark: CaptureMark, index: Int?) {
        editingMark = mark
        editingIndex = index
        selectedMark = index
        let input = AnnotationTextInput(frame: .zero)
        input.allowsManualLineBreak = mark.kind == .text
        input.isRichText = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.textContainerInset = CaptureMark.textInset
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = false
        if mark.kind == .number {
            input.string = String(mark.number)
            input.textContainer?.maximumNumberOfLines = 1
            input.textContainer?.lineBreakMode = .byClipping
            input.setAccessibilityLabel(mark.kind.title)
        } else {
            input.string = mark.text
        }
        updateTextAppearance(input, mark: mark)
        input.delegate = self
        input.wantsLayer = true
        input.layer?.borderWidth = 1
        input.layer?.borderColor = NSColor.systemBlue.cgColor
        input.finish = { [weak self] commit in self?.finishText(commit: commit) }
        textInput = input
        addSubview(input, positioned: .below, relativeTo: isDocument ? nil : toolbar)
        fitTextInput()
        window?.makeFirstResponder(input)
        let length = input.string.utf16.count
        input.setSelectedRange(mark.kind == .number ? NSRange(location: 0, length: length)
                                                    : NSRange(location: length, length: 0))
        refresh()
    }

    func textDidChange(_ notification: Notification) { fitTextInput() }

    private func updateTextAppearance(_ input: NSTextView, mark: CaptureMark) {
        let foreground = NSColor(cgColor: mark.lettering.color.ink) ?? .black
        input.font = mark.annotationFont
        input.textColor = foreground
        input.backgroundColor = NSColor(cgColor: mark.lettering.color.contrastingInk) ?? .white
        input.drawsBackground = mark.kind == .number || mark.textFormat.showsBackground
        input.insertionPointColor = foreground
        let alignment: NSTextAlignment = mark.kind == .number ? .center : mark.textFormat.alignment.appKitAlignment
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        input.defaultParagraphStyle = paragraph
        input.alignment = alignment
    }

    private func fitTextInput() {
        guard let input = textInput, var mark = editingMark, let selection else { return }
        if mark.kind == .number {
            let font = input.font ?? .systemFont(ofSize: mark.lettering.size.points)
            let textWidth = ceil((input.string as NSString).size(withAttributes: [.font: font]).width)
            let width = min(selection.width, max(56, textWidth + 2 * input.textContainerInset.width + 4))
            let height = min(selection.height, max(30, ceil(font.ascender - font.descender + font.leading)
                                                   + 2 * input.textContainerInset.height))
            input.frame = CGRect(x: min(max(mark.start.x - width / 2, selection.minX), selection.maxX - width),
                                 y: min(max(mark.start.y - height / 2, selection.minY), selection.maxY - height),
                                 width: width, height: height)
            return
        }
        mark.text = input.string
        let height = min(selection.height, max(30, mark.bounds.height + 4))
        input.frame = CGRect(x: mark.start.x, y: min(selection.maxY - height, max(selection.minY, mark.start.y - height)),
                             width: max(1, mark.end.x - mark.start.x), height: height)
    }

    private func fitAnnotation(_ mark: CaptureMark) -> CaptureMark {
        guard let selection else { return mark }
        let box = mark.bounds
        let x = max(selection.minX, min(box.minX, selection.maxX - box.width))
        let y = max(selection.minY, min(box.minY, selection.maxY - box.height))
        return mark.translated(dx: x - box.minX, dy: y - box.minY)
    }

    @discardableResult
    func finishText(commit: Bool) -> Bool {
        guard let input = textInput, var mark = editingMark else { return true }
        let index = editingIndex
        if commit {
            input.unmarkText()
            if mark.kind == .number {
                let value = input.string.folding(options: .widthInsensitive, locale: nil)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let number = Int(value), number > 0 else {
                    NSSound.beep()
                    window?.makeFirstResponder(input)
                    input.selectAll(nil)
                    return false
                }
                mark.number = number
            } else {
                mark.text = input.string
            }
        }
        textInput = nil
        editingMark = nil
        editingIndex = nil
        if commit {
            if mark.kind == .number || !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mark = fitAnnotation(mark)
                if let index { annotations.change { $0[index] = mark } }
                else { annotations.change { $0.append(mark) }; selectedMark = marks.indices.last }
            } else if let index {
                annotations.removeMark(at: index)
                selectedMark = nil
            }
        }
        input.removeFromSuperview()
        window?.makeFirstResponder(self)
        refresh()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private var canScroll: Bool {
        guard !isDocument, mode == .image, polygon == nil, anchorPoints == nil, polylineNodes.isEmpty,
              marks.isEmpty, drag == nil, let selection else { return false }
        let r = photo.pixelRect(selection)
        return min(r.width, r.height) >= CGFloat(ScrollStitcher.minimumSide)
            && r.height <= CGFloat(ScrollStitcher.heightLimit) && r.width * r.height <= CGFloat(ScrollStitcher.pixelLimit)
    }

    private var redactionCandidates: [CGRect] {
        guard case .ready(let boxes) = redaction else { return [] }
        let covers = marks.filter { $0.kind == .cover }.map(\.bounds)
        return boxes.filter { box in !covers.contains { $0.contains(box) } }
    }

    private var redactionStatus: String? {
        switch redaction {
        case nil: return nil
        case .scanning: return L("正在查找手机号和邮箱…")
        case .failed: return L("识别失败 · 可手动遮挡")
        case .ready(let boxes):
            if boxes.isEmpty { return L("未发现可能的手机号或邮箱") }
            let remaining = redactionCandidates.count
            return remaining == 0 ? L("已处理所有提示") : L("点橙框遮挡 · %ld 处待确认", remaining)
        }
    }

    private func redactionCandidate(at point: CGPoint) -> CGRect? {
        redactionCandidates.first { $0.contains(point) }
    }

    private func stopRedaction() {
        redactionScan?.cancel()
        redactionScan = nil
        redaction = nil
    }

    private func toggleRedaction() {
        if redaction != nil {
            stopRedaction()
            return
        }
        guard !isDocument, mode == .image, drag == nil, let selection else { return }
        tool = nil
        selectedMark = nil
        selectedAnchor = nil
        let pixels = photo.pixelRect(selection)
        let regionImage = polygon == nil ? photo.image.cropping(to: pixels) : photo.render(selection, marks: [], polygon: polygon)
        guard !pixels.isEmpty, let image = regionImage else {
            redaction = .failed
            return
        }
        // 裁切会外扩到整数像素，按实际裁切范围换算识别框。
        let crop = photo.pointRect(pixels)
        let transform = CGAffineTransform(translationX: crop.minX, y: crop.minY)
            .scaledBy(x: crop.width / CGFloat(image.width), y: crop.height / CGFloat(image.height))
        let token = UUID()
        redaction = .scanning(token)
        let scan = DispatchWorkItem { [weak self] in
            let boxes = try? CaptureRedaction.recognize(in: image).map { $0.applying(transform) }
            DispatchQueue.main.async { [weak self] in
                self?.finishRedaction(boxes, token: token)
            }
        }
        redactionScan = scan
        CaptureRedaction.queue.async(execute: scan)
    }

    private func finishRedaction(_ boxes: [CGRect]?, token: UUID) {
        guard case .scanning(let activeToken) = redaction, activeToken == token else { return }
        redactionScan = nil
        redaction = boxes.map(Redaction.ready) ?? .failed
        refresh()
    }

    private func perform(_ action: CaptureToolbar.Action) {
        if heldDirection?.originalPolygon != nil { stopDirectionRepeat() }
        if case .cancel = action, editingMark?.kind == .number {
            finishText(commit: false)
        } else if !finishText(commit: true) {
            return
        }
        if !polylineNodes.isEmpty {
            switch action {
            case .undo: polylineNodes.removeLast(); refresh(); return
            case .cancel: polylineNodes.removeAll(); refresh(); return
            case .redo, .scroll: return
            default: finishPolyline()
            }
        }
        if isPlacingPolygonMark {
            switch action {
            case .undo: removeLastAnchor(); return
            case .redo, .copy, .save, .pin, .scroll: return
            case .cancel, .tool(.polygon): endAnchors(); refresh(); return
            default: endAnchors()
            }
        }
        switch action {
        case .select: stopRedaction(); tool = nil
        case .anchors:
            if let onChooseAnchorMode { onChooseAnchorMode() } else { beginAnchors() }
            return
        case .tool(.polygon):
            guard mode == .image, selection != nil, drag == nil else { return }
            stopRedaction()
            selectedMark = nil
            selectedAnchor = nil
            tool = .polygon
            anchorPoints = []
            anchorPointer = nil
            onPolygonMarkPlacementChanged?(true)
        case .tool(let kind):
            stopRedaction()
            selectedAnchor = nil
            tool = tool == kind ? nil : kind
        case .style, .lineEnds, .arrowHead: return
        case .redact: toggleRedaction()
        case .undo: restoreEdit(annotations.undo())
        case .redo: restoreEdit(annotations.redo())
        case .copy: onCopy?(); return
        case .scroll:
            if canScroll { onScrollCapture?() }
            return
        case .pin: onPin?(); return
        case .save: onSave?(); return
        case .cancel: onCancel?(); return
        }
        refresh()
        window?.makeFirstResponder(self)
    }

    private func restoreEdit(_ shape: CapturePolygon?) {
        if let shape { setSelectionPolygon(shape) }
        selectedAnchor = nil
        selectedMark = nil
    }

    func handleKey(_ event: NSEvent) -> Bool {
        if isEditingText { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if handleDirectionKey(event, modifiers: mods) { return true }
        if heldDirection?.originalPolygon != nil { stopDirectionRepeat() }
        if event.isARepeat && mods.isEmpty {
            if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter { return true }
            if event.keyCode == KeyCode.p && !isDocument && mode == .image { return true }
        }
        if !polylineNodes.isEmpty {
            switch (event.keyCode, mods) {
            case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []): finishPolyline()
            case (KeyCode.escape, []): perform(.cancel)
            case (KeyCode.backspace, []), (KeyCode.forwardDelete, []), (KeyCode.z, .command), (KeyCode.z, .control): perform(.undo)
            case (KeyCode.c, .command), (KeyCode.c, .control):
                if !isDocument { perform(.copy) }
            case (KeyCode.s, .command), (KeyCode.s, .control):
                if !isDocument { perform(.save) }
            case (KeyCode.f3, []) where !isDocument: perform(.pin)
            default: break
            }
            return true
        }
        if anchorPoints != nil {
            switch (event.keyCode, mods) {
            case (KeyCode.escape, []): endAnchors(); refresh()
            case (KeyCode.p, []) where !isPlacingPolygonMark: endAnchors(); refresh()
            case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []),
                 (KeyCode.returnKey, .shift), (KeyCode.keypadEnter, .shift): closeAnchors()
            case (KeyCode.backspace, []), (KeyCode.forwardDelete, []), (KeyCode.z, .command), (KeyCode.z, .control):
                removeLastAnchor()
            default: break
            }
            return true
        }
        switch (event.keyCode, mods) {
        case (KeyCode.p, []) where !isDocument && mode == .image && marks.isEmpty && drag == nil: perform(.anchors)
        case (KeyCode.escape, []):
            switch drag {
            case .moveSelectionVertex(_, let original):
                setSelectionPolygon(original)
                drag = nil
                refresh()
            case .mark(let kind, _) where kind.isLine:
                drag = nil; draft = nil; refresh()
            case .moveMark(_, let mark, _) where mark.kind.isLine:
                drag = nil; draft = nil; refresh()
            case .resizeTextBox:
                drag = nil; draft = nil; refresh()
            default: onCancel?()
            }
        case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []):
            if selection == nil, let hovered { selection = hovered }
            if selection != nil, drag == nil { onCopy?() }
        case (KeyCode.c, []) where !isDocument && mode == .image:
            if !event.isARepeat, drag == nil { onCopyColor?() }
        case (KeyCode.c, .command), (KeyCode.c, .control):
            guard !isDocument else { return false }
            if selection != nil, drag == nil { onCopy?() }
        case (KeyCode.s, .command), (KeyCode.s, .control):
            guard !isDocument else { return false }
            if mode == .image, selection != nil, drag == nil { onSave?() }
        case (KeyCode.l, .command), (KeyCode.l, .control):
            guard !isDocument else { return false }
            if canScroll { onScrollCapture?() }
        case (KeyCode.f3, []):
            guard !isDocument else { return false }
            if mode == .image, selection != nil, drag == nil { onPin?() }
        case (KeyCode.r, []) where !isDocument && mode == .image && marks.isEmpty && drag == nil:
            onRestoreRegion?()
        case (KeyCode.backspace, []), (KeyCode.forwardDelete, []):
            guard drag == nil, !event.isARepeat else { break }
            if case .curveControl = selectedAnchor { break }
            if case .region(let vertex) = selectedAnchor, let polygon = editableSelectionPolygon {
                guard let updated = polygon.removingVertex(vertex) else { NSSound.beep(); break }
                selectedAnchor = nil
                setSelectionPolygon(updated)
                annotations.recordPolygonChange(from: polygon, to: updated)
                refresh()
            } else if let vertex = selectedAnnotationNode, let index = selectedMark,
                      let mark = selectedAnnotation ?? editableLine {
                guard let updated = mark.removingNode(at: vertex) else { NSSound.beep(); break }
                selectedAnchor = nil
                annotations.change { $0[index] = updated }
                refresh()
            } else if let i = selectedMark, marks.indices.contains(i) {
                annotations.removeMark(at: i)
                selectedMark = nil
                refresh()
            }
        case (KeyCode.z, [.command, .shift]), (KeyCode.z, [.control, .shift]), (KeyCode.y, .control):
            if drag == nil { perform(.redo) }
        case (KeyCode.z, .command), (KeyCode.z, .control):
            if drag == nil { perform(.undo) }
        default: return false
        }
        return true
    }

    private static let directionKeys: [CGKeyCode: (dx: Int, dy: Int, arrow: Bool)] = [
        KeyCode.leftArrow: (-1, 0, true), KeyCode.rightArrow: (1, 0, true),
        KeyCode.upArrow: (0, 1, true), KeyCode.downArrow: (0, -1, true),
        KeyCode.a: (-1, 0, false), KeyCode.d: (1, 0, false),
        KeyCode.w: (0, 1, false), KeyCode.s: (0, -1, false),
    ]

    private func handleDirectionKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        let key = event.keyCode
        guard !isDocument, modifiers.isEmpty || modifiers == .shift, let direction = Self.directionKeys[key],
              (direction.arrow && selection != nil && drag == nil && anchorPoints == nil && polylineNodes.isEmpty)
              || (mode == .image && onNudgePointer != nil) else { return false }
        // 单按立即走一步。长按用显示帧驱动，忽略系统的自动连发。
        guard !event.isARepeat, heldDirection?.key != key else { return true }
        stopDirectionRepeat()
        heldDirection = (key, modifiers, CACurrentMediaTime() + 0.16, nil)
        moveDirection(key, modifiers: modifiers)
        if let window, window.isVisible {
            let link = window.displayLink(target: self, selector: #selector(directionFrame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            directionLink = link
            link.add(to: .main, forMode: .common)
        } else { stopDirectionRepeat() }
        return true
    }

    @objc private func directionFrame(_ link: CADisplayLink) {
        advanceDirectionRepeat(at: link.targetTimestamp)
    }

    func advanceDirectionRepeat(at time: CFTimeInterval) {
        guard let heldDirection, time >= heldDirection.startsAt, !isEditingText else { return }
        moveDirection(heldDirection.key, modifiers: heldDirection.modifiers)
    }

    func releaseDirectionKey(_ event: NSEvent) {
        if event.keyCode == heldDirection?.key { stopDirectionRepeat() }
    }

    func updateDirectionModifiers(_ event: NSEvent) {
        updateAngleSnapping(event)
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty || mods == .shift { heldDirection?.modifiers = mods }
        else { stopDirectionRepeat() }
    }

    override func flagsChanged(with event: NSEvent) {
        updateAngleSnapping(event)
        super.flagsChanged(with: event)
    }

    private func updateAngleSnapping(_ event: NSEvent) {
        let snap = event.modifierFlags.contains(.shift)
        guard snapAngles != snap else { return }
        snapAngles = snap
        if let pointer, drag != nil { updateDrag(to: pointer) }
        else if anchorPoints != nil || !polylineNodes.isEmpty { needsDisplay = true }
    }

    func stopDirectionRepeat() {
        let originalPolygon = heldDirection?.originalPolygon
        heldDirection = nil
        directionLink?.invalidate()
        directionLink = nil
        if let originalPolygon, let polygon, originalPolygon != polygon {
            annotations.recordPolygonChange(from: originalPolygon, to: polygon)
            refresh()
        }
    }

    private func moveDirection(_ key: CGKeyCode, modifiers: NSEvent.ModifierFlags) {
        guard let (dx, dy, arrow) = Self.directionKeys[key] else { return }
        let shift = modifiers == .shift
        if arrow, let rect = selection, drag == nil, anchorPoints == nil, polylineNodes.isEmpty {
            let adjusted = photo.adjusted(rect, dx: dx, dy: dy, resize: shift)
            if let polygon {
                guard !shift else { return }
                let old = photo.pointRect(photo.pixelRect(rect))
                let dx = adjusted.minX - old.minX, dy = adjusted.minY - old.minY
                guard dx != 0 || dy != 0 else { return }
                if heldDirection?.originalPolygon == nil { heldDirection?.originalPolygon = polygon }
                setSelectionPolygon(polygon.offsetBy(dx: dx, dy: dy))
            } else {
                selection = adjusted
            }
            refresh()
        } else {
            guard mode == .image else { return }
            let step = shift ? 10 : 1
            onNudgePointer?(dx * step, dy * step)
        }
    }
}
