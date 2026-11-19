// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import SwiftUI

/// 剪贴板历史：记录、弹出面板、选中后粘贴（C1–C5）。只在主线程上使用。
@MainActor
final class ClipboardController {
    let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let watcher: ClipboardWatcher
    private let configStore: ConfigStore
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var keyMonitor: Any?
    private var pasteTarget: pid_t?
    private var pendingPaste: UUID?
    private var previewOffset: CGFloat?
    /// 从本程序的文件搜索框里打开时，选中的条目交给它
    private var host: Host?

    /// store 不给时用默认目录。不写成默认参数：默认参数不在主线程上下文里求值，不能调用 ClipboardStore()
    init(configStore: ConfigStore, store: ClipboardStore? = nil, pasteboard: NSPasteboard = .general) {
        let store = store ?? ClipboardStore()
        self.configStore = configStore
        self.store = store
        self.pasteboard = pasteboard
        watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, config: { configStore.config.clipboard })
    }

    /// 按配置开始或停止记录。
    func applyConfig() {
        let cfg = configStore.config.clipboard
        store.setImageRecognition(enabled: cfg.enabled && cfg.recordImages)
        if cfg.enabled {
            watcher.start()
            store.trim(maxItems: cfg.maxItems)
        } else {
            watcher.stop()
            hide()
        }
    }

    var isVisible: Bool { panel.isVisible }
    /// 自测用
    var query: String { model.query }
    var confirmingClear: Bool { model.confirmingClear }
    /// 自测用：“全部清除”按钮上的一点，屏幕坐标（左上角为原点）
    var clearButtonPoint: CGPoint {
        let frame = panel.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let halfHeader = ClipboardPanelView.searchBarHeight / 2
        let y = model.opensAbove ? frame.minY + halfHeader : frame.maxY - halfHeader
        return CGPoint(x: frame.maxX - 16 - 20, y: primaryHeight - y)
    }
    /// 面板里当前显示的条目（自测用）。
    var visibleResults: [ClipboardItem] { model.results }

    /// 从文件搜索框里打开（Win+V）时：面板靠着搜索框，选中的文字直接填进搜索框，Esc 回到搜索框。
    struct Host {
        /// 面板所贴靠的搜索栏（AppKit 坐标）
        let anchor: NSRect
        /// 选中的文字（图片是 nil）
        let insert: (String?) -> Void
        /// 按 Esc 或再按 Win+V 关掉
        let back: () -> Void
        /// 点了别的地方，面板自己关掉
        let resigned: () -> Void
    }

    func show(in host: Host? = nil, at pointer: CGPoint = NSEvent.mouseLocation) {
        guard configStore.config.clipboard.enabled else { return }
        pendingPaste = nil
        // 已经开着：放到前面就行，保留正在输入的查询
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        pasteTarget = host == nil ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        let placement = placement(at: pointer, beside: host?.anchor)
        watcher.recordPendingChange()
        model.prepareForShow(opensAbove: placement.opensAbove)
        self.host = host
        previewOffset = nil
        panel.setFrame(placement.frame, display: false)
        FrontAppTracker.shared.clipboardPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Esc、再按一次 Win+V：关掉；从搜索框打开的回到搜索框
    func close() {
        let host = self.host
        self.host = nil
        hide()
        host?.back()
    }

    /// 关掉。从搜索框打开的，告诉它面板没了（点了别处、在设置里关掉了剪贴板历史），它自己决定接着用还是一起关
    func hide() {
        let host = self.host
        self.host = nil
        pasteTarget = nil
        removeKeyMonitor()
        FrontAppTracker.shared.clipboardPanelActive.set(false)
        if panel.isVisible {
            model.cancelTextCopy()
            panel.endEditing(for: nil)
            panel.orderOut(nil)
            model.setPreviewOpen(false)
        }
        host?.resigned()
    }

    /// 把选中的条目放进剪贴板，再模拟 ⌘V 粘贴到原来的应用里。
    func paste(_ item: ClipboardItem) {
        if let host {
            guard item.kind == .text, let text = item.text else {
                model.showFeedback(L("文件搜索框只能粘贴文字"))
                return
            }
            self.host = nil
            hide()
            store.markUsed(item.id)
            host.insert(text)
            return
        }
        guard write(item) else {
            model.showFeedback(L("未能写入剪贴板"))
            return
        }
        let target = pasteTarget
        let count = pasteboard.changeCount
        hide()
        store.markUsed(item.id)
        guard pasteboard.name == .general, let target, Permissions.accessibility else { return }
        let request = UUID()
        pendingPaste = request
        // 等面板消失、原来的窗口重新接收键盘输入，并且用户松开修饰键之后再粘贴。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            Synthetic.afterModifiersReleased {
                guard let self, self.pendingPaste == request else { return }
                self.pendingPaste = nil
                guard self.pasteboard.changeCount == count,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target else { return }
                Synthetic.tap(KeyStroke(KeyCode.v, .maskCommand))
            }
        }
    }

    private func copy(_ item: ClipboardItem) {
        model.showFeedback(write(item) ? L("已复制") : L("未能写入剪贴板"))
    }

    /// 写进剪贴板。图片文件丢失等原因写不了时返回 false，这时不能再粘贴，否则会贴出剪贴板里原有的东西。
    private func write(_ item: ClipboardItem) -> Bool {
        let pbItem = NSPasteboardItem()
        switch item.kind {
        case .text:
            pbItem.setString(item.text ?? "", forType: .string)
            for (type, data) in store.extraData(for: item) {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
        case .image:
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                Log.clipboard.error("找不到图片文件，无法写入剪贴板")
                return false
            }
            if url.pathExtension == "tiff" {
                pbItem.setData(data, forType: .tiff)
                if let png = ClipboardImage.png(fromTIFF: data) { pbItem.setData(png, forType: .png) }
            } else {
                pbItem.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation { pbItem.setData(tiff, forType: .tiff) }
            }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([pbItem]) else { return false }
        watcher.noteOwnWrite()
        return true
    }

    // MARK: - 面板

    private func makeModel() -> ClipboardPanelModel {
        let model = ClipboardPanelModel(store: store, pasteboard: pasteboard)
        model.onPaste = { [weak self] item in self?.paste(item) }
        model.onCopy = { [weak self] item in self?.copy(item) }
        model.onPreviewChange = { [weak self] open in self?.resizeForPreview(open) }
        model.onFloat = { [weak self] item in
            guard let self, let url = store.imageURL(for: item),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let png = url.pathExtension == "tiff" ? ClipboardImage.png(fromTIFF: data) : data,
                  let picture = PinPicture(png: png) else {
                NSSound.beep()
                return
            }
            hide()
            ScreenPins.shared.show(picture)
        }
        model.onClose = { [weak self] in self?.close() }
        return model
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        // 面板带隐藏的标题栏（为了圆角和阴影），不给它让位置，否则搜索框上面会空出一条
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }

    /// 面板快捷键在搜索框之前处理，组字时由输入法优先处理。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let key = CGKeyCode(event.keyCode)
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if key == KeyCode.escape, mods.isEmpty {
                self.model.cancel()
                return nil
            }
            if key == KeyCode.y, mods == .command {
                if !event.isARepeat {
                    if self.model.isPreviewOpen { self.model.cancel() }
                    else { self.model.setPreviewOpen(true) }
                }
                return nil
            }
            if key == KeyCode.c, mods == [.command, .shift] || mods == [.control, .shift],
               let item = self.model.selectedItem {
                if !event.isARepeat { self.model.onCopy(item) }
                return nil
            }
            if (key == KeyCode.returnKey || key == KeyCode.keypadEnter), mods == .shift,
               let item = self.model.selectedItem, item.kind == .text {
                self.model.pasteAsPlainText(item)
                return nil
            }
            if key == KeyCode.f3, mods.isEmpty, let item = self.model.selectedItem, item.kind == .image {
                self.model.onFloat(item)
                return nil
            }
            if key == KeyCode.p, mods == .command || mods == .control {
                if !event.isARepeat { self.model.togglePinSelected() }
                return nil
            }
            if self.model.handleDeleteShortcut(key, modifiers: mods, isRepeat: event.isARepeat) {
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 展开预览时优先留住列表的位置。右侧空间不够时向左移动，收起时回到展开前的位置。
    private func resizeForPreview(_ open: Bool) {
        guard panel.isVisible, let screen = panel.screen else { return }
        let inset = ClipboardPanelPlacement.screenInset
        let area = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        var frame = panel.frame
        if open {
            guard area.width >= ClipboardPanel.expandedWidth else { return }
            frame.size.width = ClipboardPanel.expandedWidth
            frame = WindowPlacement.fittedFrame(frame, in: area, centered: false)
            previewOffset = panel.frame.minX - frame.minX
        } else {
            guard let offset = previewOffset else { return }
            previewOffset = nil
            frame.origin.x += offset
            frame.size.width = ClipboardPanel.size.width
            frame = WindowPlacement.fittedFrame(frame, in: area, centered: false)
        }
        panel.setFrame(frame, display: true)
    }

    /// 优先贴着本程序的搜索框或正在输入的文字光标，其次跟随鼠标。
    private func placement(at pointer: CGPoint, beside given: NSRect?) -> ClipboardPanelPlacement {
        if let given, let hostScreen = WindowPlacement.screen(containing: CGPoint(x: given.midX, y: given.midY)) {
            return .init(anchor: given, gap: 4, visibleFrame: hostScreen.visibleFrame)
        }
        if let caret = CaretLocator.caretRect(),
           let screen = WindowPlacement.screen(containing: CGPoint(x: caret.minX, y: caret.midY)),
           caret.height <= screen.visibleFrame.height / 4 {
            return .init(anchor: caret, gap: 12, visibleFrame: screen.visibleFrame)
        }
        let visible = WindowPlacement.pointerScreen(at: pointer)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return .init(anchor: NSRect(origin: pointer, size: .zero), gap: 4, visibleFrame: visible)
    }
}

/// 通过辅助功能接口查询文字光标在屏幕上的位置。
enum CaretLocator {
    /// 返回 AppKit 坐标（原点在主屏幕左下角）。
    static func caretRect() -> NSRect? {
        guard Permissions.accessibility,
              let element = FocusInspector().focusedElement(), FocusInspector.focusKind(of: element) == .text,
              let primary = NSScreen.screens.first,
              let selected: CFRange = element.axValue(kAXSelectedTextRangeAttribute, type: .cfRange),
              selected.location >= 0, selected.length >= 0, selected.location < Int.max - selected.length
        else { return nil }

        // 选中文本时贴着选区末端。部分应用只返回有长度的文字范围。
        let end = selected.location + selected.length
        let rect: CGRect
        let x: CGFloat
        if let insertion = bounds(of: CFRange(location: end, length: 0), in: element) {
            rect = insertion
            x = insertion.minX
        } else if let next = bounds(of: CFRange(location: end, length: 1), in: element) {
            rect = next
            x = next.minX
        } else if end > 0, let previous = bounds(of: CFRange(location: end - 1, length: 1), in: element) {
            rect = previous
            x = previous.maxX
        } else {
            return nil
        }

        // 辅助功能接口的坐标原点在主屏幕左上角，y 向下。
        return NSRect(x: x, y: primary.frame.maxY - rect.maxY, width: 0, height: rect.height)
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &boundsValue
        ) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.minX.isFinite, rect.maxX.isFinite, rect.minY.isFinite, rect.maxY.isFinite, rect.height > 0
        else { return nil }
        return rect
    }
}
