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
}

/// 普通截图和长图编辑共用的浮动工具条。宽度不足时整组换行。
@MainActor
final class CaptureToolbar: NSView {
    enum Action { case select, anchors, tool(CaptureMark.Kind), style, redact, undo, redo, scroll, pin, save, cancel, copy }

    private let document: Bool
    private var groups: [[CaptureToolButton]] = []
    private var dividers: [NSBox] = []
    private var availableWidth: CGFloat?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var status: String?
    private var styleOnly = false
    private let styleButton = CaptureToolButton(action: .style, name: L("标注样式"), symbol: "lineweight")
    private var style: AnnotationStyle?
    var perform: ((Action) -> Void)?
    var changeStyle: ((AnnotationStyle) -> Void)?
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
        self.shadow = shadow
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
        var tools = document ? [select] : []
        for kind in CaptureMark.Kind.allCases {
            tools.append(button(.tool(kind), kind.title, kind.symbol))
            if kind == .polygon {
                styleButton.target = self
                styleButton.action = #selector(clicked(_:))
                addSubview(styleButton)
                tools.append(styleButton)
            }
            if kind == .cover, !document {
                tools.append(button(.redact, L("辅助打码"), "text.viewfinder"))
            }
        }
        groups.append(tools)
        groups.append([button(.undo, L("撤销标注"), "arrow.uturn.backward", keys: "⌘Z"),
                       button(.redo, L("重做标注"), "arrow.uturn.forward", keys: "⇧⌘Z")])
        if !document {
            groups.append([button(.scroll, L("长截图（⌘L）"), "arrow.up.and.down.text.horizontal"),
                           button(.pin, L("贴到屏幕（F3）"), "pin"),
                           button(.save, L("保存 PNG…"), "square.and.arrow.down", keys: "⌘S")])
            groups.append([button(.cancel, L("取消（Esc）"), "xmark"),
                           button(.copy, L("复制图片（Enter）"), "checkmark")])
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
    override var wantsUpdateLayer: Bool { true }

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

    func fit(within width: CGFloat) {
        guard width != availableWidth else { return }
        availableWidth = width
        let inset = ToolbarMetrics.inset, side = ToolbarMetrics.button, gap = ToolbarMetrics.spacing
        if styleOnly {
            for divider in dividers { divider.isHidden = true }
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
            setFrameSize(CGSize(width: toolbarWidth, height: rowHeight + 2 * inset))
            return
        }
        let dividerGap = ToolbarMetrics.dividerMargin * 2 + 1
        let visibleGroups = groups.map { $0.filter { $0 !== styleButton || style != nil } }
        let groupWidths = visibleGroups.map { CGFloat($0.count) * (side + gap) - gap }
        let singleRow = 2 * inset + groupWidths.reduce(0, +) + CGFloat(dividers.count) * dividerGap
        let rightEdge = max(inset + side, width - inset)
        var x = inset, y = inset, widest = inset
        for (index, group) in visibleGroups.enumerated() {
            if index > 0 {
                let divider = dividers[index - 1]
                // 窄屏上标注独占首行，避免只把最后两个按钮挤到下一行。
                let wrap = (!document && index == 1 && singleRow > width) || x + dividerGap + groupWidths[index] > rightEdge
                divider.isHidden = wrap
                if wrap {
                    x = inset
                    y += side + gap
                } else {
                    divider.frame = CGRect(x: x + ToolbarMetrics.dividerMargin,
                                           y: y + (side - ToolbarMetrics.dividerHeight) / 2,
                                           width: 1, height: ToolbarMetrics.dividerHeight)
                    x += dividerGap
                }
            }
            for (i, button) in group.enumerated() {
                if i > 0 {
                    if x + gap + side > rightEdge {
                        x = inset
                        y += side + gap
                    } else { x += gap }
                }
                button.frame = CGRect(x: x, y: y, width: side, height: side)
                x += side
                widest = max(widest, x)
            }
        }
        let toolbarWidth = widest + inset
        var height = y + side + inset
        if !statusLabel.isHidden {
            let textWidth = toolbarWidth - 4 * inset
            let textHeight = statusLabel.cell?.cellSize(forBounds:
                CGRect(x: 0, y: 0, width: textWidth, height: 120)).height ?? 16
            statusLabel.frame = CGRect(x: 2 * inset, y: height, width: textWidth, height: ceil(textHeight))
            height = statusLabel.frame.maxY + inset
        }
        setFrameSize(CGSize(width: toolbarWidth, height: height))
    }

    func update(tool: CaptureMark.Kind?, canUndo: Bool, canRedo: Bool, canScroll: Bool, hasMarks: Bool,
                redactionStatus: String? = nil, hasPolygon: Bool = false,
                anchorStatus: String? = nil, canRemoveAnchor: Bool = false,
                style: AnnotationStyle? = nil, styleOnly: Bool = false) {
        let status = anchorStatus ?? redactionStatus
        let styleVisibilityChanged = (self.style == nil) != (style == nil)
        self.style = style
        if self.status != status || self.styleOnly != styleOnly || styleVisibilityChanged {
            self.status = status
            self.styleOnly = styleOnly
            statusLabel.stringValue = status ?? ""
            statusLabel.isHidden = status == nil
            if let width = availableWidth {
                availableWidth = nil
                fit(within: width)
            }
            onLayoutChanged?()
        }
        styleButton.stylePreview = style
        styleButton.setAccessibilityValue(style.map {
            [$0.color.title, $0.sizeTitle].compactMap { $0 }.joined(separator: " · ")
        })
        for button in groups.joined() {
            button.isHidden = button === styleButton ? style == nil : styleOnly
            switch button.command {
            case .select: button.select(tool == nil && redactionStatus == nil)
            case .anchors: button.isEnabled = !hasMarks && anchorStatus == nil
            case .tool(let kind): button.select(tool == kind)
            case .redact:
                button.select(redactionStatus != nil)
                button.toolTip = redactionStatus == nil ? L("辅助打码") : L("退出辅助打码")
                button.setAccessibilityLabel(button.toolTip)
            case .undo:
                button.isEnabled = anchorStatus == nil ? canUndo : canRemoveAnchor
                let name = anchorStatus == nil ? L("撤销标注") : L("撤回锚点")
                button.toolTip = "\(name)  ⌘Z"
                button.setAccessibilityLabel(name)
            case .redo: button.isEnabled = anchorStatus == nil && canRedo
            case .scroll:
                button.isEnabled = canScroll
                if hasPolygon { button.toolTip = L("长截图需要矩形选区") }
                else if hasMarks { button.toolTip = L("先撤销标注，再开始长截图") }
                else { button.toolTip = canScroll ? L("长截图（⌘L）") : L("请调整选区大小后再开始长截图") }
            case .copy, .save, .pin: button.isEnabled = anchorStatus == nil
            case .style, .cancel: break
            }
        }
    }

    @objc private func clicked(_ sender: CaptureToolButton) {
        if case .style = sender.command {
            makeStyleMenu().popUp(positioning: nil, at: CGPoint(x: sender.frame.minX, y: sender.frame.maxY + 4), in: self)
        } else { perform?(sender.command) }
    }

    func makeStyleMenu() -> NSMenu {
        let menu = NSMenu(title: L("标注样式"))
        guard let style else { return menu }
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
        if case .lettering(let lettering) = style {
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

    @objc private func chooseColor(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? AnnotationColor, let style else { return }
        switch style {
        case .stroke(var stroke):
            stroke.color = color
            changeStyle?(.stroke(stroke))
        case .lettering(var lettering):
            lettering.color = color
            changeStyle?(.lettering(lettering))
        case .fill:
            changeStyle?(.fill(color))
        }
    }

    @objc private func chooseWidth(_ sender: NSMenuItem) {
        guard let width = sender.representedObject as? AnnotationStroke.Width, case .stroke(var stroke) = style else { return }
        stroke.width = width
        changeStyle?(.stroke(stroke))
    }

    @objc private func chooseFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? AnnotationLettering.Size,
              case .lettering(var lettering) = style else { return }
        lettering.size = size
        changeStyle?(.lettering(lettering))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
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
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: primary ? .bold : .medium))
        toolTip = name
        setAccessibilityLabel(name)
        focusRingType = .exterior
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }


    func select(_ selected: Bool) {
        state = selected ? .on : .off
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
        if case .lettering(let lettering) = stylePreview {
            let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 5, yRadius: 5)
            let color = lettering.color
            NSColor(cgColor: color.contrastingInk)?.setFill()
            plate.fill()
            NSColor.separatorColor.setStroke()
            plate.stroke()
            let sample = NSAttributedString(string: "A", attributes: [
                .font: NSFont.systemFont(ofSize: 10 + lettering.size.points / 5, weight: .semibold),
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
