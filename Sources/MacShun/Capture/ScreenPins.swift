// SPDX-License-Identifier: MIT

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 保存和复制始终使用原始 PNG；缩放、窗口阴影和透明度只影响屏幕显示。
struct PinPicture {
    let png: Data
    let image: NSImage
    let pixels: CGSize

    init?(png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              let image = NSImage(data: png) else { return nil }
        self.png = png
        self.image = image
        pixels = CGSize(width: width, height: height)
    }

    static func read(_ pasteboard: NSPasteboard) -> PinPicture? {
        if let data = pasteboard.data(forType: .png), let picture = PinPicture(png: data) { return picture }
        let image: NSImage?
        if pasteboard.types?.contains(.fileURL) == true {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier]
            ]
            guard let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first,
                  url.isFileURL else { return nil }
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(pasteboard: pasteboard)
        }
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return PinPicture(png: data)
    }
}

enum PinGeometry {
    /// 以当前鼠标下的图像位置为中心，放大时这一像素留在原处。
    static func scaled(_ frame: CGRect, to size: CGSize, around anchor: CGPoint) -> CGRect {
        let x = anchor.x - (anchor.x - frame.minX) * size.width / frame.width
        let y = anchor.y - (anchor.y - frame.minY) * size.height / frame.height
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    static func fit(_ size: CGSize, near mouse: CGPoint, on visible: CGRect) -> CGRect {
        let factor = min(1, visible.width / size.width, visible.height / size.height)
        let width = max(1, (size.width * factor).rounded()), height = max(1, (size.height * factor).rounded())
        return CGRect(x: max(visible.minX, min(mouse.x + 12, visible.maxX - width)),
                      y: max(visible.minY, min(mouse.y - height - 12, visible.maxY - height)),
                      width: width, height: height)
    }
}

@MainActor
final class ScreenPins: NSObject, NSWindowDelegate {
    static let shared = ScreenPins()
    private(set) var windows: [ScreenPinPanel] = []
    // 支持 Ctrl+滚轮调透明度时，让鼠标引擎放过发往贴图的滚轮。
    nonisolated static let frames = Locked([Int: CGRect]())

    @discardableResult
    func show(_ picture: PinPicture, at selection: CGRect? = nil, pasteboard: NSPasteboard = .general) -> ScreenPinPanel? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return nil }
        let frame: CGRect
        let natural: CGSize
        if let selection {
            natural = selection.size
            frame = selection
        } else {
            let scale = screen.backingScaleFactor
            natural = CGSize(width: max(1, picture.pixels.width / scale), height: max(1, picture.pixels.height / scale))
            frame = PinGeometry.fit(natural, near: mouse, on: screen.visibleFrame)
        }
        let panel = ScreenPinPanel(picture: picture, frame: frame, natural: natural, pasteboard: pasteboard)
        panel.delegate = self
        windows.append(panel)
        trackFrame(panel)
        panel.orderFrontRegardless()
        return panel
    }

    func showClipboard() {
        guard let picture = PinPicture.read(.general) else {
            let alert = NSAlert()
            alert.messageText = L("剪贴板里没有可贴出的图片")
            alert.informativeText = L("请先复制图片，或在截图选区里点“贴到屏幕”。")
            NSApp.activate()
            alert.runModal()
            return
        }
        show(picture)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? ScreenPinPanel else { return }
        Self.frames.update { $0.removeValue(forKey: panel.windowNumber) }
        windows.removeAll { $0 === panel }
    }

    private func trackFrame(_ panel: ScreenPinPanel) {
        guard windows.contains(where: { $0 === panel }) else { return }
        Self.frames.update { $0[panel.windowNumber] = panel.frame }
    }
    func windowDidMove(_ notification: Notification) {
        if let panel = notification.object as? ScreenPinPanel { trackFrame(panel) }
    }
    func windowDidResize(_ notification: Notification) { windowDidMove(notification) }

    func closeAll() { windows.forEach { $0.close() } }
}

