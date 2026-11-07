// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
private final class CapturePanel: NSPanel {
    let canvas: CaptureCanvas
    let displayID: CGDirectDisplayID

    init(frame: CGRect, displayID: CGDirectDisplayID, canvas: CaptureCanvas) {
        self.displayID = displayID
        self.canvas = canvas
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = canvas
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        canvas.handleKey(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) { _ = canvas.handleKey(event) }
}

/// 只记本次运行中上一次成功输出的屏幕和矩形。显示器移动后仍使用该屏内的位置。
private struct CaptureRegionMemory {
    let display: CGDirectDisplayID
    let screenSize: CGSize
    let pixels: CGSize
    let rect: CGRect

    init(display: CGDirectDisplayID, photo: CaptureImage, selection: CGRect) {
        self.display = display
        screenSize = photo.size
        pixels = CGSize(width: photo.image.width, height: photo.image.height)
        rect = photo.pixelRect(selection)
    }

    func matches(_ id: CGDirectDisplayID, _ photo: CaptureImage) -> Bool {
        display == id && screenSize == photo.size && pixels == CGSize(width: photo.image.width, height: photo.image.height)
    }
}

/// 一次只保留一组冻结画面；全部屏幕取完才显示选区窗口。取消时不写剪贴板或磁盘。
@MainActor
final class ScreenCaptureController: NSObject {
    private var panels: [CapturePanel] = []
    private var lastRegion: CaptureRegionMemory?
    private var session: UUID?
    private var savePanel: NSSavePanel?
    private var previousApp: NSRunningApplication?
    private var notice: NSPanel?
    private var scrolling: ScrollingCapture?

    private let pasteboard: NSPasteboard
    private let makeScrollReader: ScrollCaptureSource.Factory
    private let freeze: @MainActor () async throws -> [FrozenScreen]

    init(pasteboard: NSPasteboard = .general,
         makeScrollReader: @escaping ScrollCaptureSource.Factory = ScrollCaptureSource.reader,
         freeze: @escaping @MainActor () async throws -> [FrozenScreen] = { try await FrozenScreen.captureAll() }) {
        self.pasteboard = pasteboard
        self.freeze = freeze
        self.makeScrollReader = makeScrollReader
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(cancel), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancel), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancel), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    func start(_ mode: CaptureMode) {
        guard session == nil else { return }
        notice?.orderOut(nil)
        notice = nil
        let token = UUID()
        session = token
        previousApp = NSWorkspace.shared.frontmostApplication
        Task {
            do {
                let screens = try await freeze()
                guard session == token else { return }
                let canRestore = screens.contains { lastRegion?.matches($0.displayID, $0.photo) == true }
                for screen in screens { addPanel(for: screen, mode: mode, canRestore: canRestore) }
                showPanels()
            } catch {
                guard session == token else { return }
                cancel()
                let error = error as NSError
                let denied = error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
                if denied || !CGPreflightScreenCaptureAccess() {
                    let alert = NSAlert()
                    alert.messageText = L("允许 Mac顺 截取屏幕")
                    alert.informativeText = L("在系统设置的屏幕录制权限中允许 Mac顺，然后重试。如果系统要求重新打开应用，请按提示操作。")
                    alert.addButton(withTitle: L("打开系统设置"))
                    alert.addButton(withTitle: L("取消"))
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn { Permissions.openScreenCaptureSettings() }
                } else {
                    showMessage(L("无法截取屏幕"), detail: error.localizedDescription)
                }
            }
        }
    }

    private func addPanel(for screen: FrozenScreen, mode: CaptureMode, canRestore: Bool) {
        let canvas = CaptureCanvas(photo: screen.photo, mode: mode, windowRects: screen.windowRects, canRestore: canRestore)
        let panel = CapturePanel(frame: screen.frame, displayID: screen.displayID, canvas: canvas)
        canvas.onRestoreRegion = { [weak self] in self?.restoreRegion() }
        canvas.onChooseDisplay = { [weak self, weak panel] in
            self?.panels.filter { $0 !== panel }.forEach { $0.canvas.clearSelection() }
        }
        canvas.onCopy = { [weak self, weak canvas] in
            if let canvas { self?.copy(canvas) }
        }
        canvas.onPin = { [weak self, weak canvas] in
            guard let self, let canvas, let selection = canvas.selection, let window = canvas.window,
                  let image = output(canvas), let data = png(image), let picture = PinPicture(png: data) else { return }
            let frame = window.convertToScreen(canvas.convert(selection, to: nil))
            let region = regionMemory(canvas)
            cancel()
            if ScreenPins.shared.show(picture, at: frame, pasteboard: pasteboard) != nil { lastRegion = region }
        }
        let display = screen.displayID
        canvas.onScrollCapture = { [weak self, weak canvas] in
            guard let self, let canvas, let selection = canvas.selection, let window = canvas.window,
                  canvas.marks.isEmpty else { return }
            let region = ScrollCaptureRegion(display: display, screen: window.frame, photo: canvas.photo, selection: selection)
            let remembered = regionMemory(canvas)
            hidePanels()
            panels.removeAll()
            let token = session
            let capture = ScrollingCapture(region: region, pasteboard: pasteboard) { [weak self] in
                if self?.session == token { self?.cancel() }
            }
            capture.onExport = { [weak self] in self?.lastRegion = remembered }
            scrolling = capture
            capture.start(makeReader: makeScrollReader)
        }
        canvas.onSave = { [weak self, weak canvas] in
            if let canvas { self?.save(canvas) }
        }
        canvas.onCancel = { [weak self] in self?.cancel() }
        panels.append(panel)
    }

