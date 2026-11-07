// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class CaptureCanvas: NSView, NSTextViewDelegate {
    let photo: CaptureImage
    let mode: CaptureMode
    let windowRects: [CGRect]
    private(set) var selection: CGRect?
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
    private var tracking: NSTrackingArea?

    /// 坐标是各边相对选区的位置（0、0.5 或 1）。
    private static let handles = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 1)
    ]
    private enum Drag {
        case select, move(CGRect), resize(CGRect, CGPoint), mark(CaptureMark.Kind), moveMark(Int, CaptureMark)
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

    init(photo: CaptureImage, mode: CaptureMode, windowRects: [CGRect], document: CaptureAnnotations? = nil, canRestore: Bool = false) {
        isDocument = document != nil
        annotations = document ?? CaptureAnnotations()
        toolbar = CaptureToolbar(document: document != nil)
        self.photo = photo
        self.mode = mode
        self.windowRects = windowRects
        super.init(frame: photo.bounds)
        var text = mode == .text ? L("拖选文字或点选窗口，松开即复制 · Esc 取消") : L("拖选区域或点选窗口 · Esc 取消")
        if canRestore, mode == .image { text += L(" · R 恢复上次选区") }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        hint.layer?.cornerRadius = 8
        let width = min(bounds.width - 32, ceil(label.intrinsicContentSize.width) + 8)
        let height = label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 200)).height ?? 20
        label.frame = CGRect(x: 12, y: 6, width: width, height: height).integral
        hint.frame = CGRect(x: (bounds.width - width - 24) / 2, y: bounds.maxY - height - 60,
                            width: width + 24, height: height + 12).integral
        hint.addSubview(label)
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
        if isDocument { refresh() }
        setAccessibilityLabel(mode.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target?.isDescendant(of: hint) == true || target === hint || target === dimensions ? self : target
    }

    func clearSelection() {
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
        hint.isHidden = selection != nil || drag != nil
        toolbar.isHidden = !isDocument && (mode == .text || selection == nil || drag != nil)
        if !isDocument, let rect = selection {
            toolbar.fit(within: bounds.width - 12)
            let size = toolbar.frame.size, gap: CGFloat = 10
            let x = max(6, min(rect.maxX - size.width, bounds.maxX - size.width - 6))
            var y = rect.minY - size.height - gap
            if y < 6 { y = min(rect.maxY + gap, bounds.maxY - size.height - 6) }
            toolbar.setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
            let px = photo.pixelRect(rect)
            dimensions.stringValue = "\(Int(px.width)) × \(Int(px.height)) px"
            dimensions.sizeToFit()
            let w = dimensions.frame.width + 12, h = dimensions.frame.height + 4
            var labelY = min(bounds.maxY - h - 4, rect.maxY + 6)
            if !toolbar.isHidden, toolbar.frame.intersects(CGRect(x: rect.minX, y: labelY, width: w, height: h)) {
                labelY = max(4, toolbar.frame.minY - h - 4)
            }
            dimensions.frame = CGRect(x: min(max(4, rect.minX), bounds.maxX - w - 4), y: labelY, width: w, height: h).integral
        }
        dimensions.isHidden = isDocument || selection == nil || mode == .text || isEditingText
        toolbar.update(tool: tool, canUndo: annotations.canUndo, canRedo: annotations.canRedo,
                       canScroll: canScroll, hasMarks: !marks.isEmpty)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pixels = photo.pixelRect(dirtyRect)
        if isDocument, let tile = photo.image.cropping(to: pixels) {
            ctx.draw(tile, in: photo.pointRect(pixels))
        } else { ctx.draw(photo.image, in: bounds) }
        let area = selection ?? hovered
        ctx.saveGState()
        ctx.addRect(bounds)
        if let area { ctx.addRect(area) }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.39))
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
        guard let area, !area.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: area)
        for (i, mark) in marks.enumerated() where i != editingIndex {
            if case .moveMark(let moving, _) = drag, moving == i { continue }
            if mark.bounds.insetBy(dx: -16, dy: -16).intersects(dirtyRect) { mark.draw(in: ctx) }
        }
        draft?.draw(in: ctx)
        if let i = selectedMark, marks.indices.contains(i), editingIndex == nil, drag == nil {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(marks[i].bounds.insetBy(dx: -3, dy: -3))
        }
        ctx.restoreGState()
        if isDocument { return }
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(area.insetBy(dx: 1, dy: 1))
        if selection != nil, tool == nil, drag == nil, mode == .image {
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
        guard selection == nil, drag == nil else { return }
        let rect = windowRects.first(where: { $0.contains(point) })
        if hovered != rect { hovered = rect; needsDisplay = true }
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func mouseMoved(with event: NSEvent) { hover(at: point(event)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) { cursor(at: point(event)).set() }

    /// 显示哪个缩放指针和按下后拖哪个手柄，都由同一个命中区决定。
    private func handle(at p: CGPoint, in rect: CGRect) -> CGPoint? {
        guard !isDocument, tool == nil, mode == .image else { return nil }
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

    private func cursor(at p: CGPoint) -> NSCursor {
        switch drag {
        case .move, .moveMark: return .closedHand
        case .resize(_, let h): return resizeCursor(h)
        case .select, .mark: return .crosshair
        case nil: break
        }
        if !isDocument, !toolbar.isHidden, toolbar.frame.contains(p) { return .arrow }
        guard let selection else { return .crosshair }
        if let h = handle(at: p, in: selection) { return resizeCursor(h) }
        guard selection.contains(p) else { return .crosshair }
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
        let hit = marks.indices.reversed().first { marks[$0].hit(start) }
        if let selection, selection.contains(start), let hit, marks[hit].kind == .text,
           event.clickCount == 2 || tool == .text {
            beginText(marks[hit], index: hit)
            return
        }
        selectedMark = nil
        if let selection, let tool, selection.contains(start) {
            switch tool {
            case .text:
                let x = min(start.x, selection.maxX - min(selection.width, 80))
                let y = max(start.y, selection.minY + min(selection.height, 30))
                beginText(CaptureMark(kind: .text, start: CGPoint(x: x, y: y),
                                      end: CGPoint(x: min(x + 360, selection.maxX), y: y)), index: nil)
                return
            case .number:
                let mark = CaptureMark(kind: .number, start: start, end: start, number: annotations.nextNumber)
                let box = mark.bounds
                let x = max(selection.minX, min(box.minX, selection.maxX - box.width))
                let y = max(selection.minY, min(box.minY, selection.maxY - box.height))
                annotations.change { $0.append(mark.translated(dx: x - box.minX, dy: y - box.minY)) }
                selectedMark = marks.indices.last
            default: drag = .mark(tool)
            }
        } else if let selection, let handle = handle(at: start, in: selection) {
            drag = .resize(selection, handle)
        } else if let selection, selection.contains(start), let hit {
            selectedMark = hit
            drag = .moveMark(hit, marks[hit])
        } else if isDocument {
            refresh()
            return
        } else if let selection, selection.contains(start) {
            drag = .move(selection)
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
        case .move(let old):
            let x = min(max(0, old.minX + p.x - start.x), bounds.width - old.width)
            let y = min(max(0, old.minY + p.y - start.y), bounds.height - old.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: old.size)
        case .resize(let old, let h):
            let dx = p.x - start.x, dy = p.y - start.y
            let x0 = h.x == 0 ? max(0, min(old.maxX - 1, old.minX + dx)) : old.minX
            let x1 = h.x == 1 ? min(bounds.maxX, max(old.minX + 1, old.maxX + dx)) : old.maxX
            let y0 = h.y == 0 ? max(0, min(old.maxY - 1, old.minY + dy)) : old.minY
            let y1 = h.y == 1 ? min(bounds.maxY, max(old.minY + 1, old.maxY + dy)) : old.maxY
            selection = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case .moveMark(_, let original):
            guard let r = selection else { return }
            if p == start { draft = original; break }
            let box = original.bounds
            let dx = min(max(p.x - start.x, r.minX - box.minX), max(0, r.maxX - box.maxX))
            let dy = min(max(p.y - start.y, r.minY - box.minY), max(0, r.maxY - box.maxY))
            draft = original.translated(dx: dx, dy: dy)
        case .mark(let kind):
            guard let r = selection else { return }
            let end = CGPoint(x: max(r.minX, min(r.maxX, p.x)), y: max(r.minY, min(r.maxY, p.y)))
            draft = CaptureMark(kind: kind, start: start, end: end)
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
        case .moveMark(let index, _):
            if let draft { annotations.change { $0[index] = draft } }
        default: break
        }
        self.drag = nil
        draft = nil
        refresh()
        cursor(at: p).set()
        if mode == .text, selection != nil { onCopy?() }
    }
    override func rightMouseDown(with event: NSEvent) { if !isDocument { onCancel?() } }

    func restoreRegion(_ rect: CGRect) {
        clearSelection()
        selection = rect.intersection(photo.bounds)
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
        input.font = .systemFont(ofSize: CaptureMark.fontSize)
        input.textColor = .black
        input.backgroundColor = .white
        input.insertionPointColor = .black
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
        addSubview(input)
        fitTextInput()
        window?.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        refresh()
    }

    func textDidChange(_ notification: Notification) { fitTextInput() }

    private func fitTextInput() {
        guard let input = textInput, var mark = editingMark, let selection else { return }
        mark.text = input.string + (input.string.hasSuffix("\n") ? " " : "")
        let height = min(selection.height, max(30, mark.bounds.height + 4))
        input.frame = CGRect(x: mark.start.x, y: max(selection.minY, mark.start.y - height),
                             width: max(1, mark.end.x - mark.start.x), height: height)
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
                if let selection, mark.bounds.minY < selection.minY {
                    mark = mark.translated(dx: 0, dy: min(selection.maxY - mark.start.y, selection.minY - mark.bounds.minY))
                }
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
        guard !isDocument, mode == .image, marks.isEmpty, drag == nil, let selection else { return false }
        let r = photo.pixelRect(selection)
        return min(r.width, r.height) >= CGFloat(ScrollStitcher.minimumSide)
            && r.height <= CGFloat(ScrollStitcher.heightLimit) && r.width * r.height <= CGFloat(ScrollStitcher.pixelLimit)
    }

    private func perform(_ action: CaptureToolbar.Action) {
        finishText(commit: true)
        switch action {
        case .select: tool = nil
        case .tool(let kind): tool = tool == kind ? nil : kind
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
        switch (event.keyCode, mods) {
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
            selection = photo.adjusted(rect, dx: delta.0, dy: delta.1, resize: mods == .shift)
            refresh()
        }
        return true
    }
}