@MainActor
final class ScreenPinPanel: NSPanel {
    let picture: PinPicture
    let naturalSize: CGSize
    private let pasteboard: NSPasteboard
    private var savePanel: NSSavePanel?
    private let surface = PinSurface()
    private(set) var zoom: CGFloat

    init(picture: PinPicture, frame: CGRect, natural: CGSize, pasteboard: NSPasteboard) {
        self.picture = picture
        naturalSize = natural
        zoom = frame.width / natural.width
        self.pasteboard = pasteboard
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        title = L("屏幕贴图")
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = surface
        setFrame(frame, display: false)
        surface.setAccessibilityLabel(title)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func scale(to requested: CGFloat, around point: CGPoint) {
        // 很长的剪贴板图片初始可低于 10%，避免下一次手势突然跳大。
        let minimum = min(zoom, 0.1)
        let value = min(8, max(minimum, requested))
        let size = CGSize(width: max(1, (naturalSize.width * value).rounded()), height: max(1, (naturalSize.height * value).rounded()))
        zoom = value
        setFrame(PinGeometry.scaled(frame, to: size, around: point), display: true)
        surface.showPercent(Int((zoom * 100).rounded()), opacity: false)
    }

    func adjustOpacity(_ delta: CGFloat) {
        alphaValue = min(1, max(0.2, alphaValue + delta))
        surface.showPercent(Int((alphaValue * 100).rounded()), opacity: true)
    }

    func copyPicture() {
        let item = NSPasteboardItem()
        guard item.setData(picture.png, forType: .png) else { return }
        pasteboard.clearContents()
        if !pasteboard.writeObjects([item]) { NSSound.beep() }
    }

    func savePicture() {
        if let savePanel { savePanel.makeKeyAndOrderFront(nil); return }
        let panel = NSSavePanel()
        panel.level = .modalPanel
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = L("屏幕贴图") + ".png"
        savePanel = panel
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.begin { [weak self] result in
            guard let self else { return }
            savePanel = nil
            if result == .OK, let url = panel.url {
                do { try picture.png.write(to: url, options: .atomic) }
                catch { NSAlert(error: error).runModal() }
            }
            if NSApp.isActive, let previous, previous != .current { previous.activate(options: []) }
        }
    }

    override func close() {
        savePanel?.cancel(nil)
        super.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }
    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let center = CGPoint(x: frame.midX, y: frame.midY)
        switch (event.keyCode, mods) {
        case (KeyCode.escape, []): close()
        case (KeyCode.c, .control), (KeyCode.c, .command): copyPicture()
        case (KeyCode.s, .control), (KeyCode.s, .command): savePicture()
        case (KeyCode.equal, []), (KeyCode.equal, .shift): scale(to: zoom * 1.1, around: center)
        case (KeyCode.minus, []): scale(to: zoom / 1.1, around: center)
        default: return false
        }
        return true
    }
}

@MainActor
private final class PinCloseButton: CaptureHoverButton {
    override func draw(_ dirtyRect: NSRect) {
        let fill = hovered || isHighlighted ? NSColor.systemRed.shadow(withLevel: isHighlighted ? 0.35 : 0.14) : nil
        (fill ?? NSColor.black.withAlphaComponent(0.76)).setFill()
        let face = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        face.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        face.lineWidth = 1
        face.stroke()
        super.draw(dirtyRect)
    }
}