    private func regionMemory(_ canvas: CaptureCanvas) -> CaptureRegionMemory? {
        guard let panel = canvas.window as? CapturePanel, let selection = canvas.selection else { return nil }
        return CaptureRegionMemory(display: panel.displayID, photo: canvas.photo, selection: selection)
    }

    private func restoreRegion() {
        guard let lastRegion, panels.allSatisfy({ $0.canvas.marks.isEmpty && !$0.canvas.isEditingText }),
              let target = panels.first(where: { lastRegion.matches($0.displayID, $0.canvas.photo) }) else { return }
        for panel in panels where panel !== target { panel.canvas.clearSelection() }
        target.canvas.restoreRegion(target.canvas.photo.pointRect(lastRegion.rect))
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(target.canvas)
    }

    private func showPanels(focusing preferred: CaptureCanvas? = nil) {
        let mouse = NSEvent.mouseLocation
        FrontAppTracker.shared.captureActive.set(true)
        for panel in panels { panel.orderFrontRegardless() }
        let panel = panels.first { $0.canvas === preferred } ?? panels.first { $0.frame.contains(mouse) } ?? panels.first
        if let panel {
            panel.canvas.hover(at: panel.convertPoint(fromScreen: mouse))
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.canvas)
        }
    }

    private func hidePanels() {
        FrontAppTracker.shared.captureActive.set(false)
        panels.forEach { $0.orderOut(nil) }
    }

    func finishScrolling() { scrolling?.requestFinish() }
    func cancelScrolling() {
        if scrolling != nil { cancel() }
    }

    @objc func cancel() {
        guard session != nil else { return }
        session = nil
        scrolling?.close()
        scrolling = nil
        savePanel?.cancel(nil)
        savePanel = nil
        hidePanels()
        panels.removeAll()
        previousApp = nil
    }

    private func output(_ canvas: CaptureCanvas) -> CGImage? {
        guard let selection = canvas.selection else { return nil }
        let image = canvas.photo.render(selection, marks: canvas.marks)
        if image == nil { toast(L("无法生成图片，请重新选择区域。")) }
        return image
    }

    private func copy(_ canvas: CaptureCanvas) {
        guard let image = output(canvas), let token = session else { return }
        let remembered = regionMemory(canvas)
        hidePanels()
        panels.removeAll()
        if canvas.mode == .text {
            let count = pasteboard.changeCount
            toast(L("正在识别文字…"))
            Task {
                let text = await Task.detached(priority: .userInitiated) { ContentExtractor.recognizeText(in: image) }.value
                guard session == token else { return }
                cancel()
                guard !text.isEmpty else { toast(L("选区里没有识别到文字")); return }
                guard pasteboard.changeCount == count else {
                    toast(L("剪贴板已更改，请重新取字")); return
                }
                let item = NSPasteboardItem()
                item.setString(text, forType: .string)
                if write(item) { toast(L("已复制识别的文字")) }
            }
        } else {
            cancel()
            guard let data = png(image) else { toast(L("无法生成图片，请重新选择区域。")); return }
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            if write(item) { lastRegion = remembered }
        }
    }

    /// 由既有 ClipboardWatcher 按记录开关、权限和大小限制入库。
    private func write(_ item: NSPasteboardItem) -> Bool {
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects([item])
        if !ok { toast(L("未能写入剪贴板")) }
        return ok
    }

    private func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func save(_ canvas: CaptureCanvas) {
        guard savePanel == nil, let token = session, let image = output(canvas) else { return }
        hidePanels()
        let panel = NSSavePanel()
        savePanel = panel
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = L("截图 %@.png", date.string(from: Date()))
        NSApp.activate()
        panel.begin { [weak self, weak canvas] response in
            guard let self, session == token, let canvas else { return }
            savePanel = nil
            if response == .OK, let url = panel.url {
                do {
                    guard let data = png(image) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                    lastRegion = regionMemory(canvas)
                    restoreFocusAfterSave()
                    cancel()
                    return
                } catch {
                    showMessage(L("无法保存截图"), detail: error.localizedDescription)
                }
            }
            restoreFocusAfterSave()
            showPanels(focusing: canvas)
        }
    }

    /// 非激活式选区面板不改变前台程序；只有系统保存对话框需要把焦点交回去。
    private func restoreFocusAfterSave() {
        if NSApp.isActive, let previousApp, previousApp != .current { previousApp.activate(options: []) }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    private func toast(_ message: String) {
        notice?.orderOut(nil)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 28, height: label.frame.height + 18)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 20,
                           width: size.width, height: size.height).integral
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let card = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        card.material = .popover
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        label.setFrameOrigin(CGPoint(x: 14, y: 9))
        card.addSubview(label)
        panel.contentView = card
        notice = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak panel] in
            if self?.notice === panel { panel?.orderOut(nil); self?.notice = nil }
        }
    }
}
