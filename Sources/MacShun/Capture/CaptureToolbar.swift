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
    enum Action { case select, tool(CaptureMark.Kind), undo, redo, scroll, pin, save, cancel, copy }

    private var groups: [[CaptureToolButton]] = []
    private var dividers: [NSBox] = []
    private var availableWidth: CGFloat?
    var perform: ((Action) -> Void)?

    init(document: Bool = false) {
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
        groups.append([select] + CaptureMark.Kind.allCases.map { button(.tool($0), $0.title, $0.symbol) })
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
        let dividerGap = ToolbarMetrics.dividerMargin * 2 + 1
        let groupWidths = groups.map { CGFloat($0.count) * (side + gap) - gap }
        let singleRow = 2 * inset + groupWidths.reduce(0, +) + CGFloat(dividers.count) * dividerGap
        let rightEdge = max(inset + side, width - inset)
        var x = inset, y = inset, widest = inset
        for (index, group) in groups.enumerated() {
            if index > 0 {
                let divider = dividers[index - 1]
                // 窄屏上标注独占首行，避免只把最后两个按钮挤到下一行。
                let wrap = (index == 1 && singleRow > width) || x + dividerGap + groupWidths[index] > rightEdge
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
        setFrameSize(CGSize(width: widest + inset, height: y + side + inset))
    }

    func update(tool: CaptureMark.Kind?, canUndo: Bool, canRedo: Bool, canScroll: Bool, hasMarks: Bool) {
        for button in groups.joined() {
            switch button.command {
            case .select: button.select(tool == nil)
            case .tool(let kind): button.select(tool == kind)
            case .undo: button.isEnabled = canUndo
            case .redo: button.isEnabled = canRedo
            case .scroll:
                button.isEnabled = canScroll
                if hasMarks { button.toolTip = L("先撤销标注，再开始长截图") }
                else { button.toolTip = canScroll ? L("长截图（⌘L）") : L("请调整选区大小后再开始长截图") }
            default: break
            }
        }
    }

    @objc private func clicked(_ sender: CaptureToolButton) { perform?(sender.command) }

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
    init(action: CaptureToolbar.Action, name: String, symbol: String) {
        command = action
        if case .copy = action { primary = true } else { primary = false }
        super.init(frame: .zero)
        switch action {
        case .select, .tool: setButtonType(.pushOnPushOff)
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
        guard let glyph = image?.withSymbolConfiguration(.init(paletteColors: [ink])) else { return }
        let rect = CGRect(x: (bounds.width - glyph.size.width) / 2, y: (bounds.height - glyph.size.height) / 2,
                          width: glyph.size.width, height: glyph.size.height)
        glyph.draw(in: backingAlignedRect(rect, options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