@MainActor
private final class PinSurface: NSView {
    private var panel: ScreenPinPanel? { window as? ScreenPinPanel }
    private let badge = NSTextField(labelWithString: "")
    private let dismiss = PinCloseButton()
    private var pointerInside = false
    private var hoverArea: NSTrackingArea?
    private var hideBadge: DispatchWorkItem?
    private var resizeAnchor: CGPoint?
    private var startDistance: CGFloat = 1
    private var startZoom: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        badge.isHidden = true
        addSubview(badge)
        // 图像本身可深可浅，关闭按钮的对比度要独立于系统主题。
        dismiss.isBordered = false
        dismiss.contentTintColor = .white
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭贴图"))
        dismiss.imagePosition = .imageOnly
        dismiss.toolTip = L("关闭贴图")
        dismiss.setAccessibilityLabel(L("关闭贴图"))
        dismiss.target = self
        dismiss.action = #selector(closePin)
        dismiss.isHidden = true
        addSubview(dismiss)
        toolTip = L("拖动贴图；滚轮缩放，Ctrl 加滚轮调透明度。右键查看更多操作。")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        panel?.picture.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    func showPercent(_ value: Int, opacity: Bool) {
        badge.stringValue = opacity ? L("透明度 %ld%%", value) : String(value) + "%"
        badge.isHidden = false
        needsLayout = true
        hideBadge?.cancel()
        let hide = DispatchWorkItem { [weak self] in self?.badge.isHidden = true }
        hideBadge = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: hide)
    }

    @objc private func closePin() { panel?.close() }

    override func layout() {
        super.layout()
        dismiss.frame = CGRect(x: max(0, bounds.maxX - 34), y: max(0, bounds.maxY - 34), width: 24, height: 24)
        dismiss.isHidden = !pointerInside || bounds.width < 70 || bounds.height < 52
        if !badge.isHidden {
            let size = badge.intrinsicContentSize
            let width = min(max(0, bounds.width - 12), size.width + 10)
            let height = min(max(0, bounds.height - 6), size.height + 2)
            let below = !dismiss.isHidden && width + 12 > dismiss.frame.minX
            badge.frame = CGRect(x: 6, y: below ? 4 : max(0, bounds.maxY - height - 8), width: width, height: height)
        }
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerInside = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false; needsLayout = true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === badge ? self : hit
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(self)
        let mouse = panel.convertPoint(toScreen: event.locationInWindow)
        if event.clickCount == 2 {
            resizeAnchor = nil
            panel.scale(to: 1, around: mouse)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let grip = min(8, min(bounds.width, bounds.height) / 4)
        let left = p.x < grip, bottom = p.y < grip
        if (left || p.x > bounds.width - grip) && (bottom || p.y > bounds.height - grip) {
            let anchor = CGPoint(x: left ? panel.frame.maxX : panel.frame.minX, y: bottom ? panel.frame.maxY : panel.frame.minY)
            resizeAnchor = anchor
            startZoom = panel.zoom
            startDistance = max(1, hypot(mouse.x - anchor.x, mouse.y - anchor.y))
        } else {
            resizeAnchor = nil
            panel.performDrag(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let panel, let anchor = resizeAnchor else { return }
        let p = panel.convertPoint(toScreen: event.locationInWindow)
        panel.scale(to: startZoom * hypot(p.x - anchor.x, p.y - anchor.y) / startDistance, around: anchor)
    }
    override func mouseUp(with event: NSEvent) { resizeAnchor = nil }

    override func scrollWheel(with event: NSEvent) {
        guard let panel, event.scrollingDeltaY != 0, event.momentumPhase.isEmpty else { return }
        var steps = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { steps = -steps }
        steps = event.hasPreciseScrollingDeltas ? min(2, max(-2, steps / 14)) : (steps > 0 ? 1 : -1)
        if event.modifierFlags.contains(.control) { panel.adjustOpacity(steps * 0.05) }
        else { panel.scale(to: panel.zoom * pow(1.1, steps), around: panel.convertPoint(toScreen: event.locationInWindow)) }
    }
    override func magnify(with event: NSEvent) {
        guard let panel else { return }
        panel.scale(to: panel.zoom * (1 + event.magnification), around: panel.convertPoint(toScreen: event.locationInWindow))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let panel else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(L("复制图片"), symbol: "doc.on.doc") { panel.copyPicture() })
        menu.addItem(ActionMenuItem(L("保存 PNG…"), symbol: "square.and.arrow.down") { panel.savePicture() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L("恢复原始大小")) { panel.scale(to: 1, around: CGPoint(x: panel.frame.midX, y: panel.frame.midY)) })
        menu.addItem(ActionMenuItem(L("恢复不透明")) { panel.adjustOpacity(1) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L("关闭贴图"), symbol: "xmark") { panel.close() })
        return menu
    }
}
