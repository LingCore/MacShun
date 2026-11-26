// SPDX-License-Identifier: MIT

import AppKit

private enum ToolbarMetrics {
    static let inset: CGFloat = 6
    static let button: CGFloat = 32
    static let spacing: CGFloat = 3
    static let dividerMargin: CGFloat = 7
    static let dividerHeight: CGFloat = 18
    static let radius: CGFloat = 12
    static let buttonRadius = radius - inset
    static let cardGap: CGFloat = 5
}

@MainActor
private final class CaptureToolbarCard: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.cornerRadius = ToolbarMetrics.radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 截图的两组工具各有一张卡片，宽度不足时在各自卡片内换行。
@MainActor
final class CaptureToolbar: NSView {
    enum Action { case select, anchors, tool(CaptureMark.Kind), style, lineEnds, arrowHead, ocr, redact, undo, redo, scroll, pin, save, cancel, copy }

    private let document: Bool
    private let cards = [CaptureToolbarCard(), CaptureToolbarCard()]
    private var groups: [[CaptureToolButton]] = []
    private var secondaryStart = 0
    private var movableGroups: [Int] = []
    private var dividers: [NSBox] = []
    private var availableWidth: CGFloat?
    private var primaryRowOnTop = true
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var status: String?
    private var styleOnly = false
    private let styleButton = CaptureToolButton(action: .style, name: L("标注样式"), symbol: "lineweight")
    private let endsButton = CaptureToolButton(action: .lineEnds, name: L("箭头位置"), symbol: "arrow.right")
    private let headButton = CaptureToolButton(action: .arrowHead, name: L("箭头样式"), symbol: "arrowtriangle.right.fill")
    private var style: AnnotationStyle?
    private var lineStyle: AnnotationLineStyle?
    private var lineMode: AnnotationLineMode?
    private var allowsPolyline = false
    var perform: ((Action) -> Void)?
    var changeStyle: ((AnnotationStyle) -> Void)?
    var changeLineStyle: ((AnnotationLineStyle) -> Void)?
    var changeLineMode: ((AnnotationLineMode) -> Void)?
    var onLayoutChanged: (() -> Void)?

