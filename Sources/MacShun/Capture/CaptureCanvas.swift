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
    private var anchorPoints: [CGPoint]?
    private var anchorPointer: CGPoint?
    private var drawingStroke = AnnotationStroke()
    private var textStyle = AnnotationLettering(color: .black)
    private var numberStyle = AnnotationLettering(color: .red)
    private var coverColor: AnnotationColor = .black
    var isPlacingPolygonMark: Bool { anchorPoints != nil && tool == .polygon }
    private var anchorHint: String {
        L("点击添加锚点 · 点首点或按 Enter 闭合 · Delete 撤回 · Esc 退出")
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
    private enum Drag {
        case select, move(CGRect, CapturePolygon?), resize(CGRect, CGPoint), mark(CaptureMark.Kind)
        case moveMark(Int, CaptureMark, vertex: Int? = nil)
    }
    private var drag: Drag?
    private var start = CGPoint.zero
    private var draft: CaptureMark?
    var onChooseDisplay: (() -> Void)?
    var onCopy: (() -> Void)?
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
        self.photo = photo
        self.mode = mode
        self.windowRects = windowRects
        var text = mode == .text ? L("拖选文字或点选窗口，松开即复制 · Esc 取消") : L("拖选区域或点选窗口 · P 锚点选区 · Esc 取消")
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
            addSubview(hint)
            addSubview(dimensions)
            addSubview(toolbar)
        }
        toolbar.isHidden = !isDocument
        toolbar.perform = { [weak self] action in self?.perform(action) }
        toolbar.changeStyle = { [weak self] style in self?.changeAnnotationStyle(style) }
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

    func clearSelection() {
        endAnchors()
        polygon = nil
        selection = nil
        finishText(commit: false)
        annotations = CaptureAnnotations()
        selectedMark = nil
        draft = nil
        tool = nil
        drag = nil
        hovered = nil
        refresh()
    }

    private func refresh() {
        let placingAnchors = anchorPoints != nil
        var dimensionsFit = false
        hint.isHidden = isPlacingPolygonMark || (!placingAnchors && (selection != nil || drag != nil))
        toolbar.isHidden = !isDocument && (mode == .text || selection == nil || drag != nil || (placingAnchors && !isPlacingPolygonMark))
        toolbar.update(tool: tool, canUndo: annotations.canUndo, canRedo: annotations.canRedo,
                       canScroll: canScroll, hasMarks: !marks.isEmpty, redactionStatus: redactionStatus, hasPolygon: polygon != nil,
                       anchorStatus: isPlacingPolygonMark ? anchorHint : nil,
                       canRemoveAnchor: anchorPoints?.isEmpty == false,
                       style: activeAnnotationStyle,
                       styleOnly: !isDocument && isPlacingPolygonMark)
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
            let toolbarWithGap = toolbar.frame.insetBy(dx: -4, dy: -4)
            let labelSize = CGSize(width: w, height: h)
            if let frame = labelOrigins.map({ CGRect(origin: $0, size: labelSize).integral }).first(where: {
                bounds.insetBy(dx: 4, dy: 4).contains($0) && (toolbar.isHidden || !toolbarWithGap.intersects($0))
            }) {
                dimensions.frame = frame
                dimensionsFit = true
            }
        }
        dimensions.isHidden = !dimensionsFit || mode == .text || isEditingText || redaction != nil || anchorPoints != nil
        needsDisplay = true
    }

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
        for (i, mark) in marks.enumerated() where i != editingIndex {
            if case .moveMark(let moving, _, _) = drag, moving == i, draft != nil { continue }
            if mark.selectionBounds.intersects(dirtyRect) { mark.draw(in: ctx) }
        }
        draft?.draw(in: ctx)
        if let anchorPoints {
            drawAnchors(anchorPoints, in: ctx)
        } else if let selectedPolygon = draft?.polygon ?? selectedAnnotation?.polygon {
            drawVertices(selectedPolygon.vertices, color: NSColor.systemBlue.cgColor, in: ctx)
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
        if let anchorPointer { ctx.addLine(to: canCloseAnchors(at: anchorPointer) ? first : anchorPointer) }
        ctx.strokePath()
        drawVertices(points, color: handleColor, in: ctx, placing: true)
    }

    private func drawVertices(_ points: [CGPoint], color: CGColor, in ctx: CGContext, placing: Bool = false) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color)
        let scale = screenPoint
        ctx.setLineWidth(1.5 * scale)
        for (index, point) in points.enumerated() {
            let first = placing && index == 0
            let radius = (first ? 5 : 3.5) * scale
            let active = first && anchorPointer.map { canCloseAnchors(at: $0) } == true
            let box = CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
            ctx.setFillColor(active ? color : NSColor.white.cgColor)
            ctx.fillEllipse(in: box)
            ctx.strokeEllipse(in: box)
        }
    }

    func beginAnchors() {
        guard !isDocument, mode == .image, marks.isEmpty, drag == nil else { return }
        stopRedaction()
        selectedMark = nil
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
            polygon = result
            selection = result.bounds
        }
        refresh()
    }

    private func removeLastAnchor() {
        if anchorPoints?.isEmpty == false { anchorPoints?.removeLast() }
        refresh()
    }

    private func containsSelection(_ point: CGPoint) -> Bool {
        polygon?.contains(point) ?? (selection?.contains(point) == true)
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
        if bounds.contains(point) { cursor(at: point).set() }
        if anchorPoints != nil {
            anchorPointer = !isPlacingPolygonMark || containsSelection(point) ? point : nil
            needsDisplay = true
            return
        }
        guard selection == nil, drag == nil else { return }
        let rect = windowRects.first(where: { $0.contains(point) })
        if hovered != rect { hovered = rect; needsDisplay = true }
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func mouseMoved(with event: NSEvent) { hover(at: point(event)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; anchorPointer = nil; needsDisplay = true }
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
        if tool == .text { return .lettering(textStyle) }
        if tool == .number { return .lettering(numberStyle) }
        if tool == .cover { return .fill(coverColor) }
        return selectedAnnotation?.style
    }

    private func changeAnnotationStyle(_ style: AnnotationStyle) {
        guard drag == nil, activeAnnotationStyle != nil else { return }
        switch style {
        case .stroke(let stroke):
            drawingStroke = stroke
            if selectedAnnotation?.kind.usesStroke == true, let selectedMark {
                annotations.change { $0[selectedMark].stroke = stroke }
            }
        case .lettering(let lettering):
            if let input = textInput, var mark = editingMark {
                mark.letteringStyle = lettering
                editingMark = mark
                if editingIndex == nil { textStyle = lettering }
                updateTextAppearance(input, lettering: lettering)
                fitTextInput()
            } else if let mark = selectedAnnotation, mark.kind.usesLettering, let selectedMark, mark.lettering != lettering {
                var updated = mark
                updated.letteringStyle = lettering
                let fitted = fitAnnotation(updated)
                annotations.change { $0[selectedMark] = fitted }
            } else if tool == .text {
                textStyle = lettering
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

    private func vertex(at point: CGPoint) -> Int? {
        guard let vertices = selectedAnnotation?.polygon?.vertices else { return nil }
        let radius = 7 * screenPoint
        return vertices.enumerated().map { (index, vertex) in (index, hypot(vertex.x - point.x, vertex.y - point.y)) }
            .filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        if !isDocument, !toolbar.isHidden, toolbar.frame.contains(p), toolbar.hitTest(p) != nil { return .arrow }
        if anchorPoints != nil { return canCloseAnchors(at: p) ? .pointingHand : .crosshair }
        switch drag {
        case .move, .moveMark: return .closedHand
        case .resize(_, let h): return resizeCursor(h)
        case .select, .mark: return .crosshair
        case nil: break
        }
        guard let selection else { return .crosshair }
        if redaction != nil { return redactionCandidate(at: p) == nil ? .arrow : .pointingHand }
        if vertex(at: p) != nil { return .openHand }
        if let h = handle(at: p, in: selection) { return resizeCursor(h) }
        guard containsSelection(p) else { return .crosshair }
        if tool == .text || textInput?.frame.contains(p) == true { return .iBeam }
        if tool != nil { return .crosshair }
        return !isDocument || marks.contains { $0.hit(p) } ? .openHand : .arrow
    }

    override func mouseDown(with event: NSEvent) {
        onChooseDisplay?()
        finishText(commit: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = point(event)
        if let anchorPoints {
            if canCloseAnchors(at: start) {
                closeAnchors()
            } else if bounds.contains(start), (!isPlacingPolygonMark || containsSelection(start)),
                      !anchorPoints.contains(start) {
                self.anchorPoints?.append(start)
                anchorPointer = start
                refresh()
            }
            cursor(at: start).set()
            return
        }
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
        if let index = selectedMark, let vertex = vertex(at: start) {
            drag = .moveMark(index, marks[index], vertex: vertex)
            refresh()
            cursor(at: start).set()
            return
        }
        let hit = marks.indices.reversed().first { marks[$0].hit(start) }
        if containsSelection(start), let hit, marks[hit].kind == .text,
           event.clickCount == 2 || tool == .text {
            beginText(marks[hit], index: hit)
            return
        }
        selectedMark = nil
        if let selection, let tool, containsSelection(start) {
            switch tool {
            case .text:
                let x = min(start.x, selection.maxX - min(selection.width, 80))
                let y = max(start.y, selection.minY + min(selection.height, 30))
                beginText(CaptureMark(kind: .text, start: CGPoint(x: x, y: y),
                                      end: CGPoint(x: min(x + 360, selection.maxX), y: y),
                                      letteringStyle: textStyle), index: nil)
                return
            case .number:
                let mark = fitAnnotation(CaptureMark(kind: .number, start: start, end: start,
                                                     number: annotations.nextNumber, letteringStyle: numberStyle))
                annotations.change { $0.append(mark) }
                selectedMark = marks.indices.last
            default: drag = .mark(tool)
            }
        } else if let selection, let handle = handle(at: start, in: selection) {
            drag = .resize(selection, handle)
        } else if containsSelection(start), let hit {
            selectedMark = hit
            drag = .moveMark(hit, marks[hit])
        } else if isDocument {
            refresh()
            return
        } else if let selection, containsSelection(start) {
            drag = .move(selection, polygon)
        } else {
            clearSelection()
            drag = .select
        }
        refresh()
        cursor(at: start).set()
    }

    private func updateDrag(to raw: CGPoint) {
        guard let drag else { return }
        let p = CGPoint(x: min(max(0, raw.x), bounds.width), y: min(max(0, raw.y), bounds.height))
        switch drag {
        case .select:
            selection = CaptureImage.rect(from: start, to: p)
        case .move(let old, let oldPolygon):
            let x = min(max(0, old.minX + p.x - start.x), bounds.width - old.width)
            let y = min(max(0, old.minY + p.y - start.y), bounds.height - old.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: old.size)
            polygon = oldPolygon?.offsetBy(dx: x - old.minX, dy: y - old.minY)
        case .resize(let old, let h):
            let dx = p.x - start.x, dy = p.y - start.y
            let x0 = h.x == 0 ? max(0, min(old.maxX - 1, old.minX + dx)) : old.minX
            let x1 = h.x == 1 ? min(bounds.maxX, max(old.minX + 1, old.maxX + dx)) : old.maxX
            let y0 = h.y == 0 ? max(0, min(old.maxY - 1, old.minY + dy)) : old.minY
            let y1 = h.y == 1 ? min(bounds.maxY, max(old.minY + 1, old.maxY + dy)) : old.maxY
            selection = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case .moveMark(_, let original, let vertex):
            guard let r = selection else { return }
            if p == start { draft = original; break }
            if let vertex, var vertices = original.polygon?.vertices {
                let old = vertices[vertex]
                let point = CGPoint(x: min(max(r.minX, old.x + p.x - start.x), r.maxX),
                                    y: min(max(r.minY, old.y + p.y - start.y), r.maxY))
                guard polygon?.contains(point) != false,
                      !vertices.enumerated().contains(where: { $0.offset != vertex && $0.element == point }) else { return }
                vertices[vertex] = point
                if let updated = CapturePolygon(vertices) { draft = CaptureMark(polygon: updated, stroke: original.stroke) }
                break
            }
            let box = original.bounds
            let dx = min(max(p.x - start.x, r.minX - box.minX), max(0, r.maxX - box.maxX))
            let dy = min(max(p.y - start.y, r.minY - box.minY), max(0, r.maxY - box.maxY))
            draft = original.translated(dx: dx, dy: dy)
        case .mark(let kind):
            guard let r = selection else { return }
            let end = CGPoint(x: max(r.minX, min(r.maxX, p.x)), y: max(r.minY, min(r.maxY, p.y)))
            draft = CaptureMark(kind: kind, start: start, end: end,
                                stroke: kind.usesStroke ? drawingStroke : AnnotationStroke(),
                                fillColor: kind == .cover ? coverColor : .black)
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) { updateDrag(to: point(event)) }
    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        let p = point(event)
        updateDrag(to: p)
        switch drag {
        case .select:
            if hypot(p.x - start.x, p.y - start.y) < 3 {
                selection = windowRects.first(where: { $0.contains(start) }) ?? bounds
            }
            if selection?.isEmpty == true { selection = nil }
        case .mark:
            if let draft, draft.start != draft.end {
                annotations.change { $0.append(draft) }
                selectedMark = marks.indices.last
            }
        case .moveMark(let index, _, _):
            if let draft { annotations.change { $0[index] = draft } }
        default: break
        }
        self.drag = nil
        draft = nil
        refresh()
        cursor(at: p).set()
        if mode == .text, selection != nil { onCopy?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        if anchorPoints != nil { endAnchors(); refresh() }
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
        input.isRichText = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        updateTextAppearance(input, lettering: mark.lettering)
        input.textContainerInset = CGSize(width: 5, height: 3)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = false
        input.string = mark.text
        input.delegate = self
        input.wantsLayer = true
        input.layer?.borderWidth = 1
        input.layer?.borderColor = NSColor.systemBlue.cgColor
        input.finish = { [weak self] commit in self?.finishText(commit: commit) }
        textInput = input
        addSubview(input, positioned: .below, relativeTo: isDocument ? nil : toolbar)
        fitTextInput()
        window?.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        refresh()
    }

    func textDidChange(_ notification: Notification) { fitTextInput() }

    private func updateTextAppearance(_ input: NSTextView, lettering: AnnotationLettering) {
        let foreground = NSColor(cgColor: lettering.color.ink) ?? .black
        input.font = .systemFont(ofSize: lettering.size.points)
        input.textColor = foreground
        input.backgroundColor = NSColor(cgColor: lettering.color.contrastingInk) ?? .white
        input.insertionPointColor = foreground
    }

    private func fitTextInput() {
        guard let input = textInput, var mark = editingMark, let selection else { return }
        mark.text = input.string + (input.string.hasSuffix("\n") ? " " : "")
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

    func finishText(commit: Bool) {
        guard let input = textInput, var mark = editingMark else { return }
        let index = editingIndex
        textInput = nil
        editingMark = nil
        editingIndex = nil
        if commit {
            input.unmarkText()
            mark.text = input.string
            if !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                mark = fitAnnotation(mark)
                if let index { annotations.change { $0[index] = mark } }
                else { annotations.change { $0.append(mark) }; selectedMark = marks.indices.last }
            } else if let index {
                annotations.change { $0.remove(at: index) }
                selectedMark = nil
            }
        }
        input.removeFromSuperview()
        window?.makeFirstResponder(self)
        refresh()
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private var canScroll: Bool {
        guard !isDocument, mode == .image, polygon == nil, anchorPoints == nil,
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
        finishText(commit: true)
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
            tool = .polygon
            anchorPoints = []
            anchorPointer = nil
            onPolygonMarkPlacementChanged?(true)
        case .tool(let kind): stopRedaction(); tool = tool == kind ? nil : kind
        case .style: return
        case .redact: toggleRedaction()
        case .undo: annotations.undo(); selectedMark = nil
        case .redo: annotations.redo(); selectedMark = nil
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

    func handleKey(_ event: NSEvent) -> Bool {
        if isEditingText { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.isARepeat && mods.isEmpty {
            if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter { return true }
            if event.keyCode == KeyCode.p && !isDocument && mode == .image { return true }
        }
        if anchorPoints != nil {
            switch (event.keyCode, mods) {
            case (KeyCode.escape, []): endAnchors(); refresh()
            case (KeyCode.p, []) where !isPlacingPolygonMark: endAnchors(); refresh()
            case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []): closeAnchors()
            case (KeyCode.backspace, []), (KeyCode.forwardDelete, []), (KeyCode.z, .command), (KeyCode.z, .control):
                removeLastAnchor()
            default: break
            }
            return true
        }
        switch (event.keyCode, mods) {
        case (KeyCode.p, []) where !isDocument && mode == .image && marks.isEmpty && drag == nil: perform(.anchors)
        case (KeyCode.escape, []): onCancel?()
        case (KeyCode.returnKey, []), (KeyCode.keypadEnter, []):
            if selection == nil, let hovered { selection = hovered }
            if selection != nil, drag == nil { onCopy?() }
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
            if let i = selectedMark, marks.indices.contains(i), drag == nil {
                annotations.change { $0.remove(at: i) }
                selectedMark = nil
                refresh()
            }
        case (KeyCode.z, [.command, .shift]), (KeyCode.z, [.control, .shift]), (KeyCode.y, .control):
            if drag == nil { perform(.redo) }
        case (KeyCode.z, .command), (KeyCode.z, .control):
            if drag == nil { perform(.undo) }
        default:
            guard !isDocument, let rect = selection, drag == nil, mods.isEmpty || mods == .shift else { return false }
            let delta: (Int, Int)
            switch event.keyCode {
            case KeyCode.leftArrow: delta = (-1, 0)
            case KeyCode.rightArrow: delta = (1, 0)
            case KeyCode.upArrow: delta = (0, 1)
            case KeyCode.downArrow: delta = (0, -1)
            default: return false
            }
            let adjusted = photo.adjusted(rect, dx: delta.0, dy: delta.1, resize: mods == .shift)
            if let polygon {
                guard mods.isEmpty else { return true }
                let old = photo.pointRect(photo.pixelRect(rect))
                let moved = polygon.offsetBy(dx: adjusted.minX - old.minX, dy: adjusted.minY - old.minY)
                self.polygon = moved
                selection = moved.bounds
            } else {
                selection = adjusted
            }
            refresh()
        }
        return true
    }
}
