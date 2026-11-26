// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class CaptureCanvas: NSView, NSTextViewDelegate {
    private(set) var photo: CaptureImage
    let mode: CaptureMode
    let windowRects: [CGRect]
    private(set) var windowTargets: [CaptureWindowTarget]
    private(set) var windowsOnly = false
    private var discoveredControls: [CGWindowID: [CGRect]] = [:]
    private(set) var hoverChain: [CGRect] = []
    private(set) var hoverLevel = 0
    private var wheelRemainder: CGFloat = 0
    private var parkedState: (selection: CGRect, polygon: CapturePolygon?, annotations: CaptureAnnotations)?
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
    private var highlighterStroke = AnnotationStroke(color: .orange, width: .medium)
    private var mosaicStyle = AnnotationMosaicStyle()
    private var spotlightStyle = AnnotationSpotlightStyle()
    private var lineStyle = AnnotationLineStyle()
    private var arrowStyle = AnnotationLineStyle(ends: .end)
    private var lineMode: AnnotationLineMode = .straight
    private var arrowMode: AnnotationLineMode = .straight
    private var polylineNodes: [CGPoint] = []
    private var snapAngles = false
    private var optionHeld = false
    private var textStyle = AnnotationLettering(color: .black)
    private var textFormat = AnnotationTextFormat()
    private var numberStyle = AnnotationLettering(color: .red)
    private var coverColor: AnnotationColor = .black
    private var toolbarHidden = false
    private(set) var lockedAspectRatio: CGFloat?
    private var sizePresets: [CaptureSizePreset] = CaptureSizePreset.parseList(CaptureSizePreset.defaultsString)
    private let sizePopover = CaptureSizePopoverView()
    private let keyHintsView = CaptureKeyHintsView()
    private var keyHintsPermanentlyHidden = false
    private var keyHintsSessionOverride: Bool?
    private let canRestoreHistory: Bool
    private var hasCaptureHistory = false
    var isEditingSize: Bool { !sizePopover.isHidden }
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
    var hovered: CGRect? {
        guard selection == nil, anchorPoints == nil, hoverChain.indices.contains(hoverLevel) else { return nil }
        return hoverChain[hoverLevel]
    }
    let toolbar: CaptureToolbar
    private let hint = NSView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let selectionHint: String
    private let noticeView = NSView()
    private let noticeLabel = NSTextField(labelWithString: "")
    private var noticeHideWork: DispatchWorkItem?
    private var overlayView: CaptureOverlayView?
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
    private var redactionCancelled: Locked<Bool>?

    /// 坐标是各边相对选区的位置（0、0.5 或 1）。
    private static let handles = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 1, y: 1)
    ]
    private enum TextEdge { case left, right }
    private enum Drag {
        case select
        case pendingSelect(CGRect, CapturePolygon?)
        case move(CGRect, CapturePolygon?)
        case resize(CGRect, CaptureSelectionHandle)
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
    var onCopyText: (() -> Void)?
    var onCopyColor: (() -> Void)?
    var canSampleDisplay: (() -> Bool)?
    var onNudgePointer: ((_ dx: Int, _ dy: Int) -> Void)?
    var onSave: ((_ forcePrompt: Bool) -> Void)?
    var onPin: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRestoreRegion: ((_ backward: Bool) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onToggleWindowsOnly: (() -> Void)?
    var onProbeElement: ((CaptureWindowTarget, CGPoint) -> Void)?
    var onChooseAnchorMode: (() -> Void)?
    var onPolygonMarkPlacementChanged: ((Bool) -> Void)?
    var onSizePresetsChanged: (([CaptureSizePreset]) -> Void)?
    var onKeyHintsHiddenChanged: ((Bool) -> Void)?
    var onStepCaptureHistory: ((_ older: Bool) -> Void)?

    init(photo: CaptureImage, mode: CaptureMode, windowRects: [CGRect], windowTargets: [CaptureWindowTarget] = [],
         document: CaptureAnnotations? = nil, canRestore: Bool = false) {
        isDocument = document != nil
        canRestoreHistory = canRestore
        annotations = document ?? CaptureAnnotations()
        toolbar = CaptureToolbar(document: document != nil)
        loupe = document == nil && mode == .image ? CaptureLoupe() : nil
        keyboardCursorScale = loupe == nil ? 1 : CaptureCursorImage.magnification(in: UserDefaults(suiteName: "com.apple.universalaccess"))
        self.photo = photo
        self.mode = mode
        self.windowRects = windowRects
        self.windowTargets = windowTargets.isEmpty
            ? windowRects.enumerated().map { CaptureWindowTarget.synthetic($0.element, id: CGWindowID($0.offset + 1)) }
            : windowTargets
        var text = mode == .text
            ? L("拖选文字或点选区域，松开即复制 · 滚轮切层级 · Tab 仅框窗口 · Esc 取消")
            : L("拖选或点选区域 · 滚轮切层级 · Tab 仅框窗口 · WASD 微调 · P 锚点 · Esc 取消")
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
        noticeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        noticeLabel.textColor = .white
        noticeLabel.alignment = .center
        noticeView.wantsLayer = true
        noticeView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        noticeView.layer?.cornerRadius = 8
        noticeView.isHidden = true
        noticeView.addSubview(noticeLabel)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dimensions.textColor = .white
        dimensions.alignment = .center
        dimensions.wantsLayer = true
        dimensions.layer?.cornerRadius = 5
        dimensions.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        dimensions.isHidden = true
        if isDocument { selection = photo.bounds }
        else {
            wantsLayer = true
            let overlay = CaptureOverlayView(canvas: self)
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            overlayView = overlay
            addSubview(overlay)
            addSubview(keyHintsView)
            addSubview(hint)
            addSubview(noticeView)
            addSubview(dimensions)
            addSubview(toolbar)
            if let loupe { addSubview(loupe) }
            addSubview(sizePopover)
            configureSizePopover()
            keyHintsView.onTogglePermanentHide = { [weak self] in
                guard let self else { return }
                self.keyHintsPermanentlyHidden.toggle()
                self.keyHintsSessionOverride = nil
                self.onKeyHintsHiddenChanged?(self.keyHintsPermanentlyHidden)
                self.refresh()
                self.window?.makeFirstResponder(self)
            }
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

    deinit {
        noticeHideWork?.cancel()
        redactionCancelled?.set(true)
        redactionScan?.cancel()
    }

    override var wantsUpdateLayer: Bool { !isDocument }

    override func updateLayer() {
        guard !isDocument, let layer else { return }
        if layer.contents as AnyObject? !== photo.image {
            layer.contents = photo.image
            layer.contentsGravity = .resize
        }
    }

    override var needsDisplay: Bool {
        didSet {
            if needsDisplay { overlayView?.needsDisplay = true }
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        overlayView?.setNeedsDisplay(invalidRect)
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !sizePopover.isHidden, sizePopover.frame.contains(point) {
            return sizePopover.hitTest(sizePopover.convert(point, from: superview)) ?? sizePopover
        }
        let target = super.hitTest(point)
        if target?.isDescendant(of: hint) == true || target === hint
            || target?.isDescendant(of: noticeView) == true || target === noticeView
            || target === dimensions {
            return self
        }
        return target
    }

    func setSizePresets(_ presets: [CaptureSizePreset]) {
        sizePresets = presets.isEmpty ? CaptureSizePreset.parseList(CaptureSizePreset.defaultsString) : presets
        if !sizePopover.isHidden { syncSizePopover() }
    }

    func setKeyHintsPermanentlyHidden(_ hidden: Bool) {
        keyHintsPermanentlyHidden = hidden
        refresh()
    }

    func setHasCaptureHistory(_ value: Bool) {
        guard hasCaptureHistory != value else { return }
        hasCaptureHistory = value
        refresh()
    }

    /// 切换截图历史快照（`,` / `.`）：替换当前画面并还原对应选区与标注，或回到实时冻结画面。
    func replaceSnapshot(
        photo newPhoto: CaptureImage,
        windowTargets targets: [CaptureWindowTarget],
        selection newSelection: CGRect?,
        polygon newPolygon: CapturePolygon?,
        marks newMarks: [CaptureMark],
        noticeText: String? = nil
    ) {
        guard newPhoto.size == bounds.size else { return }
        clearSelection(keepingPointer: true)
        photo = newPhoto
        windowTargets = targets
        discoveredControls.removeAll()
        if !isDocument {
            layer?.contents = newPhoto.image
        }
        if let newPolygon {
            setSelectionPolygon(newPolygon)
        } else if let newSelection {
            selection = newSelection.intersection(bounds)
        }
        if !newMarks.isEmpty {
            annotations.change { $0 = newMarks }
        }
        if selection == nil, let pointer {
            updateHoverChain(at: pointer, preserveLevel: false, triggerProbe: false)
        }
        if let noticeText { showNotice(noticeText) }
        refresh()
    }

    private func configureSizePopover() {
        sizePopover.onApplyPixelSize = { [weak self] w, h in self?.applyPixelSize(width: w, height: h) }
        sizePopover.onToggleRatioLock = { [weak self] ratio in
            guard let self else { return }
            self.lockedAspectRatio = ratio
            if let ratio, let rect = self.selection, self.polygon == nil {
                let px = self.photo.pixelRect(rect)
                let newH = max(1, Int((px.width / ratio).rounded()))
                self.applyPixelSize(width: Int(px.width), height: newH)
            }
            self.refresh()
        }
        sizePopover.onSelectPreset = { [weak self] preset in
            guard let self else { return }
            if preset.isRatio {
                self.lockedAspectRatio = preset.ratioValue
                if let rect = self.selection, self.polygon == nil {
                    let px = self.photo.pixelRect(rect)
                    let targetH = max(1, Int((px.width / preset.ratioValue).rounded()))
                    self.applyPixelSize(width: Int(px.width), height: targetH)
                } else {
                    self.showNotice(L("已锁定比例 %@ · 拖动框选", preset.displayTitle))
                }
                self.closeSizePopover(focusCanvas: true)
            } else {
                self.lockedAspectRatio = nil
                self.applyPixelSize(width: preset.width, height: preset.height)
                self.closeSizePopover(focusCanvas: true)
            }
        }
        sizePopover.onAddPreset = { [weak self] preset in
            guard let self, self.sizePresets.count < CaptureSizePreset.limit, !self.sizePresets.contains(preset) else { return }
            self.sizePresets.append(preset)
            self.onSizePresetsChanged?(self.sizePresets)
            self.syncSizePopover()
            self.refresh()
        }
        sizePopover.onRemovePreset = { [weak self] preset in
            guard let self else { return }
            self.sizePresets.removeAll { $0 == preset }
            self.onSizePresetsChanged?(self.sizePresets)
            self.syncSizePopover()
            self.refresh()
        }
        sizePopover.onClose = { [weak self] in self?.closeSizePopover(focusCanvas: true) }
    }

    func openSizePopover() {
        guard !isDocument, mode == .image, drag == nil, anchorPoints == nil, polylineNodes.isEmpty else { return }
        finishText(commit: true)
        stopRedaction()
        syncSizePopover()
        sizePopover.isHidden = false
        refresh()
        sizePopover.focusWidthField()
    }

    func closeSizePopover(focusCanvas: Bool) {
        guard !sizePopover.isHidden else { return }
        sizePopover.isHidden = true
        if focusCanvas { window?.makeFirstResponder(self) }
        refresh()
    }

    private func syncSizePopover() {
        let activeRect = selection ?? hovered
        let px = activeRect.map { photo.pixelRect($0) } ?? .zero
        sizePopover.update(
            pixelWidth: Int(px.width.rounded()),
            pixelHeight: Int(px.height.rounded()),
            lockedRatio: lockedAspectRatio,
            presets: sizePresets
        )
    }

    func applyPixelSize(width: Int, height: Int) {
        guard width >= 1, height >= 1 else { return }
        let imgW = CGFloat(photo.image.width)
        let imgH = CGFloat(photo.image.height)
        let clampedW = min(imgW, CGFloat(width))
        let clampedH = min(imgH, CGFloat(height))
        let targetPixels: CGRect
        if let current = selection, polygon == nil {
            let cur = photo.pixelRect(current)
            let x = min(max(0, cur.minX), imgW - clampedW)
            let y = min(max(0, cur.minY), imgH - clampedH)
            targetPixels = CGRect(x: x, y: y, width: clampedW, height: clampedH)
        } else {
            let centerPx = pointer.flatMap { photo.pixel(at: $0) } ?? CGPoint(x: imgW / 2, y: imgH / 2)
            let x = min(max(0, (centerPx.x - clampedW / 2).rounded()), imgW - clampedW)
            let y = min(max(0, (centerPx.y - clampedH / 2).rounded()), imgH - clampedH)
            targetPixels = CGRect(x: x, y: y, width: clampedW, height: clampedH)
        }
        polygon = nil
        selection = photo.pointRect(targetPixels)
        parkedState = nil
        onSelectionChanged?()
        if !sizePopover.isHidden { syncSizePopover() }
        refresh()
    }

    func showNotice(_ text: String) {
        guard !isDocument else { return }
        noticeHideWork?.cancel()
        noticeLabel.stringValue = text
        noticeLabel.sizeToFit()
        let w = min(bounds.width - 32, ceil(noticeLabel.frame.width) + 24)
        let h = ceil(noticeLabel.frame.height) + 12
        noticeLabel.frame = CGRect(x: 12, y: 6, width: max(1, w - 24), height: max(1, h - 12)).integral
        noticeView.frame = CGRect(x: floor((bounds.width - w) / 2), y: 24, width: w, height: h).integral
        noticeView.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.dismissNotice() }
        noticeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    func dismissNotice() {
        noticeHideWork?.cancel()
        noticeHideWork = nil
        noticeView.isHidden = true
    }

    func clearSelection(keepingPointer: Bool = false, keepingParked: Bool = false, keepingRatioLock: Bool = false) {
        if heldDirection?.originalPolygon != nil { stopDirectionRepeat() }
        endAnchors()
        polylineNodes.removeAll()
        polygon = nil
        selectedAnchor = nil
        selection = nil
        finishText(commit: false)
        closeSizePopover(focusCanvas: false)
        annotations = CaptureAnnotations()
        selectedMark = nil
        draft = nil
        tool = nil
        drag = nil
        toolbarHidden = false
        if !keepingRatioLock { lockedAspectRatio = nil }
        nudgedWhileSelecting = false
        wheelRemainder = 0
        if !keepingParked { parkedState = nil }
        if !keepingPointer {
            hoverChain.removeAll()
            hoverLevel = 0
            pointer = nil
            endKeyboardPointer()
            stopDirectionRepeat()
        }
        refresh()
    }

    private func refresh() {
        let placingAnchors = anchorPoints != nil
        var dimensionsFit = false
        let isPendingOnly: Bool
        if case .pendingSelect = drag { isPendingOnly = true } else { isPendingOnly = false }
        let activelyDragging = drag != nil && !isPendingOnly
        hint.isHidden = isPlacingPolygonMark || !placingAnchors
        toolbar.isHidden = !isDocument && (mode == .text || selection == nil || activelyDragging || (placingAnchors && !isPlacingPolygonMark) || toolbarHidden)
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
        var vertexTargets: [CGRect] = []
        if !isDocument, isPlacingPolygonMark {
            toolbar.fit(within: bounds.width - 12)
            toolbar.setFrameOrigin(CGPoint(x: floor(bounds.midX - toolbar.frame.width / 2),
                                           y: max(6, bounds.maxY - toolbar.frame.height - 16)))
        } else if !isDocument, !placingAnchors, let rect = selection {
            if !toolbar.isHidden {
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
                vertexTargets = vertices.map {
                    CGRect(x: $0.x - 8, y: $0.y - 8, width: 16, height: 16)
                }
                if vertexTargets.contains(where: { $0.intersects(CGRect(origin: origin, size: size)) }) {
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
            }
        }
        if !isDocument, !placingAnchors, let rect = selection ?? hovered, !rect.isEmpty {
            let px = photo.pixelRect(rect)
            var label = "\(Int(px.width)) × \(Int(px.height)) px"
            if selection == nil, hoverChain.count > 1 {
                label += " · \(hoverLevel + 1)/\(hoverChain.count)"
            } else if selection != nil, lockedAspectRatio != nil {
                label += " 🔒"
            }
            dimensions.stringValue = label
            dimensions.sizeToFit()
            let w = dimensions.frame.width + 12, h = dimensions.frame.height + 4
            let labelX = min(max(4, rect.minX), bounds.maxX - w - 4)
            var labelOrigins = [CGPoint(x: labelX, y: rect.maxY + 6), CGPoint(x: labelX, y: rect.minY - h - 6)]
            if rect.width >= w + 12, rect.height >= h + 12 {
                labelOrigins.append(CGPoint(x: rect.minX + 6, y: rect.maxY - h - 6))
                labelOrigins.append(CGPoint(x: rect.minX + 6, y: rect.minY + 6))
            }
            let floatingObstacles = [hint, noticeView].filter { !$0.isHidden }.map { $0.frame.insetBy(dx: -4, dy: -4) }
            let obstacles = (toolbar.isHidden ? [] : toolbar.visibleCardFrames.map { $0.insetBy(dx: -4, dy: -4) })
                + vertexTargets + floatingObstacles
            let labelSize = CGSize(width: w, height: h)
            if let frame = labelOrigins.map({ CGRect(origin: $0, size: labelSize).integral }).first(where: {
                let frame = $0
                return bounds.insetBy(dx: 4, dy: 4).contains(frame) && !obstacles.contains { $0.intersects(frame) }
            }) {
                dimensions.frame = frame
                dimensionsFit = true
            }
        }
        dimensions.isHidden = !dimensionsFit || mode == .text || isEditingText || redaction != nil || anchorPoints != nil || !sizePopover.isHidden
        if !isDocument, !sizePopover.isHidden {
            let popSize = sizePopover.frame.size
            let anchorRect = selection ?? pointer.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) } ?? CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
            let px = min(max(8, anchorRect.minX), max(8, bounds.maxX - popSize.width - 8))
            var py = anchorRect.maxY + 8
            if py + popSize.height > bounds.maxY - 8 {
                py = max(8, anchorRect.minY - popSize.height - 8)
            }
            sizePopover.setFrameOrigin(CGPoint(x: floor(px), y: floor(py)))
        }
        updateKeyHints(activelyDragging: activelyDragging)
        updateLoupe()
        needsDisplay = true
    }

    private var shouldShowKeyHints: Bool {
        if let override = keyHintsSessionOverride { return override }
        return !keyHintsPermanentlyHidden
    }

    private func currentKeyHintRows() -> [CaptureKeyHintsView.Row] {
        if selection == nil {
            var rows: [CaptureKeyHintsView.Row] = [
                .init(keys: [L("滚轮")], label: L("切换选区层级")),
                .init(keys: ["Tab"], label: windowsOnly ? L("只框窗口：开") : L("只框窗口：关")),
                .init(keys: ["WASD"], label: L("微调光标 1px")),
                .init(keys: ["F"], label: L("预设尺寸 / 比例")),
            ]
            if canRestoreHistory {
                rows.append(.init(keys: ["R"], label: L("恢复最近选区")))
            }
            if hasCaptureHistory {
                rows.append(.init(keys: [",", "."], label: L("翻看截图历史")))
            }
            rows.append(.init(keys: ["C"], label: L("复制色值")))
            rows.append(.init(keys: ["Esc"], label: L("退出截图")))
            return rows
        }
        if let tool {
            var rows: [CaptureKeyHintsView.Row] = [
                .init(keys: ["[", "]"], label: tool.usesLettering ? L("调整字号") : tool == .mosaic ? L("调整打码强度") : tool == .spotlight ? L("调整遮罩深浅") : L("调整线宽")),
            ]
            if tool.supportsSquareConstrain || tool.isLine || tool.isFreehand {
                rows.append(.init(keys: ["Shift"], label: tool.supportsSquareConstrain ? L("正方 / 正圆") : tool.isFreehand ? L("画直线") : L("吸附 15°")))
            }
            rows.append(.init(keys: ["⌘Z"], label: L("撤销")))
            rows.append(.init(keys: ["H"], label: toolbarHidden ? L("显示工具栏") : L("隐藏工具栏")))
            rows.append(.init(keys: ["Esc"], label: L("退出当前工具")))
            return rows
        }
        return [
            .init(keys: ["1–9"], label: L("标注工具")),
            .init(keys: ["F"], label: L("尺寸 / 锁比例")),
            .init(keys: ["⇧C"], label: L("识别选区文字")),
            .init(keys: ["Enter"], label: L("复制图片")),
            .init(keys: ["⌘S"], label: L("保存（⇧⌘S 另存为）")),
            .init(keys: ["F3"], label: L("贴到屏幕")),
            .init(keys: ["H"], label: toolbarHidden ? L("显示工具栏") : L("隐藏工具栏")),
            .init(keys: ["Esc"], label: L("重新选区")),
        ]
    }

    private func updateKeyHints(activelyDragging: Bool) {
        guard !isDocument, mode == .image, shouldShowKeyHints,
              !activelyDragging, !isEditingText, !isEditingSize,
              anchorPoints == nil, polylineNodes.isEmpty, redaction == nil else {
            keyHintsView.isHidden = true
            return
        }
        keyHintsView.update(rows: currentKeyHintRows(), permanentlyHidden: keyHintsPermanentlyHidden)
        let size = keyHintsView.frame.size
        let margin: CGFloat = 16
        let leftRect = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        let rightRect = CGRect(x: bounds.maxX - margin - size.width, y: margin, width: size.width, height: size.height)
        var blockers: [CGRect] = []
        if let selection { blockers.append(selection.insetBy(dx: -8, dy: -8)) }
        if !toolbar.isHidden { blockers.append(contentsOf: toolbar.visibleCardFrames.map { $0.insetBy(dx: -8, dy: -8) }) }
        if !dimensions.isHidden { blockers.append(dimensions.frame.insetBy(dx: -6, dy: -6)) }
        if !noticeView.isHidden { blockers.append(noticeView.frame.insetBy(dx: -6, dy: -6)) }

        if bounds.contains(leftRect), !blockers.contains(where: { $0.intersects(leftRect) }) {
            keyHintsView.frame = leftRect
            keyHintsView.isHidden = false
        } else if bounds.contains(rightRect), !blockers.contains(where: { $0.intersects(rightRect) }) {
            keyHintsView.frame = rightRect
            keyHintsView.isHidden = false
        } else {
            keyHintsView.isHidden = true
        }
        keyHintsView.updateOpacity(pointer: pointer, loupeFrame: loupe?.isHidden == false ? loupe?.frame : nil)
    }

    private func updateLoupe() {
        guard let loupe else { return }
        guard let pointer, let pixel = photo.pixel(at: pointer), !isEditingText, !isEditingSize, anchorPoints == nil,
              tool == nil, redaction == nil, canSampleDisplay?() != false else {
            loupe.isHidden = true
            keyHintsView.updateOpacity(pointer: pointer, loupeFrame: nil)
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
        let obstacles = (toolbarCards + [dimensions, hint, noticeView].filter { !$0.isHidden }.map(\.frame))
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
        keyHintsView.updateOpacity(pointer: pointer, loupeFrame: loupe.isHidden ? nil : loupe.frame)
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
        if isDocument {
            guard !pixels.isEmpty, let tile = photo.image.cropping(to: pixels) else { return }
            ctx.draw(tile, in: photo.pointRect(pixels))
        } else {
            ctx.draw(photo.image, in: bounds)
        }
        drawOverlay(in: ctx, dirtyRect: dirtyRect)
    }

    fileprivate func drawOverlay(in ctx: CGContext, dirtyRect: NSRect) {
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
        var visibleSpotlights: [CaptureMark] = []
        for (i, mark) in marks.enumerated() where i != editingIndex && i != draggedMark && mark.kind == .spotlight {
            visibleSpotlights.append(mark)
        }
        if let draft, draft.kind == .spotlight { visibleSpotlights.append(draft) }
        if !visibleSpotlights.isEmpty {
            CaptureMark.drawSpotlights(visibleSpotlights, within: area, in: ctx)
        }
        for (i, mark) in marks.enumerated() where i != editingIndex && i != draggedMark && mark.kind != .spotlight {
            if mark.selectionBounds.intersects(dirtyRect) { mark.draw(in: ctx, backdrop: photo) }
        }
        if let draft, draft.kind != .spotlight { draft.draw(in: ctx, backdrop: photo) }
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
        let isPendingSelect: Bool
        if case .pendingSelect = drag { isPendingSelect = true } else { isPendingSelect = false }
        if polygon == nil, selection != nil, tool == nil, redaction == nil, (drag == nil || isPendingSelect), mode == .image {
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
        if anchorPoints != nil {
            updateLoupe()
            anchorPointer = point
            needsDisplay = true
            return
        }
        if !polylineNodes.isEmpty {
            updateLoupe()
            needsDisplay = true
            return
        }
        guard selection == nil, drag == nil else {
            updateLoupe()
            return
        }
        let previous = hovered
        updateHoverChain(at: point, preserveLevel: true)
        if hovered != previous {
            refresh()
        } else {
            updateLoupe()
        }
    }

    private func updateHoverChain(at point: CGPoint, preserveLevel: Bool, triggerProbe: Bool = true) {
        let previousRect = preserveLevel && hoverLevel > 0 && hoverChain.indices.contains(hoverLevel)
            ? hoverChain[hoverLevel]
            : nil
        let (chain, windowIndex) = CaptureHitChain.hitChain(
            windows: windowTargets.map(\.localRect),
            controlsForWindow: { discoveredControls[windowTargets[$0].windowID] ?? [] },
            at: point,
            screenBounds: bounds,
            windowsOnly: windowsOnly
        )
        var nextLevel = 0
        if let previousRect, let matched = chain.firstIndex(where: { CaptureHitChain.rectsNearlyEqual($0, previousRect) }) {
            nextLevel = matched
        }
        hoverChain = chain
        hoverLevel = nextLevel
        if triggerProbe, !windowsOnly, selection == nil, drag == nil, anchorPoints == nil,
           let windowIndex, windowTargets.indices.contains(windowIndex) {
            onProbeElement?(windowTargets[windowIndex], point)
        }
    }

    func addDiscoveredControls(_ controls: [CGRect], for windowID: CGWindowID) {
        guard !controls.isEmpty else { return }
        var list = discoveredControls[windowID] ?? []
        var added = false
        for rect in controls {
            if !list.contains(where: { CaptureHitChain.rectsNearlyEqual($0, rect) }) {
                list.append(rect)
                added = true
            }
        }
        guard added else { return }
        discoveredControls[windowID] = list
        if !windowsOnly, selection == nil, drag == nil, anchorPoints == nil, let pointer {
            let previous = hovered
            updateHoverChain(at: pointer, preserveLevel: true, triggerProbe: false)
            if hovered != previous { refresh() }
        }
    }

    func stepHoverLevel(_ delta: Int) {
        guard !isDocument, selection == nil, drag == nil, anchorPoints == nil, polylineNodes.isEmpty, delta != 0 else { return }
        if hoverChain.isEmpty, let pointer {
            updateHoverChain(at: pointer, preserveLevel: false)
        }
        guard !hoverChain.isEmpty else { return }
        let next = min(max(0, hoverLevel + delta), hoverChain.count - 1)
        guard next != hoverLevel else { return }
        hoverLevel = next
        refresh()
    }

    func setWindowsOnly(_ value: Bool, announce: Bool) {
        let changed = windowsOnly != value
        windowsOnly = value
        if changed, selection == nil, drag == nil, anchorPoints == nil, let pointer {
            updateHoverChain(at: pointer, preserveLevel: false)
            refresh()
        }
        if announce {
            showNotice(value ? L("只检测窗口 · Tab 切换") : L("检测界面元素 · Tab 切换"))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isDocument, selection == nil, drag == nil, anchorPoints == nil, polylineNodes.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        // 忽略惯性滑动，避免触控板轻滑一次跳过多个层级。
        if !event.momentumPhase.isEmpty { return }
        if event.phase == .ended || event.phase == .cancelled {
            wheelRemainder = 0
            return
        }
        if event.hasPreciseScrollingDeltas {
            wheelRemainder += event.scrollingDeltaY
            let threshold: CGFloat = 18
            while abs(wheelRemainder) >= threshold {
                let step = wheelRemainder > 0 ? 1 : -1
                wheelRemainder -= CGFloat(step) * threshold
                stepHoverLevel(step)
            }
        } else {
            wheelRemainder = 0
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            if delta != 0 { stepHoverLevel(delta > 0 ? 1 : -1) }
        }
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
        hoverChain.removeAll()
        hoverLevel = 0
        wheelRemainder = 0
        anchorPointer = nil
        refresh()
    }
    override func cursorUpdate(with event: NSEvent) { cursor(at: point(event)).set() }

    /// 显示哪个缩放指针和按下后拖哪个手柄，都由同一个命中区决定（四条整边与四角均支持命中）。
    private func handle(at p: CGPoint, in rect: CGRect) -> CaptureSelectionHandle? {
        guard !isDocument, polygon == nil, tool == nil, mode == .image else { return nil }
        return CaptureSelectionGeometry.handle(at: p, in: rect)
    }

    private func resizeCursor(_ h: CaptureSelectionHandle) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch h {
            case .bottomLeft: position = .bottomLeft
            case .topLeft: position = .topLeft
            case .bottomRight: position = .bottomRight
            case .topRight: position = .topRight
            case .left: position = .left
            case .right: position = .right
            case .bottom: position = .bottom
            case .top: position = .top
            }
            return .frameResize(position: position, directions: [.inward, .outward])
        }
        switch h {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair
        }
    }

    private var selectedAnnotation: CaptureMark? {
        guard tool == nil, redaction == nil, let selectedMark, marks.indices.contains(selectedMark) else { return nil }
        return marks[selectedMark]
    }

    private var activeAnnotationStyle: AnnotationStyle? {
        if let editingMark { return editingMark.style }
        if tool == .highlighter { return .stroke(highlighterStroke) }
        if tool?.usesStroke == true { return .stroke(drawingStroke) }
        if tool == .text { return editableTextBox?.style ?? .lettering(textStyle, text: textFormat) }
        if tool == .number { return .lettering(numberStyle) }
        if tool == .cover { return .fill(coverColor) }
        if tool == .mosaic { return .mosaic(mosaicStyle) }
        if tool == .spotlight { return .spotlight(spotlightStyle) }
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
            if tool == .highlighter || (tool == nil && selectedAnnotation?.kind == .highlighter) {
                highlighterStroke = stroke
            } else {
                drawingStroke = stroke
            }
            if selectedAnnotation?.kind.usesStroke == true, let selectedMark {
                annotations.change { $0[selectedMark].stroke = stroke }
            }
        case .lettering(let lettering, let format):
            guard style != activeAnnotationStyle else { return }
            if let input = textInput, var mark = editingMark {
                // 先同步实时编辑中的文字，再改对齐方式，避免按编辑前的旧文字宽度把文本框压窄。
                if mark.kind == .text { mark.text = input.string }
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
        case .mosaic(let mosaic):
            mosaicStyle = mosaic
            if selectedAnnotation?.kind == .mosaic, let selectedMark {
                annotations.change { $0[selectedMark].mosaicStyle = mosaic }
            }
        case .spotlight(let spotlight):
            spotlightStyle = spotlight
            if marks.contains(where: { $0.kind == .spotlight }) {
                annotations.change { list in
                    for i in list.indices where list[i].kind == .spotlight {
                        list[i].spotlightStyle = spotlight
                    }
                }
            }
        }
        refresh()
        window?.makeFirstResponder(textInput ?? self)
    }

    private func stepActiveStyle(_ delta: Int) {
        guard let style = activeAnnotationStyle else { return }
        let updated: AnnotationStyle
        switch style {
        case .stroke(var stroke):
            let next = stroke.width.stepped(delta)
            guard next != stroke.width else { return }
            stroke.width = next
            updated = .stroke(stroke)
        case .lettering(var lettering, let format):
            let next = lettering.size.stepped(delta)
            guard next != lettering.size else { return }
            lettering.size = next
            updated = .lettering(lettering, text: format)
        case .mosaic(var mosaic):
            let next = mosaic.level.stepped(delta)
            guard next != mosaic.level else { return }
            mosaic.level = next
            updated = .mosaic(mosaic)
        case .spotlight(var spotlight):
            let next = spotlight.shade.stepped(delta)
            guard next != spotlight.shade else { return }
            spotlight.shade = next
            updated = .spotlight(spotlight)
        case .fill:
            return
        }
        changeAnnotationStyle(updated)
        if let title = updated.sizeTitle { showNotice(title) }
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

    private func snapGuides() -> (x: [CGFloat], y: [CGFloat]) {
        var xs: [CGFloat] = [bounds.minX, bounds.maxX]
        var ys: [CGFloat] = [bounds.minY, bounds.maxY]
        for target in windowTargets {
            xs.append(target.localRect.minX)
            xs.append(target.localRect.maxX)
            ys.append(target.localRect.minY)
            ys.append(target.localRect.maxY)
        }
        for list in discoveredControls.values {
            for r in list {
                xs.append(r.minX)
                xs.append(r.maxX)
                ys.append(r.minY)
                ys.append(r.maxY)
            }
        }
        return (xs, ys)
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        if !sizePopover.isHidden, sizePopover.frame.contains(p) { return .arrow }
        if !isDocument, !toolbar.isHidden, toolbar.frame.contains(p), toolbar.hitTest(p) != nil { return .arrow }
        if !isDocument, mode == .image, selection != nil, !dimensions.isHidden, dimensions.frame.contains(p) { return .pointingHand }
        if anchorPoints != nil { return canCloseAnchors(at: p) ? .pointingHand : .crosshair }
        if !polylineNodes.isEmpty { return canClosePolyline(at: p) ? .pointingHand : .crosshair }
        switch drag {
        case .move, .moveSelectionVertex, .moveMark: return .closedHand
        case .resizeTextBox: return .resizeLeftRight
        case .resize(_, let h): return resizeCursor(h)
        case .select, .pendingSelect, .mark: return .crosshair
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
        stopDirectionRepeat()
        onChooseDisplay?()
        guard finishText(commit: true) else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = point(event)
        pointer = start
        snapAngles = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        selectedAnchor = nil
        if !sizePopover.isHidden {
            closeSizePopover(focusCanvas: true)
            return
        }
        if !isDocument, mode == .image, selection != nil, !dimensions.isHidden, dimensions.frame.contains(start) {
            openSizePopover()
            return
        }
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
                    $0.append(CaptureMark(kind: .cover, start: box.origin, end: CGPoint(x: box.maxX, y: box.maxY), fillColor: coverColor))
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
        } else if mode == .image, event.clickCount == 2, selection != nil, tool == nil, redaction == nil, inside {
            onCopy?()
            return
        } else if let selection, inside || regionEdge != nil {
            drag = .move(selection, polygon)
        } else if let selection {
            if !marks.isEmpty {
                showNotice(L("已有标注：拖边框调整选区，Esc 放弃标注"))
                refresh()
                cursor(at: start).set()
                return
            }
            // 选区外误点不直接清空，拖动超过阈值后才重画新选区。
            drag = .pendingSelect(selection, polygon)
        } else {
            dismissNotice()
            parkedState = nil
            updateHoverChain(at: start, preserveLevel: true)
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
            guard nudgedWhileSelecting || selection != nil || hypot(p.x - start.x, p.y - start.y) >= 3 else { return }
            var endPoint = p
            if !isDocument, !optionHeld, lockedAspectRatio == nil, hypot(p.x - start.x, p.y - start.y) >= 8 {
                let guides = snapGuides()
                endPoint = CGPoint(
                    x: CaptureSelectionGeometry.snap(p.x, to: guides.x),
                    y: CaptureSelectionGeometry.snap(p.y, to: guides.y)
                )
            }
            selection = CaptureSelectionGeometry.rect(from: start, to: endPoint, in: bounds, aspectRatio: lockedAspectRatio)
        case .pendingSelect:
            guard hypot(p.x - start.x, p.y - start.y) >= 3 || nudgedWhileSelecting else { return }
            clearSelection(keepingPointer: true, keepingRatioLock: true)
            self.drag = .select
            selection = CaptureSelectionGeometry.rect(from: start, to: p, in: bounds, aspectRatio: lockedAspectRatio)
            onSelectionChanged?()
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
            var resized = CaptureSelectionGeometry.resized(
                from: old,
                handle: h,
                delta: CGSize(width: p.x - start.x, height: p.y - start.y),
                in: bounds,
                aspectRatio: lockedAspectRatio
            )
            if !isDocument, !optionHeld, lockedAspectRatio == nil {
                let guides = snapGuides()
                resized = CaptureSelectionGeometry.snapResized(resized, handle: h, xGuides: guides.x, yGuides: guides.y, in: bounds)
            }
            selection = resized
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
            let minDX = min(0, r.minX - box.minX), maxDX = max(0, r.maxX - box.maxX)
            let minDY = min(0, r.minY - box.minY), maxDY = max(0, r.maxY - box.maxY)
            let dx = min(max(p.x - start.x, minDX), maxDX)
            let dy = min(max(p.y - start.y, minDY), maxDY)
            draft = original.translated(dx: dx, dy: dy)
        case .mark(let kind, let overMark):
            guard let r = selection else { return }
            if overMark != nil, hypot(p.x - start.x, p.y - start.y) < 3 * screenPoint {
                draft = nil
                break
            }
            if kind.isFreehand {
                let clamped = CaptureLineShape.clamped(p, in: r)
                let strokeStyle = kind == .highlighter ? highlighterStroke : drawingStroke
                if snapAngles {
                    let snapped = CaptureLineShape.point(clamped, from: start, in: r, snap: true)
                    draft = CaptureMark(kind: kind, start: start, end: snapped,
                                        freehandPoints: [start, snapped], stroke: strokeStyle)
                } else {
                    var pts = draft?.freehandPoints ?? [start]
                    if let last = pts.last, hypot(clamped.x - last.x, clamped.y - last.y) >= 2 * screenPoint {
                        pts.append(clamped)
                    } else if pts.count == 1, clamped != start {
                        pts.append(clamped)
                    }
                    draft = CaptureMark(kind: kind, start: start, end: clamped,
                                        freehandPoints: pts, stroke: strokeStyle)
                }
                break
            }
            let end: CGPoint
            if snapAngles, kind.supportsSquareConstrain {
                end = CaptureSelectionGeometry.squareEnd(from: start, to: p, in: r)
            } else {
                end = CaptureLineShape.point(p, from: start, in: r, snap: kind.isLine && snapAngles)
            }
            draft = CaptureMark(kind: kind, start: start, end: end,
                                stroke: kind.usesStroke ? drawingStroke : AnnotationStroke(),
                                fillColor: kind == .cover ? coverColor : .black,
                                mosaicStyle: mosaicStyle,
                                spotlightStyle: spotlightStyle,
                                customLineStyle: kind.isLine ? activeLineStyle : nil,
                                lineShape: activeLineMode == .curve ? .curve(from: start, to: end, in: r) : nil)
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        snapAngles = event.modifierFlags.contains(.shift)
        optionHeld = event.modifierFlags.contains(.option)
        updateDrag(to: point(event))
    }

    func nudgePointer(to point: CGPoint, systemPosition: CGPoint) {
        keyboardPointer = (point, systemPosition)
        showKeyboardCursor(at: point)
        if drag != nil {
            switch drag {
            case .select, .pendingSelect: nudgedWhileSelecting = nudgedWhileSelecting || pointer != point
            default: break
            }
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
            if !nudgedWhileSelecting, selection == nil, hypot(p.x - start.x, p.y - start.y) < 3 {
                selection = hovered ?? bounds
            }
            if selection?.isEmpty == true {
                selection = nil
            } else {
                parkedState = nil
                onSelectionChanged?()
            }
        case .pendingSelect:
            // 选区外单击未拖动：保留原选区不变。
            break
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
        if selection == nil { updateHoverChain(at: p, preserveLevel: false) }
        refresh()
        cursor(at: p).set()
        if mode == .text, selection != nil { onCopy?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        stepBack(fromRightClick: true)
    }

    func restoreRegion(_ rect: CGRect, polygon: CapturePolygon? = nil) {
        clearSelection(keepingPointer: true)
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
        let x = min(max(mark.start.x, selection.minX), max(selection.minX, selection.maxX - min(selection.width, 36)))
        let width = max(1, min(mark.end.x - x, selection.maxX - x))
        let height = min(selection.height, max(30, mark.bounds.height + 4))
        input.frame = CGRect(x: x, y: min(selection.maxY - height, max(selection.minY, mark.start.y - height)),
                             width: width, height: height)
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
        redactionCancelled?.set(true)
        redactionCancelled = nil
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
        let cancelled = Locked(false)
        redaction = .scanning(token)
        redactionCancelled = cancelled
        let scan = DispatchWorkItem { [weak self] in
            guard !cancelled.get() else { return }
            let boxes = try? CaptureRedaction.recognize(in: image, isCancelled: { cancelled.get() }).map { $0.applying(transform) }
            guard !cancelled.get() else { return }
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
        stopDirectionRepeat()
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
        case .ocr: onCopyText?(); return
        case .redact: toggleRedaction()
        case .undo: restoreEdit(annotations.undo())
        case .redo: restoreEdit(annotations.redo())
        case .copy: onCopy?(); return
        case .scroll:
            if canScroll { onScrollCapture?() }
            return
        case .pin: onPin?(); return
        case .save: onSave?(false); return
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
        if isEditingText || isEditingSize { return false }
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
        case (KeyCode.f, []) where !isDocument && mode == .image && drag == nil:
            guard !event.isARepeat else { break }
            openSizePopover()
        case (KeyCode.comma, []) where !isDocument && mode == .image && drag == nil,
             (KeyCode.comma, .shift) where !isDocument && mode == .image && drag == nil:
            guard !event.isARepeat else { break }
            onStepCaptureHistory?(true)
        case (KeyCode.period, []) where !isDocument && mode == .image && drag == nil,
             (KeyCode.period, .shift) where !isDocument && mode == .image && drag == nil:
            guard !event.isARepeat else { break }
            onStepCaptureHistory?(false)
        case (KeyCode.slash, .shift) where !isDocument && mode == .image && drag == nil,
             (KeyCode.f1, []) where !isDocument && mode == .image && drag == nil:
            guard !event.isARepeat else { break }
            keyHintsSessionOverride = !shouldShowKeyHints
            refresh()
        case (KeyCode.h, []) where !isDocument && mode == .image && selection != nil && drag == nil:
            guard !event.isARepeat else { break }
            toolbarHidden.toggle()
            showNotice(toolbarHidden ? L("已隐藏工具栏 · 按 H 恢复") : L("已显示工具栏"))
            refresh()
        case (KeyCode.c, .shift) where !isDocument && mode == .image && selection != nil && drag == nil:
            guard !event.isARepeat else { break }
            onCopyText?()
        case (KeyCode.leftBracket, []) where selection != nil && drag == nil:
            stepActiveStyle(-1)
        case (KeyCode.rightBracket, []) where selection != nil && drag == nil:
            stepActiveStyle(1)
        case (KeyCode.one, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.rectangle))
        case (KeyCode.two, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.ellipse))
        case (KeyCode.three, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.arrow))
        case (KeyCode.four, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.line))
        case (KeyCode.five, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.pen))
        case (KeyCode.six, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.highlighter))
        case (KeyCode.seven, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.text))
        case (KeyCode.eight, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.number))
        case (KeyCode.nine, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.mosaic))
        case (KeyCode.zero, []) where selection != nil && drag == nil && mode == .image:
            perform(.tool(.spotlight))
        case (KeyCode.tab, []) where !isDocument && selection == nil && drag == nil,
             (KeyCode.tab, .shift) where !isDocument && selection == nil && drag == nil:
            guard !event.isARepeat else { break }
            if let onToggleWindowsOnly { onToggleWindowsOnly() }
            else { setWindowsOnly(!windowsOnly, announce: true) }
        case (KeyCode.p, []) where !isDocument && mode == .image && marks.isEmpty && drag == nil: perform(.anchors)
        case (KeyCode.escape, []):
            stepBack(fromRightClick: false)
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
            if mode == .image, selection != nil, drag == nil { onSave?(false) }
        case (KeyCode.s, [.command, .shift]), (KeyCode.s, [.control, .shift]):
            guard !isDocument else { return false }
            if mode == .image, selection != nil, drag == nil { onSave?(true) }
        case (KeyCode.l, .command), (KeyCode.l, .control):
            guard !isDocument else { return false }
            if canScroll { onScrollCapture?() }
        case (KeyCode.f3, []):
            guard !isDocument else { return false }
            if mode == .image, selection != nil, drag == nil { onPin?() }
        case (KeyCode.r, []) where !isDocument && mode == .image && marks.isEmpty && drag == nil,
             (KeyCode.r, .shift) where !isDocument && mode == .image && marks.isEmpty && drag == nil:
            if !event.isARepeat { onRestoreRegion?(mods == .shift) }
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
            if drag == nil {
                if selection == nil, let parked = parkedState {
                    parkedState = nil
                    polygon = parked.polygon
                    selection = parked.selection
                    annotations = parked.annotations
                    dismissNotice()
                    refresh()
                } else {
                    perform(.undo)
                }
            }
        default: return false
        }
        return true
    }

    /// 阶梯回退（参考 WinShun）：折线/锚点 → 进行中拖动 → 辅助打码 → 激活工具 → 选区（有标注时暂存支持 ⌘Z 恢复）→ 退出截图。
    private func stepBack(fromRightClick: Bool) {
        if !sizePopover.isHidden {
            closeSizePopover(focusCanvas: true)
            return
        }
        if !polylineNodes.isEmpty {
            if fromRightClick { finishPolyline() } else { perform(.cancel) }
            return
        }
        if anchorPoints != nil {
            endAnchors()
            refresh()
            return
        }
        if let drag {
            switch drag {
            case .select:
                selection = nil
                nudgedWhileSelecting = false
            case .pendingSelect(let prev, let prevPolygon):
                if let prevPolygon { setSelectionPolygon(prevPolygon) } else { selection = prev }
                nudgedWhileSelecting = false
            case .move(let old, let oldPolygon):
                if let oldPolygon { setSelectionPolygon(oldPolygon) } else { selection = old }
            case .resize(let old, _):
                selection = old
            case .moveSelectionVertex(_, let original):
                setSelectionPolygon(original)
            case .mark, .moveMark, .resizeTextBox:
                draft = nil
            }
            self.drag = nil
            refresh()
            return
        }
        if isDocument {
            if !fromRightClick { onCancel?() }
            return
        }
        if mode == .text {
            onCancel?()
            return
        }
        if redaction != nil {
            stopRedaction()
            refresh()
            return
        }
        if tool != nil {
            tool = nil
            selectedMark = nil
            selectedAnchor = nil
            refresh()
            return
        }
        if let currentSelection = selection {
            if !marks.isEmpty || polygon != nil {
                parkedState = (currentSelection, polygon, annotations)
                clearSelection(keepingPointer: true, keepingParked: true)
                showNotice(L("已放弃本次标注 · ⌘Z 恢复"))
            } else {
                clearSelection(keepingPointer: true)
            }
            if let pointer { updateHoverChain(at: pointer, preserveLevel: false) }
            refresh()
            return
        }
        onCancel?()
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
            // 仅在 .default 模式运行，打开工具栏弹出菜单（.eventTracking）时不会持续空转。
            link.add(to: .main, forMode: .default)
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
        let opt = event.modifierFlags.contains(.option)
        guard snapAngles != snap || optionHeld != opt else { return }
        snapAngles = snap
        optionHeld = opt
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
            let adjusted: CGRect
            if shift, polygon == nil, let ratio = lockedAspectRatio, ratio > 0 {
                var r = photo.pixelRect(rect)
                let w = CGFloat(photo.image.width)
                let bottom = r.maxY
                if dx != 0 {
                    var nw = min(w - r.minX, max(1, r.width + CGFloat(dx)))
                    var nh = max(1, (nw / ratio).rounded())
                    if nh > bottom { nh = bottom; nw = max(1, (nh * ratio).rounded()) }
                    r = CGRect(x: r.minX, y: bottom - nh, width: min(w - r.minX, nw), height: nh)
                } else {
                    var nh = min(bottom, max(1, r.height + CGFloat(dy)))
                    var nw = max(1, (nh * ratio).rounded())
                    if nw > w - r.minX { nw = w - r.minX; nh = max(1, (nw / ratio).rounded()) }
                    r = CGRect(x: r.minX, y: bottom - nh, width: nw, height: min(bottom, nh))
                }
                adjusted = photo.pointRect(r)
            } else {
                adjusted = photo.adjusted(rect, dx: dx, dy: dy, resize: shift)
            }
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

/// 透明叠加层：仅绘制遮罩、选区与标注，底图由 CaptureCanvas 的静态 GPU 图层直接合成。
@MainActor
private final class CaptureOverlayView: NSView {
    private weak var canvas: CaptureCanvas?

    init(canvas: CaptureCanvas) {
        self.canvas = canvas
        super.init(frame: canvas.bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        canvas?.drawOverlay(in: ctx, dirtyRect: dirtyRect)
    }
}