    init(document: Bool = false) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        for card in cards {
            card.wantsLayer = true
            card.shadow = shadow
            addSubview(card)
        }
        func button(_ action: Action, _ name: String, _ symbol: String, keys: String? = nil) -> CaptureToolButton {
            let button = CaptureToolButton(action: action, name: name, symbol: symbol)
            if let keys { button.toolTip = "\(name)  \(keys)" }
            button.target = self
            button.action = #selector(clicked(_:))
            addSubview(button)
            return button
        }
        let select = button(.select, document ? L("选择标注") : L("选择标注或调整选区"), "cursorarrow")
        if !document {
            groups.append([select, button(.anchors, L("锚点选区"), "point.3.connected.trianglepath.dotted", keys: "P")])
        }
        let styleButtons = [styleButton, endsButton, headButton]
        for button in styleButtons {
            button.target = self
            button.action = #selector(clicked(_:))
            addSubview(button)
        }
        let secondaryTools: [CaptureMark.Kind] = [.ellipse, .line, .highlighter, .spotlight, .polygon, .cover]
        func toolButton(_ kind: CaptureMark.Kind) -> CaptureToolButton {
            button(.tool(kind), kind.title, kind.symbol, keys: kind.shortcutHint)
        }
        let primaryOrder: [CaptureMark.Kind] = [.rectangle, .arrow, .pen, .mosaic, .text, .number]
        let tools = document
            ? CaptureMark.Kind.allCases.map(toolButton)
            : primaryOrder.map(toolButton)
        groups.append(document ? [select] + tools : tools)
        if document { groups.append(styleButtons) }
        let historyGroup = groups.count
        groups.append([button(.undo, L("撤销标注"), "arrow.uturn.backward", keys: "⌘Z"),
                       button(.redo, L("重做标注"), "arrow.uturn.forward", keys: "⇧⌘Z")])
        if !document {
            movableGroups = [groups.count, historyGroup]
            groups.append([button(.pin, L("贴到屏幕（F3）"), "pin"),
                           button(.save, L("保存 PNG…"), "square.and.arrow.down", keys: "⌘S")])
            groups.append([button(.cancel, L("取消（Esc）"), "xmark"),
                           button(.copy, L("复制图片（Enter）"), "checkmark")])
            secondaryStart = groups.count
            groups.append(secondaryTools.map(toolButton) + styleButtons)
            groups.append([button(.ocr, L("识别选区文字"), "doc.text.viewfinder", keys: "⇧C"),
                           button(.redact, L("辅助打码"), "text.viewfinder"),
                           button(.scroll, L("长截图（⌘L）"), "arrow.up.and.down.text.horizontal")])
        }
        for _ in groups.dropFirst() {
            let divider = NSBox()
            divider.boxType = .separator
            addSubview(divider)
            dividers.append(divider)
        }
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        addSubview(statusLabel)
        fit(within: .greatestFiniteMagnitude)
        update(tool: nil, canUndo: false, canRedo: false, canScroll: false, hasMarks: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setPrimaryRowOnTop(_ onTop: Bool) {
        guard primaryRowOnTop != onTop else { return }
        primaryRowOnTop = onTop
        refit()
    }

    private func refit() {
        guard let width = availableWidth else { return }
        availableWidth = nil
        fit(within: width)
    }

    private func shows(_ button: CaptureToolButton) -> Bool {
        if button === styleButton { return style != nil }
        if button === endsButton || button === headButton { return lineStyle != nil && !styleOnly }
        return !styleOnly
    }

    func fit(within width: CGFloat) {
        guard width != availableWidth else { return }
        availableWidth = width
        let inset = ToolbarMetrics.inset, side = ToolbarMetrics.button, gap = ToolbarMetrics.spacing
        dividers.forEach { $0.isHidden = true }
        cards.forEach { $0.isHidden = true }
        if styleOnly {
            let minimumWidth = 2 * inset + side
            let idealWidth = ceil(statusLabel.intrinsicContentSize.width) + side + 4 * inset + gap
            let toolbarWidth = max(minimumWidth, min(width, idealWidth))
            let textX = inset + side + gap
            let textWidth = max(1, toolbarWidth - textX - 2 * inset)
            let textHeight = ceil(statusLabel.cell?.cellSize(forBounds:
                CGRect(x: 0, y: 0, width: textWidth, height: 120)).height ?? 16)
            let rowHeight = max(side, textHeight)
            styleButton.frame = CGRect(x: inset, y: inset + floor((rowHeight - side) / 2), width: side, height: side)
            statusLabel.frame = CGRect(x: textX, y: inset + floor((rowHeight - textHeight) / 2),
                                       width: textWidth, height: textHeight)
            let size = CGSize(width: toolbarWidth, height: rowHeight + 2 * inset)
            cards[0].frame = CGRect(origin: .zero, size: size)
            cards[0].isHidden = false
            setFrameSize(size)
            return
        }

        let dividerGap = ToolbarMetrics.dividerMargin * 2 + 1
        let visibleGroups = groups.map { $0.filter(shows) }
        var sections = document ? [Array(groups.indices)] : [Array(0..<secondaryStart), Array(secondaryStart..<groups.count)]
        if !document {
            func rowWidth(_ indices: [Int]) -> CGFloat {
                let counts = indices.map { visibleGroups[$0].count }.filter { $0 > 0 }
                let buttons = CGFloat(counts.reduce(0, +))
                return 2 * inset + buttons * (side + gap) - CGFloat(counts.count) * gap
                    + CGFloat(max(0, counts.count - 1)) * dividerGap
            }
            // 空间紧张时先把保存、贴图和历史移到另一行，复制和取消仍紧邻选区。
            for index in movableGroups where rowWidth(sections[0]) > width {
                guard rowWidth(sections[1] + [index]) <= width else { continue }
                sections[0].removeAll { $0 == index }
                sections[1].append(index)
            }
        }
        let order = primaryRowOnTop || document ? Array(sections.indices) : Array(sections.indices.reversed())
        let rightEdge = max(inset + side, width - inset)
        var top: CGFloat = 0, widest: CGFloat = 0
        for section in order {
            var x = inset, y = top + inset, farthest = inset
            for index in sections[section] {
                let visible = visibleGroups[index]
                guard !visible.isEmpty else { continue }
                let groupWidth = CGFloat(visible.count) * (side + gap) - gap
                if x > inset {
                    if x + dividerGap + groupWidth > rightEdge {
                        x = inset
                        y += side + gap
                    } else {
                        let divider = dividers[index - 1]
                        divider.frame = CGRect(x: x + ToolbarMetrics.dividerMargin,
                            y: y + (side - ToolbarMetrics.dividerHeight) / 2, width: 1, height: ToolbarMetrics.dividerHeight)
                        divider.isHidden = false
                        x += dividerGap
                    }
                }
                for (index, button) in visible.enumerated() {
                    if index > 0 {
                        if x + gap + side > rightEdge {
                            x = inset
                            y += side + gap
                        } else { x += gap }
                    }
                    button.frame = CGRect(x: x, y: y, width: side, height: side)
                    x += side
                    farthest = max(farthest, x)
                }
            }
            var cardWidth = farthest + inset
            var bottom = y + side + inset
            if section == sections.count - 1, !statusLabel.isHidden {
                let font = statusLabel.font ?? .systemFont(ofSize: 13)
                let preferred = ceil((statusLabel.stringValue as NSString).size(withAttributes: [.font: font]).width)
                cardWidth = max(cardWidth, min(width, preferred + 6 * inset))
                let textWidth = cardWidth - 4 * inset
                let textHeight = statusLabel.cell?.cellSize(forBounds:
                    CGRect(x: 0, y: 0, width: textWidth, height: 120)).height ?? 16
                statusLabel.frame = CGRect(x: 2 * inset, y: bottom, width: textWidth, height: ceil(textHeight))
                bottom = statusLabel.frame.maxY + inset
            }
            cards[section].frame = CGRect(x: 0, y: top, width: cardWidth, height: bottom - top)
            cards[section].isHidden = false
            widest = max(widest, cardWidth)
            top = bottom + ToolbarMetrics.cardGap
        }
        setFrameSize(CGSize(width: widest, height: top - ToolbarMetrics.cardGap))
    }

    func update(tool: CaptureMark.Kind?, canUndo: Bool, canRedo: Bool, canScroll: Bool, hasMarks: Bool,
                redactionStatus: String? = nil, hasPolygon: Bool = false,
                anchorStatus: String? = nil, pathStatus: String? = nil, canRemoveAnchor: Bool = false,
                style: AnnotationStyle? = nil, lineStyle: AnnotationLineStyle? = nil,
                lineMode: AnnotationLineMode? = nil, allowsPolyline: Bool = false, styleOnly: Bool = false) {
        let status = anchorStatus ?? pathStatus ?? redactionStatus
        let styleVisibilityChanged = (self.style == nil) != (style == nil) || (self.lineStyle == nil) != (lineStyle == nil)
        self.style = style
        self.lineStyle = lineStyle
        self.lineMode = lineMode
        self.allowsPolyline = allowsPolyline
        if self.status != status || self.styleOnly != styleOnly || styleVisibilityChanged {
            self.status = status
            self.styleOnly = styleOnly
            statusLabel.stringValue = status ?? ""
            statusLabel.isHidden = status == nil
            refit()
            onLayoutChanged?()
        }
        styleButton.stylePreview = style
        styleButton.setAccessibilityValue(style.map {
            let alignment: String? = if case .lettering(_, let format) = $0 { format?.alignment.title } else { nil }
            return [lineMode?.title, $0.color?.title, $0.sizeTitle, alignment].compactMap { $0 }.joined(separator: " · ")
        })
        if let lineStyle {
            endsButton.setGlyph(lineStyle.ends.symbol)
            headButton.setGlyph(lineStyle.head.symbol)
            endsButton.setAccessibilityValue(lineStyle.ends.title)
            headButton.setAccessibilityValue(lineStyle.head.title)
        }
        for button in groups.joined() {
            let shouldHide = !shows(button)
            if button.isHidden != shouldHide { button.isHidden = shouldHide }
            switch button.command {
            case .select: button.select(tool == nil && redactionStatus == nil)
            case .anchors:
                let enabled = !hasMarks && anchorStatus == nil && pathStatus == nil
                if button.isEnabled != enabled { button.isEnabled = enabled }
            case .tool(let kind): button.select(tool == kind)
            case .redact:
                button.select(redactionStatus != nil)
                let tip = redactionStatus == nil ? L("辅助打码") : L("退出辅助打码")
                if button.toolTip != tip {
                    button.toolTip = tip
                    button.setAccessibilityLabel(tip)
                }
            case .undo:
                let enabled = anchorStatus == nil && pathStatus == nil ? canUndo : canRemoveAnchor
                if button.isEnabled != enabled { button.isEnabled = enabled }
                let undoName = hasPolygon ? L("撤销") : L("撤销标注")
                let name = pathStatus != nil ? L("撤回节点") : (anchorStatus == nil ? undoName : L("撤回锚点"))
                let tip = "\(name)  ⌘Z"
                if button.toolTip != tip {
                    button.toolTip = tip
                    button.setAccessibilityLabel(name)
                }
            case .redo:
                let enabled = anchorStatus == nil && pathStatus == nil && canRedo
                if button.isEnabled != enabled { button.isEnabled = enabled }
                let name = hasPolygon ? L("重做") : L("重做标注")
                let tip = "\(name)  ⇧⌘Z"
                if button.toolTip != tip {
                    button.toolTip = tip
                    button.setAccessibilityLabel(name)
                }
            case .scroll:
                if button.isEnabled != canScroll { button.isEnabled = canScroll }
                let tip: String
                if hasPolygon { tip = L("长截图需要矩形选区") }
                else if hasMarks { tip = L("先撤销标注，再开始长截图") }
                else { tip = canScroll ? L("长截图（⌘L）") : L("请调整选区大小后再开始长截图") }
                if button.toolTip != tip { button.toolTip = tip }
            case .copy, .save, .pin, .ocr:
                let enabled = anchorStatus == nil
                if button.isEnabled != enabled { button.isEnabled = enabled }
            case .style, .lineEnds, .arrowHead, .cancel: break
            }
        }
    }

    @objc private func clicked(_ sender: CaptureToolButton) {
        let menu: NSMenu
        switch sender.command {
        case .style: menu = makeStyleMenu()
        case .lineEnds: menu = makeLineEndsMenu()
        case .arrowHead: menu = makeArrowHeadMenu()
        default: perform?(sender.command); return
        }
        menu.popUp(positioning: nil, at: CGPoint(x: sender.frame.minX, y: sender.frame.maxY + 4), in: self)
    }

    func makeLineEndsMenu() -> NSMenu {
        let menu = NSMenu(title: L("箭头位置"))
        for ends in AnnotationLineStyle.Ends.allCases {
            let item = NSMenuItem(title: ends.title, action: #selector(chooseLineEnds(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ends
            item.state = ends == lineStyle?.ends ? .on : .off
            item.image = NSImage(systemSymbolName: ends.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    func makeArrowHeadMenu() -> NSMenu {
        let menu = NSMenu(title: L("箭头样式"))
        for head in AnnotationLineStyle.Head.allCases {
            let item = NSMenuItem(title: head.title, action: #selector(chooseArrowHead(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = head
            item.state = head == lineStyle?.head ? .on : .off
            item.image = NSImage(systemSymbolName: head.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseLineEnds(_ sender: NSMenuItem) {
        guard var lineStyle, let ends = sender.representedObject as? AnnotationLineStyle.Ends else { return }
        lineStyle.ends = ends
        changeLineStyle?(lineStyle)
    }

    @objc private func chooseArrowHead(_ sender: NSMenuItem) {
        guard var lineStyle, let head = sender.representedObject as? AnnotationLineStyle.Head else { return }
        lineStyle.head = head
        changeLineStyle?(lineStyle)
    }

    func makeStyleMenu() -> NSMenu {
        let menu = NSMenu(title: L("标注样式"))
        guard let style else { return menu }
        if case .mosaic(let mosaic) = style {
            menu.addItem(.sectionHeader(title: L("打码样式")))
            for mode in AnnotationMosaicStyle.Mode.allCases {
                let item = NSMenuItem(title: mode.title, action: #selector(chooseMosaicMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode
                item.state = mode == mosaic.mode ? .on : .off
                item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: L("打码强度")))
            for level in AnnotationMosaicStyle.Level.allCases {
                let item = NSMenuItem(title: level.title, action: #selector(chooseMosaicLevel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = level
                item.state = level == mosaic.level ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        if case .spotlight(let spotlight) = style {
            menu.addItem(.sectionHeader(title: L("遮罩深浅")))
            for shade in AnnotationSpotlightStyle.Shade.allCases {
                let item = NSMenuItem(title: shade.title, action: #selector(chooseSpotlightShade(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = shade
                item.state = shade == spotlight.shade ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        if case .lettering(_, let format?) = style {
            addTextFormatItems(to: menu, format: format)
        }
        if let lineMode {
            menu.addItem(.sectionHeader(title: L("线型")))
            for mode in AnnotationLineMode.allCases where allowsPolyline || mode != .polyline {
                let item = NSMenuItem(title: mode.title, action: #selector(chooseLineMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode
                item.state = mode == lineMode ? .on : .off
                item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: L("颜色")))
        for color in AnnotationColor.allCases {
            let item = NSMenuItem(title: color.title, action: #selector(chooseColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.state = color == style.color ? .on : .off
            item.image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
                let swatch = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                NSColor(cgColor: color.ink)?.setFill()
                swatch.fill()
                NSColor.separatorColor.setStroke()
                swatch.stroke()
                return true
            }
            menu.addItem(item)
        }
        if case .fill = style { return menu }
        menu.addItem(.separator())
        if case .lettering(let lettering, _) = style {
            menu.addItem(.sectionHeader(title: L("字号")))
            for size in AnnotationLettering.Size.allCases {
                let item = NSMenuItem(title: size.title, action: #selector(chooseFontSize(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = size
                item.state = size == lettering.size ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        guard case .stroke(let stroke) = style else { return menu }
        menu.addItem(.sectionHeader(title: L("线宽")))
        for width in AnnotationStroke.Width.allCases {
            let item = NSMenuItem(title: width.title, action: #selector(chooseWidth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = width
            item.state = width == stroke.width ? .on : .off
            item.image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
                NSColor.labelColor.setFill()
                let thickness = width.points
                NSBezierPath(roundedRect: CGRect(x: 1, y: rect.midY - thickness / 2, width: 14, height: thickness),
                             xRadius: thickness / 2, yRadius: thickness / 2).fill()
                return true
            }
            menu.addItem(item)
        }
        return menu
    }

    private func addTextFormatItems(to menu: NSMenu, format: AnnotationTextFormat) {
        func add(_ title: String, symbol: String, chosen: Bool, format: AnnotationTextFormat) {
            let item = NSMenuItem(title: title, action: #selector(chooseTextFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            item.state = chosen ? .on : .off
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.sectionHeader(title: L("文字对齐")))
        for alignment in AnnotationTextFormat.Alignment.allCases {
            var updated = format
            updated.alignment = alignment
            add(alignment.title, symbol: alignment.symbol, chosen: alignment == format.alignment, format: updated)
        }
        menu.addItem(.separator())
        var bold = format
        bold.bold.toggle()
        add(L("粗体"), symbol: "bold", chosen: format.bold, format: bold)
        var background = format
        background.showsBackground.toggle()
        add(L("文字底框"), symbol: "rectangle", chosen: format.showsBackground, format: background)
        menu.addItem(.separator())
    }

    @objc private func chooseTextFormat(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? AnnotationTextFormat,
              case .lettering(let lettering, _?) = style else { return }
        changeStyle?(.lettering(lettering, text: format))
    }

    @objc private func chooseLineMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AnnotationLineMode, lineMode != nil else { return }
        changeLineMode?(mode)
    }

    @objc private func chooseColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? AnnotationColor, let style else { return }
        switch style {
        case .stroke(var stroke):
            stroke.color = color
            changeStyle?(.stroke(stroke))
        case .lettering(var lettering, let format):
            lettering.color = color
            changeStyle?(.lettering(lettering, text: format))
        case .fill:
            changeStyle?(.fill(color))
        case .mosaic, .spotlight:
            break
        }
    }

    @objc private func chooseMosaicMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AnnotationMosaicStyle.Mode,
              case .mosaic(var mosaic) = style else { return }
        mosaic.mode = mode
        changeStyle?(.mosaic(mosaic))
    }

    @objc private func chooseMosaicLevel(_ sender: NSMenuItem) {
        guard let level = sender.representedObject as? AnnotationMosaicStyle.Level,
              case .mosaic(var mosaic) = style else { return }
        mosaic.level = level
        changeStyle?(.mosaic(mosaic))
    }

    @objc private func chooseSpotlightShade(_ sender: NSMenuItem) {
        guard let shade = sender.representedObject as? AnnotationSpotlightStyle.Shade,
              case .spotlight(var spotlight) = style else { return }
        spotlight.shade = shade
        changeStyle?(.spotlight(spotlight))
    }

    @objc private func chooseWidth(_ sender: NSMenuItem) {
        guard let width = sender.representedObject as? AnnotationStroke.Width, case .stroke(var stroke) = style else { return }
        stroke.width = width
        changeStyle?(.stroke(stroke))
    }

    @objc private func chooseFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? AnnotationLettering.Size,
              case .lettering(var lettering, let format) = style else { return }
        lettering.size = size
        changeStyle?(.lettering(lettering, text: format))
    }

    var visibleCardFrames: [CGRect] {
        guard !isHidden else { return [] }
        return cards.filter { !$0.isHidden }.map { convert($0.frame, to: superview) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visibleCardFrames.contains(where: { $0.contains(point) }) else { return nil }
        let hit = super.hitTest(point)
        return !styleOnly || hit === styleButton ? hit : nil
    }

    // 工具组之间的留白也属于工具条，点在这里不能重新框选底下的画面。
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

/// 截图工具和贴图关闭键在非激活面板里也要响应指针。
@MainActor
class CaptureHoverButton: NSButton {
    private var tracking: NSTrackingArea?
    private(set) var hovered = false {
        didSet { if oldValue != hovered { needsDisplay = true } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        if let window, !isHiddenOrHasHiddenAncestor {
            hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else { hovered = false }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

@MainActor
private final class CaptureToolButton: CaptureHoverButton {
    let command: CaptureToolbar.Action
    private let primary: Bool
    private var glyph: String?
    var stylePreview: AnnotationStyle? {
        didSet { if oldValue != stylePreview { needsDisplay = true } }
    }
    init(action: CaptureToolbar.Action, name: String, symbol: String) {
        command = action
        if case .copy = action { primary = true } else { primary = false }
        super.init(frame: .zero)
        switch action {
        case .select, .tool, .redact: setButtonType(.pushOnPushOff)
        default: setButtonType(.momentaryPushIn)
        }
        isBordered = false
        imagePosition = .imageOnly
        setGlyph(symbol)
        toolTip = name
        setAccessibilityLabel(name)
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setGlyph(_ symbol: String) {
        guard glyph != symbol else { return }
        glyph = symbol
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: primary ? .bold : .medium))
        needsDisplay = true
    }

    func select(_ selected: Bool) {
        let next: NSControl.StateValue = selected ? .on : .off
        guard state != next else { return }
        state = next
        setAccessibilityValue(selected ? 1 : 0)
        needsDisplay = true
    }

    private var face: NSBezierPath {
        NSBezierPath(roundedRect: bounds, xRadius: ToolbarMetrics.buttonRadius, yRadius: ToolbarMetrics.buttonRadius)
    }

    override func drawFocusRingMask() { face.fill() }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        let ink: NSColor
        let accent = NSColor.controlAccentColor
        if !isEnabled {
            fill = .clear
            ink = .labelColor.withAlphaComponent(0.45)
        } else if primary {
            let shade: CGFloat = isHighlighted ? 0.25 : hovered ? 0.13 : 0
            fill = accent.shadow(withLevel: shade) ?? accent
            ink = .white
        } else if state == .on {
            fill = accent.withAlphaComponent(isHighlighted ? 0.34 : hovered ? 0.25 : 0.17)
            ink = accent
        } else {
            fill = NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.20 : hovered ? 0.11 : 0)
            ink = .labelColor
        }
        fill.setFill()
        face.fill()
        if case .fill(let color) = stylePreview {
            let sample = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 9, y: bounds.midY - 7, width: 18, height: 14),
                                      xRadius: 3, yRadius: 3)
            NSColor(cgColor: color.ink)?.setFill()
            sample.fill()
            NSColor.separatorColor.setStroke()
            sample.stroke()
            return
        }
        if case .mosaic(let mosaic) = stylePreview {
            let symbol = NSImage(systemSymbolName: mosaic.mode.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))?
                .withSymbolConfiguration(.init(paletteColors: [ink]))
            if let symbol {
                let rect = CGRect(x: (bounds.width - symbol.size.width) / 2, y: (bounds.height - symbol.size.height) / 2,
                                  width: symbol.size.width, height: symbol.size.height)
                symbol.draw(in: backingAlignedRect(rect, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        if case .spotlight(let spotlight) = stylePreview {
            let outer = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 9, y: bounds.midY - 7, width: 18, height: 14),
                                     xRadius: 3, yRadius: 3)
            NSColor.labelColor.withAlphaComponent(spotlight.shade.alpha).setFill()
            outer.fill()
            let inner = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 4, y: bounds.midY - 3, width: 8, height: 6),
                                     xRadius: 1.5, yRadius: 1.5)
            NSColor.windowBackgroundColor.setFill()
            inner.fill()
            NSColor.separatorColor.setStroke()
            outer.stroke()
            return
        }
        if case .stroke(let stroke) = stylePreview {
            let thickness = stroke.width.points + 2
            let sample = NSBezierPath(roundedRect: CGRect(x: bounds.midX - 10, y: bounds.midY - thickness / 2,
                                                         width: 20, height: thickness),
                                      xRadius: thickness / 2, yRadius: thickness / 2)
            NSColor(cgColor: stroke.color.ink)?.setFill()
            sample.fill()
            NSColor.separatorColor.setStroke()
            sample.lineWidth = 1
            sample.stroke()
            return
        }
        if case .lettering(let lettering, let format) = stylePreview {
            let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 5, yRadius: 5)
            let color = lettering.color
            NSColor(cgColor: color.contrastingInk)?.setFill()
            plate.fill()
            NSColor.separatorColor.setStroke()
            plate.stroke()
            let sample = NSAttributedString(string: "A", attributes: [
                .font: NSFont.systemFont(ofSize: 10 + lettering.size.points / 5, weight: format?.bold == true ? .bold : .semibold),
                .foregroundColor: NSColor(cgColor: color.ink) ?? .labelColor
            ])
            let size = sample.size()
            sample.draw(at: CGPoint(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2)))
            return
        }
        guard let glyph = image?.withSymbolConfiguration(.init(paletteColors: [ink])) else { return }
        let rect = CGRect(x: (bounds.width - glyph.size.width) / 2, y: (bounds.height - glyph.size.height) / 2,
                          width: glyph.size.width, height: glyph.size.height)
        glyph.draw(in: backingAlignedRect(rect, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
