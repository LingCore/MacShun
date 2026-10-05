// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Carbon
import SwiftUI

/// 剪贴板历史：记录、弹出面板、选中后粘贴（C1–C5）。只在主线程上使用。
final class ClipboardController {
    let store: ClipboardStore
    private let watcher: ClipboardWatcher
    private let configStore: ConfigStore
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var keyMonitor: Any?
    /// 从本程序的文件搜索框里打开时，选中的条目交给它
    private var host: Host?
    /// 打开面板前的输入法。搜索框只允许英文输入，系统可能因此切换输入法，关闭面板时切回来。
    private var savedInputSource: TISInputSource?

    init(configStore: ConfigStore, store: ClipboardStore = ClipboardStore()) {
        self.configStore = configStore
        self.store = store
        watcher = ClipboardWatcher(store: store, config: { configStore.config.clipboard })
    }

    /// 按配置开始或停止记录。
    func applyConfig() {
        let cfg = configStore.config.clipboard
        if cfg.enabled {
            watcher.start()
            store.trim(maxItems: cfg.maxItems)
        } else {
            watcher.stop()
            hide()
        }
    }

    var isVisible: Bool { panel.isVisible }
    /// 面板里当前显示的条目（自测用）。
    var visibleResults: [ClipboardItem] { model.results }

    /// 从文件搜索框里打开（Win+V）时：面板叠在搜索框下面，选中的文字直接填进搜索框，Esc 回到搜索框。
    struct Host {
        /// 面板放在这块区域下面（AppKit 坐标）
        let anchor: NSRect
        /// 选中的文字（图片是 nil）
        let insert: (String?) -> Void
        /// 按 Esc 或再按 Win+V 关掉
        let back: () -> Void
        /// 点了别的地方，面板自己关掉
        let resigned: () -> Void
    }

    func show(in host: Host? = nil) {
        guard configStore.config.clipboard.enabled else { return }
        // 已经开着：放到前面就行，别把原来的搜索框、输入法记录换掉
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        model.prepareForShow()
        self.host = host
        if let host { position(panel, below: host.anchor) } else { position(panel) }
        savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
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
        removeKeyMonitor()
        FrontAppTracker.shared.clipboardPanelActive.set(false)
        if panel.isVisible { panel.orderOut(nil) }
        restoreInputSource()
        host?.resigned()
    }

    private func restoreInputSource() {
        guard let saved = savedInputSource else { return }
        savedInputSource = nil
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if current.map({ CFEqual($0, saved) }) != true {
            TISSelectInputSource(saved)
        }
    }

    /// 把选中的条目放进剪贴板，再模拟 ⌘V 粘贴到原来的应用里。
    func paste(_ item: ClipboardItem) {
        if let host {
            self.host = nil
            hide()
            store.markUsed(item.id)
            host.insert(item.kind == .text ? item.text : nil)
            return
        }
        hide()
        guard write(item) else { return }
        store.markUsed(item.id)
        guard Permissions.accessibility else { return }
        // 等面板消失、原来的窗口重新接收键盘输入，并且用户松开修饰键之后再粘贴。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Synthetic.afterModifiersReleased {
                Synthetic.tap(KeyStroke(KeyCode.v, .maskCommand))
            }
        }
    }

    /// 写进剪贴板。图片文件丢失等原因写不了时返回 false，这时不能再粘贴，否则会贴出剪贴板里原有的东西。
    private func write(_ item: ClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
        let pbItem = NSPasteboardItem()
        switch item.kind {
        case .text:
            pbItem.setString(item.text ?? "", forType: .string)
            for (type, data) in store.extraData(for: item) {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
        case .image:
            guard let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) else {
                Log.clipboard.error("找不到图片文件，无法粘贴")
                return false
            }
            pbItem.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pbItem.setData(tiff, forType: .tiff)
            }
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([pbItem])
        watcher.noteOwnWrite()
        return true
    }

    // MARK: - 面板

    private func makeModel() -> ClipboardPanelModel {
        let model = ClipboardPanelModel(store: store)
        model.onPaste = { [weak self] item in self?.paste(item) }
        model.onClose = { [weak self] in self?.close() }
        return model
    }

    private func makePanel() -> ClipboardPanel {
        let panel = ClipboardPanel()
        panel.contentView = NSHostingView(rootView: ClipboardPanelView(model: model))
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }

    /// 固定、删除这两个快捷键在搜索框之前处理。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            let key = CGKeyCode(event.keyCode)
            if key == KeyCode.p, mods == .command || mods == .control {
                self.model.togglePinSelected()
                return nil
            }
            if key == KeyCode.forwardDelete && !mods.isEmpty || key == KeyCode.backspace && mods == .command {
                self.model.deleteSelected()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 放在文字光标下方；问不到光标位置时放在鼠标指针旁边。
    private func position(_ panel: NSPanel, below given: NSRect? = nil) {
        let size = panel.frame.size
        let anchor = given ?? CaretLocator.caretRect() ?? {
            let mouse = NSEvent.mouseLocation
            return NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        }()
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 6  // 下方放不下就放到上方
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// 通过辅助功能接口查询文字光标在屏幕上的位置。
enum CaretLocator {
    /// 返回 AppKit 坐标（原点在主屏幕左下角）。
    static func caretRect() -> NSRect? {
        guard Permissions.accessibility,
              let element = FocusInspector().focusedElement()
        else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue
        else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue
        ) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.origin != .zero else { return nil }

        // 辅助功能接口的坐标原点在主屏幕左上角，y 向下。
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - rect.maxY
        return NSRect(x: rect.minX, y: flippedY, width: rect.width, height: max(rect.height, 1))
    }
}
