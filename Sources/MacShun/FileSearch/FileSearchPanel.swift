// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CompactSearchHeights: Equatable {
    var fileTypes: CGFloat = 0
    var results: CGFloat = 0
}

struct CompactSearchPresentation: Equatable {
    var visible: CompactSearchHeights
    var target: CompactSearchHeights
    var fileTypesOpacity: Double

    init(visible: CompactSearchHeights, target: CompactSearchHeights) {
        self.visible = visible
        self.target = target
        fileTypesOpacity = visible.fileTypes > 0 ? 1 : 0
    }
}

/// 文件搜索（F1、F2）：连按两下 Ctrl 弹出胶囊形的搜索框，边打字边出结果，按文件名和文件内容搜。只在主线程上使用。
@MainActor
final class FileSearchController {
    private let configStore: ConfigStore
    private let history = OpenHistory()
    private let index = FileIndex.shared
    private let contentIndex = ContentIndex.shared
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var modelLoaded = false
    private var panelLoaded = false
    private var subscriptions: Set<AnyCancellable> = []
    /// 接住 Ctrl+Enter 的事件监听（见 makePanel）
    private var keyMonitor: Any?
    /// 剪贴板面板正叠在搜索框上（见 clipboardHost）
    private var hostingClipboard = false
    private var showingModal = false
    private var windowPosition: FileSearchWindowPosition?
    private var expandedGeometry: FileSearchExpandedGeometry?
    private var fileTypesFade: Task<Void, Never>?
    private var dialog: FileDialogTarget?
    private var dialogNavigation: Task<Void, Never>?
    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        fileTypesFade?.cancel()
        dialogNavigation?.cancel()
    }

    /// 按配置开始或停止建立索引。
    func applyConfig() {
        let cfg = configStore.config.fileSearch
        index.setIndexedLocations(cfg.indexedLocations)
        if modelLoaded { model.indexedLocations = cfg.indexedLocations }
        if index.includeExternalDrives != cfg.includeExternalDrives {
            index.includeExternalDrives = cfg.includeExternalDrives
            if cfg.enabled && cfg.activated && (index.isIndexing || index.lastIndexed != nil) { index.rebuild() }
        }
        // 认不认图片文字变了：重新扫一遍，把图片交给内容索引，或者从内容索引里去掉。
        // 要在 start 之前设好：启动时不然会先按默认值扫一遍、马上又重扫一遍
        if ContentExtractor.readsImages.get() != cfg.searchImageText {
            ContentExtractor.readsImages.set(cfg.searchImageText)
            if cfg.searchImageText { contentIndex.forgetTextlessPDFs() }
            if cfg.enabled && cfg.activated && cfg.searchContents && (index.isIndexing || index.lastIndexed != nil) {
                index.rebuild()
            }
        }
        if cfg.enabled && cfg.activated {
            index.start()
        } else if !cfg.enabled {
            index.stop()
            hide()
            history.clear()
        }
        // 内容索引里有文件的原文，不用了就删掉
        let searchesContent = cfg.enabled && cfg.activated && cfg.searchContents
        if searchesContent {
            contentIndex.start()
            index.setContentIndex(contentIndex)
        } else {
            index.setContentIndex(nil)
            contentIndex.stop(deleteData: true)
        }
        if modelLoaded { model.searchesContent = searchesContent }
    }

    var isVisible: Bool { panelLoaded && panel.isVisible }
    /// 自测用
    var currentQuery: String { model.query }
    var isKey: Bool { panelLoaded && panel.isKeyWindow }
    var visibleResults: [FileSearchResult] { model.results }
    var selectedIndex: Int { model.selection }
    var windowNumber: Int { panel.windowNumber }
    var confirmingDelete: String? { model.confirmingDelete }

    /// 自测用：某一条结果上某个按钮的中心在屏幕上的位置（左上角为原点）；按钮没显示时为 nil
    func buttonCenter(_ button: FileRowButton, for path: String) -> CGPoint? {
        guard let rect = model.buttonFrames[.init(path: path, button: button)] else { return nil }
        let frame = panel.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.minX + rect.midX, y: primaryHeight - (frame.maxY - rect.midY))
    }

    /// 自测用：按钮里靠左边缘一点的颜色（避开文字），看鼠标停在上面时底色变没变
    func buttonFill(_ button: FileRowButton, for path: String) -> NSColor? {
        guard let rect = model.buttonFrames[.init(path: path, button: button)], let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        return rep.colorAt(x: Int((rect.minX + 3) * scale), y: Int(rect.midY * scale))?.usingColorSpace(.deviceRGB)
    }

    /// 自测用：第几条结果的中心在屏幕上的位置（左上角为原点）。只在没往下滚、只有文件名结果时准
    func rowCenter(_ index: Int) -> CGPoint {
        let frame = panel.frame
        let header = FileSearchView.compactHeaderHeight(inFolder: model.folder != nil, typeAreaHeight: model.compactLayout.visible.fileTypes)
        let top = FileSearchView.margin + header + FileSearchView.gap + FileSearchView.listPadding
            + (CGFloat(index) + 0.5) * FileSearchView.rowHeight
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.minX + 200, y: primaryHeight - (frame.maxY - top))
    }

    /// 在搜索框里按 Win+V：剪贴板面板贴着搜索栏，选中的文字填到光标处，关掉以后回到搜索框。
    func clipboardHost() -> ClipboardController.Host {
        let frame = panel.frame
        let margin = FileSearchView.margin
        let height = FileSearchView.inputHeaderHeight(expanded: model.isExpanded)
            + (model.folder == nil ? 0 : FileSearchView.folderBarHeight)
        let anchor = NSRect(x: frame.minX + margin, y: frame.maxY - margin - height,
                            width: frame.width - 2 * margin, height: height)
        hostingClipboard = true
        return .init(
            anchor: anchor,
            insert: { [weak self] text in
                self?.hostingClipboard = false
                self?.insert(text)
            },
            back: { [weak self] in
                self?.hostingClipboard = false
                self?.refocus()
            },
            resigned: { [weak self] in
                self?.hostingClipboard = false
                // 点回了搜索框就接着用；点了别的程序，搜索框也关掉
                DispatchQueue.main.async {
                    guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
                    self.hide()
                }
            }
        )
    }

    private func refocus() {
        guard panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    /// 剪贴板历史里选的文字插到光标处。搜索框只有一行，换行换成空格。
    private func insert(_ text: String?) {
        refocus()
        let line = (text ?? "").components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if let editor = panel.firstResponder as? NSTextView {
            editor.insertText(line, replacementRange: editor.selectedRange())
        } else {
            model.query += line
        }
    }

    /// 连按两下 Ctrl 打开；已经开着就保留查询，必要时移到指针所在屏幕。
    func summon(at pointer: CGPoint = NSEvent.mouseLocation) {
        guard !showingModal else { return }
        guard panelLoaded && panel.isVisible else { show(at: pointer); return }
        if !panel.isDraggingFromHandle, let screen = WindowPlacement.pointerScreen(at: pointer),
           windowPosition.map({ $0.isOn(screen.frame) }) != true {
            position(on: screen)
            resize()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func show(at pointer: CGPoint = NSEvent.mouseLocation) {
        guard configStore.config.fileSearch.enabled else { return }
        cancelFileTypesFade()
        let screen = WindowPlacement.pointerScreen(at: pointer)
        if !configStore.config.fileSearch.activated {
            configStore.config.fileSearch.activated = true
        }
        index.includeExternalDrives = configStore.config.fileSearch.includeExternalDrives
        index.setIndexedLocations(configStore.config.fileSearch.indexedLocations)
        model.indexedLocations = configStore.config.fileSearch.indexedLocations
        index.start()
        dialogNavigation?.cancel()
        dialog = FileDialogTarget.focused()
        model.finderFolder = dialog == nil ? FinderSearchFolder.current() : nil
        model.prepareForShow(inFileDialog: dialog != nil)
        let target = model.preferredCompactHeights
        model.compactPresentation = .init(visible: animatesCompactTypeStrip ? .init() : target, target: target)
        model.isShown = true
        if !SelfTest.isRequested, let data = UserDefaults.standard.data(forKey: FileSearchExpandedGeometry.defaultsKey),
           let saved = try? JSONDecoder().decode(FileSearchExpandedGeometry.self, from: data),
           saved.size.width.isFinite, saved.size.width > 0, saved.size.height.isFinite, saved.size.height > 0 {
            expandedGeometry = saved
        }
        position(on: screen)
        FrontAppTracker.shared.fileSearchPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
        resize()
    }

    func hide() {
        FrontAppTracker.shared.fileSearchPanelActive.set(false)
        cancelFileTypesFade()
        guard panelLoaded || modelLoaded else {
            dialog = nil
            return
        }
        if panelLoaded { panel.endHandleDrag() }
        // 先关闭模型状态（停止在途搜索并拆除 QuickLook），再隐藏窗口；避免窗口先隐掉导致 QLPreviewView 析构顺序异常。
        if modelLoaded { model.isShown = false }
        if panelLoaded && panel.isVisible {
            // orderOut 会保留正在组字的编辑器；下次打开面板应从空查询开始。
            panel.endEditing(for: nil)
            panel.orderOut(nil)
        }
        dialog = nil
    }

    /// 打开、在访达中显示，和右键菜单、结果右边按钮里的操作。除了移到废纸篓，做完都关掉搜索框。
    private func perform(_ action: FileAction, on result: FileSearchResult) {
        let url = result.fileURL
        if case .goToFolder = action {
            guard let dialog else { return }
            hide()
            dialogNavigation = Task {
                let destination = await Task.detached(priority: .userInitiated) { FileDialogTarget.folder(for: url) }.value
                guard !Task.isCancelled else { return }
                guard let destination else { NSSound.beep(); return }
                switch await dialog.navigate(to: destination) {
                case .submitted: history.record(result.path)
                case .readyForConfirmation: break
                case .interrupted: if !Task.isCancelled { NSSound.beep() }
                }
            }
            return
        }
        if case .trash = action { return trash(url) }
        hide()
        history.record(result.path)
        switch action {
        case .open:
            NSWorkspace.shared.open(url)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openWith(let app):
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .copy:
            // 文件本身，可以粘贴到访达、聊天窗口里
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.path, forType: .string)
        case .goToFolder, .trash:
            break
        }
    }

    /// 移到废纸篓：搜索框不关，这一条马上从结果里拿掉
    private func trash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.app.error("文件搜索：移到废纸篓失败：\(error.localizedDescription, privacy: .public)")
                    NSSound.beep()
                    return
                }
                guard let self else { return }
                self.model.remove(url.path)
                // 不等 FSEvents（要一秒左右），免得接着打字时又搜出来
                self.index.refresh(folder: url.deletingLastPathComponent().path)
            }
        }
    }

    // MARK: - 面板

    private func makeModel() -> FileSearchModel {
        modelLoaded = true
        let cfg = configStore.config.fileSearch
        let model = FileSearchModel(index: index, contentIndex: contentIndex, pinDefaults: SelfTest.isRequested ? nil : .standard)
        model.indexedLocations = cfg.indexedLocations
        model.searchesContent = cfg.enabled && cfg.activated && cfg.searchContents
        model.history = history
        model.onAction = { [weak self] result, action in self?.perform(action, on: result) }
        model.onFeature = { [weak self] feature in
            if NSWorkspace.shared.open(feature.destination.url) { self?.hide() }
            else { NSSound.beep() }
        }
        model.onClose = { [weak self] in self?.hide() }
        model.onShowResultMenu = { [weak self] in self?.showResultMenu() }
        model.onChooseFolder = { [weak self] in self?.chooseFolder() }
        model.onAddLocation = { [weak self] path in
            guard let self else { return }
            guard let location = self.index.makeLocation(for: path) else {
                self.showSearchAlert(L("请选择本机文件夹或已挂载的 SMB 共享"))
                return
            }
            self.configStore.config.fileSearch.addIndexedLocation(location)
        }
        model.onSaveFilters = { [weak self] in self?.saveFilters() }
        model.onEditBounds = { [weak self] kind in self?.editBounds(kind) }
        // 结果多少变了，面板跟着变高变矮
        model.$rows.combineLatest(model.$query, index.$isIndexing, model.$searchingContent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &subscriptions)
        model.$isPreviewing.combineLatest(model.$folder, model.$isExpanded, model.$scope)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &subscriptions)
        return model
    }

    private func makePanel() -> FileSearchPanel {
        panelLoaded = true
        let panel = FileSearchPanel()
        let host = NSHostingView(rootView: FileSearchView(model: model, index: index, contentIndex: contentIndex))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onHandleDragEnded = { [weak self, weak panel] moved in
            guard let self, let panel else { return }
            if moved { self.rememberGeometry(of: panel, resized: panel.lastHandleDragWasResize) }
            else { self.resize() }
        }
        // 在搜索框里按 Win+V 打开的剪贴板面板叠在上面时不关
        panel.onResignKey = { [weak self] in
            guard let self, !self.hostingClipboard, !self.showingModal else { return }
            self.hide()
        }
        // Ctrl+Enter 是系统“显示快捷菜单”的快捷键：系统在把按键交给窗口之前就处理了，输入框上会弹出右键菜单。
        // 本程序的事件监听在那之前，在这里接住。⌘+Enter 输入框不处理，也在这里接。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel, !self.showingModal else { return event }
            let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
            if !composing {
                if self.model.handleQuickLookKey(event) { return nil }
                if self.model.handlePanelKey(event) { return nil }
                if self.model.handleFolderKey(event) { return nil }
            }
            guard Self.isRevealKey(event) else { return event }
            // 输入法还在拼字时交给输入法（放过去的话系统会弹出右键菜单）
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                _ = editor.inputContext?.handleEvent(event)
                return nil
            }
            self.model.openSelected(reveal: true)
            return nil
        }
        return panel
    }

    private func showResultMenu() {
        guard !showingModal, panel.isKeyWindow, let view = panel.contentView,
              (panel.firstResponder as? NSTextView)?.hasMarkedText() != true,
              let menu = model.contextMenuForSelection() else { return }
        let point: NSPoint
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.window === panel {
            point = view.convert(event.locationInWindow, from: nil)
        } else {
            let inset = FileSearchView.margin + 12
            point = NSPoint(x: view.bounds.minX + inset,
                            y: view.isFlipped ? view.bounds.maxY - inset : view.bounds.minY + inset)
        }
        showingModal = true
        menu.popUp(positioning: nil, at: point, in: view)
        showingModal = false
        if panel.isKeyWindow { model.focusSearch() }
        else if panel.isVisible { hide() }
    }

    private func chooseFolder() {
        guard !showingModal else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = false
        picker.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        picker.prompt = L("选择文件夹")
        picker.directoryURL = (model.searchFolder?.path ?? model.finderFolder?.path)
            .map { URL(fileURLWithPath: index.resolvedLocationPath($0), isDirectory: true) }
        showingModal = true
        let response = picker.runModal()
        showingModal = false
        guard panel.isVisible else { return }
        if response == .OK, let url = picker.url { model.setFilterFolder(url.standardizedFileURL.path) }
        panel.makeKeyAndOrderFront(nil)
        model.focusSearch()
    }

    private func saveFilters() {
        guard !showingModal else { return }
        let alert = NSAlert()
        alert.messageText = L("保存当前筛选")
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("取消"))
        let name = NSTextField(string: "")
        name.placeholderString = L("筛选名称")
        name.setAccessibilityLabel(L("筛选名称"))
        name.frame.size.width = 240
        alert.accessoryView = name
        alert.window.initialFirstResponder = name
        alert.window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        showingModal = true
        let response = alert.runModal()
        showingModal = false
        if response == .alertFirstButtonReturn, !model.saveFilters(named: name.stringValue) {
            showSearchAlert(L("请输入未使用的筛选名称"))
        }
        if panel.isVisible { refocus(); model.focusSearch() }
    }

    private func showSearchAlert(_ title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L("好"))
        alert.window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        showingModal = true
        alert.runModal()
        showingModal = false
        if panel.isVisible { refocus(); model.focusSearch() }
    }

    private func editBounds(_ kind: FileSearchRangeKind) {
        guard !showingModal else { return }
        let current = kind == .date ? model.panelOptions.dateBounds : model.panelOptions.sizeBounds
        let lower = NSTextField(string: kind.label(current?.lower))
        let upper = NSTextField(string: kind.label(current?.upper))
        lower.placeholderString = kind.lowerPlaceholder
        upper.placeholderString = kind.upperPlaceholder
        lower.setAccessibilityLabel(kind.lowerPlaceholder)
        upper.setAccessibilityLabel(kind.upperPlaceholder)
        let fields = NSStackView(views: [lower, upper])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.distribution = .fillEqually
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 245, height: 52)
        lower.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        upper.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        lower.nextKeyView = upper
        upper.nextKeyView = lower

        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = L("可以只填写其中一项。")
        alert.addButton(withTitle: L("应用筛选"))
        alert.addButton(withTitle: L("取消"))
        alert.accessoryView = fields
        alert.window.initialFirstResponder = lower
        alert.window.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
        showingModal = true
        while alert.runModal() == .alertFirstButtonReturn {
            if let bounds = kind.parse(lower: lower.stringValue, upper: upper.stringValue) {
                var options = model.panelOptions
                if kind == .date {
                    options.dateBounds = bounds
                    options.modified = .custom
                } else {
                    options.sizeBounds = bounds
                    options.size = .custom
                }
                model.panelOptions = options
                break
            }
            alert.informativeText = L("请填写有效范围，起始值不能大于结束值。")
        }
        showingModal = false
        if panel.isVisible { refocus(); model.focusSearch() }
    }

    /// Ctrl+Enter、⌘+Enter：在访达中显示
    static func isRevealKey(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.intersection([.control, .command]).isEmpty
    }

    private var preferredHeight: CGFloat {
        if model.isExpanded { return expandedGeometry?.size.height ?? FileSearchExpandedGeometry.defaultSize.height }
        let visible = model.compactLayout.visible
        let header = FileSearchView.compactHeaderHeight(inFolder: model.folder != nil, typeAreaHeight: visible.fileTypes)
        return header + FileSearchView.margin * 2 + visible.results
    }

    private func resize() {
        guard panel.isVisible, !panel.isDraggingFromHandle, let windowPosition else { return }
        let screen = screenForCompactWindow(at: windowPosition)
        updateCompactPresentation(at: windowPosition, on: screen)
        resizeToContent()
    }

    private var animatesCompactTypeStrip: Bool {
        !SelfTest.isRequested && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func updateCompactPresentation(at position: FileSearchWindowPosition, on screen: NSScreen?) {
        var target = model.preferredCompactHeights
        if let workArea = screen?.visibleFrame, !model.isExpanded {
            let header = FileSearchView.compactHeaderHeight(inFolder: model.folder != nil, typeAreaHeight: target.fileTypes)
                + FileSearchView.margin * 2
            let usableBelow = min(position.point.y, workArea.maxY) - workArea.minY
            // Allow one row and its footer even at the bottom of a display. More rows scroll inside that space.
            let minimum = header + min(target.results, FileSearchView.minimumResultAreaHeight)
            let available = min(workArea.height, max(usableBelow, minimum))
            target.results = min(target.results, max(0, available - header))
        }

        let previous = model.compactLayout
        let settled = CompactSearchPresentation(visible: target, target: target)
        guard !model.isExpanded, model.folder == nil, !model.isPreviewing, animatesCompactTypeStrip else {
            cancelFileTypesFade()
            if previous != settled { model.compactPresentation = settled }
            return
        }

        var layout = previous
        layout.target = target
        layout.visible.results = target.results
        if fileTypesFade != nil && previous.target.fileTypes == target.fileTypes {
            if layout != previous { model.compactPresentation = layout }
            return
        }
        cancelFileTypesFade()
        let from = previous.fileTypesOpacity
        let to = settled.fileTypesOpacity
        guard from != to else {
            if previous != settled { model.compactPresentation = settled }
            return
        }
        // 类型栏的内容保持完整高度，只做一次短淡化。结果高度直接跟随当前查询。
        layout.visible.fileTypes = max(previous.visible.fileTypes, target.fileTypes)
        model.compactPresentation = layout
        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = max(0.04, 0.11 * abs(to - from))
        fileTypesFade = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.panel.isVisible else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - startedAt) / duration)
                let remaining = 1 - progress
                var frame = self.model.compactLayout
                frame.fileTypesOpacity = progress == 1 ? to : from + (to - from) * (1 - remaining * remaining)
                if progress == 1 { frame.visible.fileTypes = frame.target.fileTypes }
                if frame != self.model.compactLayout { self.model.compactPresentation = frame }
                if progress == 1 {
                    self.fileTypesFade = nil
                    self.resizeToContent()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func cancelFileTypesFade() {
        fileTypesFade?.cancel()
        fileTypesFade = nil
    }

    private func screenForCompactWindow(at position: FileSearchWindowPosition) -> NSScreen? {
        NSScreen.screens.first { position.isOn($0.frame) } ?? panel.screen ?? NSScreen.main
    }

    private func resizeToContent() {
        guard panel.isVisible, !panel.isDraggingFromHandle, let windowPosition else { return }
        let frame = searchFrame(compact: windowPosition, on: screenForCompactWindow(at: windowPosition))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private static let fallbackWorkArea = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func searchFrame(compact: FileSearchWindowPosition, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? Self.fallbackWorkArea
        let height = preferredHeight
        if model.isExpanded {
            let geometry = expandedGeometry
            let width = geometry?.size.width ?? FileSearchExpandedGeometry.defaultSize.width
            let position: FileSearchWindowPosition
            if let saved = geometry?.position, let screen, saved.isOn(screen.frame) {
                position = saved
            } else {
                position = .init(point: CGPoint(x: visible.midX, y: visible.midY + height / 2))
            }
            return position.frame(size: CGSize(width: width, height: height), in: visible)
        }
        return compact.frame(size: CGSize(width: FileSearchPanel.width, height: height), in: visible)
    }

    /// 只在当前屏幕上恢复拖放位置，避免窗口被另一块屏幕的旧位置拉走。
    private func compactPosition(on screen: NSScreen?) -> FileSearchWindowPosition {
        if !SelfTest.isRequested,
           let screen,
           let data = UserDefaults.standard.data(forKey: FileSearchWindowPosition.defaultsKey),
           let saved = try? JSONDecoder().decode(FileSearchWindowPosition.self, from: data),
           saved.isOn(screen.frame) {
            return saved
        }
        let visible = screen?.visibleFrame ?? Self.fallbackWorkArea
        return .init(point: CGPoint(x: visible.midX, y: visible.maxY - visible.height * 0.22))
    }

    private func position(on screen: NSScreen?) {
        let position = compactPosition(on: screen)
        windowPosition = position
        panel.setFrame(searchFrame(compact: position, on: screen), display: panel.isVisible)
    }

    private func rememberGeometry(of panel: FileSearchPanel, resized: Bool) {
        let raw = FileSearchWindowPosition(frame: panel.frame)
        let screen = screenForCompactWindow(at: raw)
        let position = FileSearchWindowPosition(frame: raw.frame(size: panel.frame.size,
                                                                 in: screen?.visibleFrame ?? Self.fallbackWorkArea))
        if model.isExpanded {
            if let screen, windowPosition.map({ $0.isOn(screen.frame) }) != true {
                windowPosition = compactPosition(on: screen)
            }
            let size = resized ? panel.frame.size : (expandedGeometry?.size ?? FileSearchExpandedGeometry.defaultSize)
            expandedGeometry = FileSearchExpandedGeometry(position: position, size: size)
            resize()
            let geometry = FileSearchExpandedGeometry(position: FileSearchWindowPosition(frame: panel.frame), size: size)
            expandedGeometry = geometry
            saveGeometry(geometry, key: FileSearchExpandedGeometry.defaultsKey)
        } else {
            windowPosition = position
            resize()
            let adjusted = FileSearchWindowPosition(frame: panel.frame)
            windowPosition = adjusted
            saveGeometry(adjusted, key: FileSearchWindowPosition.defaultsKey)
        }
    }

    private func saveGeometry<T: Encodable>(_ geometry: T, key: String) {
        if !SelfTest.isRequested, let data = try? JSONEncoder().encode(geometry) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 无边框、透明的浮动面板，形状由里面的界面画出来。
final class FileSearchPanel: NSPanel {
    static let width: CGFloat = 640
    var onResignKey: (() -> Void)?
    var onHandleDragEnded: ((Bool) -> Void)?
    private var handleDrag: (pointer: NSPoint, frame: NSRect, resizeArea: NSRect?, onRelease: (() -> Void)?)?
    private(set) var lastHandleDragWasResize = false
    var isDraggingFromHandle: Bool { handleDrag != nil }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: FileSearchView.capsuleHeight + 24),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // 阴影由界面自己画，跟着胶囊的形状
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func beginHandleDrag(at pointer: NSPoint, resizing: Bool = false, onRelease: (() -> Void)? = nil) {
        handleDrag = (pointer, frame, resizing ? screen?.visibleFrame : nil, onRelease)
    }

    func updateHandleDrag(to pointer: NSPoint) {
        guard let drag = handleDrag else { return }
        let delta = CGSize(width: pointer.x - drag.pointer.x, height: pointer.y - drag.pointer.y)
        if let visible = drag.resizeArea {
            setFrame(FileSearchExpandedGeometry.resizedFrame(drag.frame, by: delta, in: visible), display: true)
        } else {
            setFrameOrigin(NSPoint(x: drag.frame.minX + delta.width, y: drag.frame.minY + delta.height))
        }
    }

    func endHandleDrag() {
        guard let drag = handleDrag else { return }
        handleDrag = nil
        lastHandleDragWasResize = drag.resizeArea != nil
        onHandleDragEnded?(frame != drag.frame)
        drag.onRelease?()
    }

    override func sendEvent(_ event: NSEvent) {
        if isDraggingFromHandle {
            switch event.type {
            case .leftMouseDragged:
                updateHandleDrag(to: convertPoint(toScreen: event.locationInWindow))
                return
            case .leftMouseUp:
                endHandleDrag()
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// 默认按文件名与系统功能搜索；“全部”另含文件正文。
enum FileSearchScope: Int, CaseIterable, Identifiable {
    case all, files, contents, system

    var id: Int { rawValue }

    func title(inFolder: Bool) -> String { inFolder && self == .files ? L("文件") : title }

    var title: String {
        switch self {
        case .all: L("全部")
        case .files: L("文件与功能")
        case .contents: L("内容")
        case .system: L("系统")
        }
    }
}

/// 对一条结果做的事：Enter、Ctrl+Enter、右键菜单和结果右边的按钮里的。
enum FileAction {
    case open, goToFolder, reveal, openWith(URL), copy, copyPath, trash
}

/// 结果右边的按钮：定位（在访达中显示）、复制、删除（移到废纸篓）
enum FileRowButton: Hashable {
    case reveal, copy, delete

    /// 哪一条上的哪个按钮
    struct Slot: Hashable {
        let path: String
        let button: FileRowButton
    }
}

/// 搜索框的数据和操作。
@MainActor
final class FileSearchModel: ObservableObject {
    @Published var query = "" {
        didSet {
            if !changingFolder { pageLimit = Self.pageSize }
            closeQuickLook(refocus: false)
            cancelDelete()
            pendingSelectionAction = nil
            pendingStaleClear?.cancel()
            pendingStaleClear = nil
            invalidateContentSearch()
            parsedQuery = FileMatcher.Query(query)
            directoryStatus = nil
            restoreFolderSelection = nil
            updateFeatures()
            let keepPreviousFiles = !changingFolder && searchesNames && !hasConflictingFolders
                && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && featureResults.isEmpty && !rows.isEmpty && rows.allSatisfy { $0.file != nil }
            if keepPreviousFiles {
                searchNames(resetSelection: true)
                if activeNameSearch != nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.waitingForNames else { return }
                        self.merge(resetSelection: true)
                    }
                    pendingStaleClear = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
                } else {
                    merge(resetSelection: true)
                }
            } else {
                merge(resetSelection: true)
                searchNames(resetSelection: false)
            }
            scheduleContentSearch()
        }
    }
    /// 明确匹配的系统功能、文件名、文件正文，各自保留类型与操作。
    @Published private(set) var rows: [LauncherRow] = [] {
        didSet { duplicateFolderLabels = Self.folderLabels(for: rows) }
    }
    private(set) var duplicateFolderLabels: [String: String] = [:]

    /// 从父目录名开始，只有重名的路径才多显示一级。根目录与另一条路径的同名后缀也能区分。
    private static func folderLabels(for rows: [LauncherRow]) -> [String: String] {
        var labels: [String: String] = [:]
        let groups = Dictionary(grouping: rows.compactMap(\.file), by: \.name)
        for matches in groups.values where matches.count > 1 {
            let byParent = Dictionary(grouping: matches) { ($0.path as NSString).deletingLastPathComponent }
            guard byParent.count > 1 else { continue }
            var remaining = byParent.keys.map { (path: $0, parts: $0.split(separator: "/")) }
            var depth = 1
            while !remaining.isEmpty {
                let bySuffix = Dictionary(grouping: remaining) { parent in
                    parent.parts.count < depth ? parent.path : parent.parts.suffix(depth).joined(separator: "/")
                }
                remaining.removeAll(keepingCapacity: true)
                for (suffix, parents) in bySuffix {
                    if parents.count == 1, let parent = parents.first {
                        for file in byParent[parent.path] ?? [] { labels[file.path] = suffix }
                    } else {
                        remaining.append(contentsOf: parents)
                    }
                }
                depth += 1
            }
        }
        return labels
    }
    /// File-only view used by file search diagnostics.
    var results: [FileSearchResult] { rows.compactMap(\.file) }
    private var featureResults: [SystemFeature] = []
    @Published var selection = 0
    @Published private(set) var isPreviewing = false
    @Published private(set) var focusToken = 0
    @Published private(set) var isExpanded = false
    private let panelDefaults: UserDefaults?
    @Published var showsPanelFilters = true {
        didSet { panelDefaults?.set(showsPanelFilters, forKey: "fileSearch.panelFiltersVisible") }
    }
    @Published var filtersOnTop = false {
        didSet { panelDefaults?.set(filtersOnTop, forKey: "fileSearch.panelFiltersOnTop") }
    }
    @Published var panelOptions = FileSearchOptions() {
        didSet { if panelOptions != oldValue && !changingFolder { refreshPanelFilters() } }
    }
    // A choice in the compact type strip belongs to the Files scope. The expanded filters can apply across scopes.
    private var fileScopeKinds = false
    @Published private(set) var filterFolder: FileSearchFolder?
    @Published private(set) var selectedFolderIsIndexed: Bool?
    @Published var indexedLocations: [FileSearchLocation] = [] {
        didSet { if indexedLocations != oldValue { refreshFolderCoverage() } }
    }
    private var usesPanelResults = false
    private static let pageSize = 60
    private var pageLimit = FileSearchModel.pageSize
    @Published private(set) var hasMoreResults = false
    var hasPanelFilters: Bool { appliedPanelOptions.hasFilters || filterFolder != nil }
    var appliedPanelOptions: FileSearchOptions {
        var options = panelOptions
        if fileScopeKinds && effectiveScope != .files { options.toggle(.any) }
        return options
    }
    var searchFolder: FileSearchFolder? {
        guard let folder, let filterFolder else { return folder ?? filterFolder }
        return SearchVolume.contains(index.resolvedLocationPath(filterFolder.path), under: index.resolvedLocationPath(folder.path))
            ? filterFolder : folder
    }
    private var hasConflictingFolders: Bool {
        guard let folder, let filterFolder else { return false }
        let project = index.resolvedLocationPath(folder.path)
        let filter = index.resolvedLocationPath(filterFolder.path)
        return !SearchVolume.contains(filter, under: project) && !SearchVolume.contains(project, under: filter)
    }
    private var searchOptions: FileSearchOptions {
        var options = appliedPanelOptions
        options.showsMetadata = isExpanded
        options.recursive = filterFolder != nil
        return options
    }
    @Published var searchesContent = false {
        didSet {
            guard searchesContent != oldValue else { return }
            if !availableScopes.contains(scope) { scope = .files }
            else { refreshScope() }
        }
    }
    @Published var scope: FileSearchScope = .files {
        didSet { if scope != oldValue && !changingFolder { refreshScope() } }
    }
    @Published private(set) var folder: FileSearchFolder?
    private struct ReturnPoint {
        let path: String?
        let query: String
        let scope: FileSearchScope
        let selection: LauncherRow.ID
        let limit: Int
    }
    private var returnPoints: [ReturnPoint] = []
    private var changingFolder = false
    private var restoreFolderSelection: LauncherRow.ID?
    var returnsToProjects: Bool {
        if case .project? = returnPoints.last?.selection { return true }
        return false
    }

    @Published private(set) var inFileDialog = false
    private var primaryAction: FileAction { inFileDialog ? .goToFolder : .open }
    var includesSystemFeatures: Bool { folder == nil && !inFileDialog }

    var availableScopes: [FileSearchScope] {
        if inFileDialog && folder == nil { return searchesContent ? [.all, .files, .contents] : [.files] }
        guard let folder else { return searchesContent ? FileSearchScope.allCases : [.files, .system] }
        return searchesContent && FileIndex.indexesContents(in: folder.path) ? [.all, .files, .contents] : [.files]
    }
    var effectiveScope: FileSearchScope { availableScopes.contains(scope) ? scope : .files }
    var searchesNames: Bool { effectiveScope == .all || effectiveScope == .files }
    @Published var compactPresentation: CompactSearchPresentation?
    var preferredCompactHeights: CompactSearchHeights {
        guard !isExpanded else { return .init() }
        let showsFileTypes = folder == nil && !inFileDialog && effectiveScope == .files
        return .init(fileTypes: showsFileTypes ? FileSearchView.fileTypeAreaHeight : 0,
                     results: FileSearchView.resultAreaHeight(resultCount: rows.count, hasSectionHeader: showsPinnedFolders || contentStart != nil,
                                                             showsStatus: showsStatus, previewing: isPreviewing))
    }
    var compactLayout: CompactSearchPresentation {
        if let compactPresentation { return compactPresentation }
        let preferred = preferredCompactHeights
        return .init(visible: preferred, target: preferred)
    }

    private func updateFeatures() {
        featureResults = includesSystemFeatures && effectiveScope != .contents && parsedQuery.isPlainName && parsedQuery.filters.isEmpty
            && (!hasPanelFilters || effectiveScope == .system)
            ? SystemFeature.search(query, browse: effectiveScope == .system) : []
    }

    private func refreshScope() {
        closeQuickLook(refocus: false)
        pendingStaleClear?.cancel()
        pendingStaleClear = nil
        invalidateContentSearch()
        pendingSelectionAction = nil
        if fileScopeKinds {
            nameResultsQuery = nil
            directoryStatus = nil
        }
        updateFeatures()
        merge(resetSelection: true)
        if usesPanelResults || !searchesNames || nameResultsQuery != query { searchNames(resetSelection: false) }
        scheduleContentSearch()
    }
    /// 内容搜索已经发出去、结果还没回来
    @Published private(set) var searchingContent = false
    /// 鼠标停在哪一条上（各行自行局部响应悬停，不再触发整个面板重绘）。
    var hoveredPath: String?
    /// 点了一次“删除”的那一条，等着再点一次“确定删除”（过几秒自动取消）
    @Published private(set) var confirmingDelete: String?
    /// 自测用：显示着的按钮在窗口里的位置（左上角为原点）
    var buttonFrames: [FileRowButton.Slot: CGRect] = [:]
    /// 搜索框开着
    var isShown = false {
        didSet {
            if !isShown {
                closeQuickLook(refocus: false)
                pendingSelectionAction = nil
                pendingStaleClear?.cancel()
                pendingStaleClear = nil
                pendingIndexRefresh?.cancel()
                pendingIndexRefresh = nil
                invalidateContentSearch()
                if folder != nil {
                    activeNameSearch?.set(true)
                    activeNameSearch = nil
                    folder = nil
                }
                if filterFolder != nil {
                    activeNameSearch?.set(true)
                    activeNameSearch = nil
                    filterFolder = nil
                }
                returnPoints.removeAll()
                restoreFolderSelection = nil
                iconCache.removeAllObjects()
            }
        }
    }

    let index: FileIndex
    let contentIndex: ContentIndex
    private var pins: PinnedSearchFolders
    @Published private(set) var savedSearches: SavedFileSearches
    /// 打开过的文件排在前面
    var history: OpenHistory?
    var onAction: (FileSearchResult, FileAction) -> Void = { _, _ in }
    var onFeature: (SystemFeature) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onShowResultMenu: () -> Void = {}
    var onChooseFolder: () -> Void = {}
    var onAddLocation: (String) -> Void = { _ in }
    var onSaveFilters: () -> Void = {}
    var onEditBounds: (FileSearchRangeKind) -> Void = { _ in }

    var finderFolder: FinderSearchFolder?
    @Published private(set) var directoryStatus: FileNameSearch.DirectoryStatus?
    private var parsedQuery = FileMatcher.Query("")
    @Published private var activeNameSearch: Locked<Bool>?
    private var namesNeedRefresh = false
    private var pendingStaleClear: DispatchWorkItem?
    private var pendingIndexRefresh: DispatchWorkItem?
    private var nameResults: [FileSearchResult] = []
    private var nameResultsQuery: String?
    private enum SelectionAction { case open, reveal, preview }
    private var pendingSelectionAction: SelectionAction?
    private var contentResults: [FileSearchResult] = []
    private var contentResultsQuery: String?
    private var contentCancelled = Locked(false)
    private var pendingContentSearch: DispatchWorkItem?
    private var contentNeedsRefresh = false
    private var deleteTimeout: DispatchWorkItem?
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private static let typeIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    private static let iconQueue = DispatchQueue(label: "MacShun.FileSearch.icons", qos: .utility)
    private var subscriptions: Set<AnyCancellable> = []

    /// 有内容结果时，文件名结果最多显示几条，免得内容结果被挤到很下面
    static let maxNameResultsWithContent = 6

    init(index: FileIndex, contentIndex: ContentIndex, pinDefaults: UserDefaults? = nil) {
        self.index = index
        self.contentIndex = contentIndex
        panelDefaults = pinDefaults
        showsPanelFilters = pinDefaults?.object(forKey: "fileSearch.panelFiltersVisible") as? Bool ?? true
        filtersOnTop = pinDefaults?.bool(forKey: "fileSearch.panelFiltersOnTop") ?? false
        pins = PinnedSearchFolders(defaults: pinDefaults)
        savedSearches = SavedFileSearches(defaults: pinDefaults)
        // 索引建好、文件有变化时，按现在的关键词重新搜一次。扫描外接硬盘时一秒会有好几次，合并防抖且选中的那条不动。
        index.$fileCount
            .dropFirst()
            // 改名和移动常常不改变数量，也要刷新当前搜索。
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown else { return }
                self.pendingIndexRefresh?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isShown else { return }
                    self.pendingIndexRefresh = nil
                    self.refreshFolderCoverage()
                    guard self.searchesNames,
                          !self.query.isEmpty || self.folder != nil || self.hasPanelFilters else { return }
                    // 只重搜文件名：内容搜索不跟着重来，不然文件一直在变时（扫描外接硬盘、装依赖）内容结果总被丢掉
                    if self.activeNameSearch == nil {
                        self.searchNames(resetSelection: false)
                    } else {
                        self.namesNeedRefresh = true
                    }
                }
                self.pendingIndexRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
            }
            .store(in: &subscriptions)
        // 正文改写、收录范围变化也需要刷新，即使文档总数相同。
        contentIndex.resultsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown, self.searchesTextForQuery else { return }
                if self.searchingContent { self.contentNeedsRefresh = true }
                else { self.scheduleContentSearch() }
            }
            .store(in: &subscriptions)
    }

    private var searchesTextForQuery: Bool {
        searchesContent && (effectiveScope == .contents || (effectiveScope == .all && parsedQuery.directoryInput == nil))
    }

    /// 内容结果从第几条开始（在这里显示“文件内容”的小标题）；没有内容结果、或者只看内容时为 nil
    var contentStart: Int? {
        effectiveScope == .all && panelOptions.order == .relevance ? rows.firstIndex { $0.file?.snippet != nil } : nil
    }

    var showsPinnedFolders: Bool {
        folder == nil && !hasPanelFilters && !inFileDialog && searchesNames && !pins.folders.isEmpty
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 只看内容时，打的字太少还不会搜
    var needsLongerQuery: Bool {
        effectiveScope == .contents && !query.trimmingCharacters(in: .whitespaces).isEmpty && !ContentIndex.qualifies(parsedQuery.contentText)
    }

    var hasOnlyFileFilters: Bool { !parsedQuery.filters.isEmpty && parsedQuery.terms.isEmpty }

    var nameHighlightTerms: [String] {
        parsedQuery.directoryInput?.listsChildren == true ? [] : parsedQuery.terms.map(\.text)
    }

    var folderHighlightTerms: [String] {
        parsedQuery.isPlainName && (parsedQuery.terms.count > 1 || !parsedQuery.filters.suffixes.isEmpty) ? nameHighlightTerms : []
    }

    var contentHighlightTerms: [String] { parsedQuery.contentText.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    /// Tab、Shift+Tab 切换范围
    func cycleScope(reverse: Bool) {
        let choices = availableScopes
        let i = choices.firstIndex(of: effectiveScope) ?? 0
        scope = choices[(i + (reverse ? choices.count - 1 : 1)) % choices.count]
    }

    /// 等待文件名或正文时保留状态位置，避免结果卡反复消失。
    var showsStatus: Bool {
        (!query.trimmingCharacters(in: .whitespaces).isEmpty || ((folder != nil || hasPanelFilters) && searchesNames))
            && rows.isEmpty
    }

    func prepareForShow(inFileDialog: Bool = false) {
        self.inFileDialog = inFileDialog
        returnPoints.removeAll()
        hoveredPath = nil
        isExpanded = false
        usesPanelResults = false
        changingFolder = true
        fileScopeKinds = false
        panelOptions = FileSearchOptions()
        filterFolder = nil
        changingFolder = false
        navigate(to: nil, query: "", scope: .files, selecting: nil)
    }

    func toggleExpanded() {
        isExpanded.toggle()
        if !usesPanelResults {
            usesPanelResults = true
            merge(resetSelection: false)
            searchNames(resetSelection: false)
            scheduleContentSearch()
        } else if isExpanded {
            if nameResults.contains(where: { $0.metadata == nil }) {
                searchNames(resetSelection: false)
            }
            if contentResults.contains(where: { $0.metadata == nil }) {
                scheduleContentSearch()
            }
        }
        focusSearch()
    }

    func focusSearch() { focusToken += 1 }

    func toggleFileKind(_ kind: FileSearchKind, inCompactStrip: Bool = false) {
        var options = appliedPanelOptions
        options.toggle(kind)
        let scoped = inCompactStrip && !options.kinds.isEmpty
        let changedScope = scoped != fileScopeKinds
        fileScopeKinds = scoped
        if options != panelOptions { panelOptions = options }
        else if changedScope { refreshPanelFilters() }
    }

    func setFilterFolder(_ path: String?) {
        guard path != filterFolder?.path else { return }
        selectedFolderIsIndexed = nil
        filterFolder = path.map(FileSearchFolder.init(path:))
        refreshFolderCoverage()
        refreshPanelFilters()
    }

    private func refreshFolderCoverage() {
        guard let path = (filterFolder ?? folder)?.path else { selectedFolderIsIndexed = nil; return }
        index.isFolderIndexed(path) { [weak self] indexed in
            guard let self, (self.filterFolder ?? self.folder)?.path == path else { return }
            if self.selectedFolderIsIndexed != indexed { self.selectedFolderIsIndexed = indexed }
        }
    }

    var canSaveFilters: Bool { hasPanelFilters || folder != nil || panelOptions.order != .relevance }

    func saveFilters(named name: String) -> Bool {
        guard canSaveFilters else { return false }
        return savedSearches.add(name: name, folder: searchFolder?.path, options: appliedPanelOptions)
    }

    func applySavedFilters(_ saved: SavedFileSearch) {
        changingFolder = true
        selectedFolderIsIndexed = nil
        if folder != nil {
            folder = nil
            returnPoints.removeAll()
        }
        fileScopeKinds = false
        panelOptions = saved.options
        filterFolder = saved.folder.map(FileSearchFolder.init(path:))
        changingFolder = false
        refreshFolderCoverage()
        refreshPanelFilters()
    }

    func removeSavedFilters(_ id: UUID) { savedSearches.remove(id) }

    func clearPanelFilters() {
        let order = panelOptions.order
        changingFolder = true
        filterFolder = nil
        fileScopeKinds = false
        panelOptions = FileSearchOptions(order: order)
        changingFolder = false
        refreshFolderCoverage()
        refreshPanelFilters()
    }

    private func refreshPanelFilters() {
        pageLimit = Self.pageSize
        closeQuickLook(refocus: false)
        cancelDelete()
        pendingSelectionAction = nil
        activeNameSearch?.set(true)
        invalidateContentSearch()
        nameResultsQuery = nil
        contentResultsQuery = nil
        directoryStatus = nil
        updateFeatures()
        merge(resetSelection: true)
        searchNames(resetSelection: false)
        scheduleContentSearch()
        focusSearch()
    }

    var isLoadingResults: Bool { activeNameSearch != nil || searchingContent }
    var visiblePageRows = 10

    func loadMoreResults(refocus: Bool = true) {
        guard hasMoreResults, !isLoadingResults else { return }
        pageLimit += Self.pageSize
        searchNames(resetSelection: false)
        scheduleContentSearch()
        if refocus { focusSearch() }
    }

    func searchInside(_ result: FileSearchResult) {
        guard result.canSearchInside else { return }
        enterFolder(result.path, returningTo: .file(result.path))
    }

    func openProject(_ project: PinnedSearchFolder) {
        enterFolder(project.path, returningTo: .project(project.path))
    }

    private func enterFolder(_ path: String, returningTo id: LauncherRow.ID) {
        guard path != folder?.path, rows.contains(where: { $0.id == id }) else { return }
        returnPoints.append(ReturnPoint(path: folder?.path, query: query, scope: effectiveScope, selection: id, limit: pageLimit))
        navigate(to: path, query: "", scope: effectiveScope, selecting: nil)
    }

    func leaveFolder() {
        guard let previous = returnPoints.popLast() else { return }
        navigate(to: previous.path, query: previous.query, scope: previous.scope, selecting: previous.selection, limit: previous.limit)
    }

    func cancelSearch() {
        if isPreviewing { closeQuickLook() }
        else if isExpanded { toggleExpanded() }
        else if folder != nil { leaveFolder() }
        else { onClose() }
    }


    private func navigate(to path: String?, query text: String, scope requested: FileSearchScope, selecting: LauncherRow.ID?,
                          limit: Int? = nil) {
        changingFolder = true
        folder = path.map(FileSearchFolder.init(path:))
        scope = availableScopes.contains(requested) ? requested : .files
        pageLimit = limit ?? Self.pageSize
        // 相同的关键词在不同目录里是不同的查询。旧结果和待执行的回车不能跨范围使用。
        nameResults = []
        nameResultsQuery = nil
        contentResults = []
        contentResultsQuery = nil
        query = text
        changingFolder = false
        refreshFolderCoverage()
        if let selecting, let position = rows.firstIndex(where: { $0.id == selecting }) {
            selection = position
        } else {
            restoreFolderSelection = selecting
        }
        focusToken += 1
    }

    /// 打了字时从第一条选起；文件有变化重新搜时，选中的那条不动
    private func searchNames(resetSelection: Bool) {
        activeNameSearch?.set(true)
        guard searchesNames else { activeNameSearch = nil; return }
        guard !hasConflictingFolders else {
            activeNameSearch = nil
            directoryStatus = .outsideFolder
            return
        }
        let cancelled = Locked(false)
        activeNameSearch = cancelled
        namesNeedRefresh = false
        index.searchPage(parsedQuery, limit: usesPanelResults ? pageLimit + 1 : 60, boosts: history?.boosts() ?? [:],
                         preferredFolder: finderFolder?.path, finderTitle: finderFolder?.title, within: searchFolder, options: searchOptions,
                         isCancelled: cancelled.get) { [weak self] page in
            guard let self, self.activeNameSearch === cancelled else { return }
            self.activeNameSearch = nil
            self.pendingStaleClear?.cancel()
            self.pendingStaleClear = nil
            self.directoryStatus = page.directory
            self.nameResults = page.results
            self.nameResultsQuery = self.query
            self.merge(resetSelection: resetSelection)
            if let id = self.restoreFolderSelection {
                self.restoreFolderSelection = nil
                if let i = self.rows.firstIndex(where: { $0.id == id }) { self.selection = i }
            }
            self.finishSelectionAction()
            // 扫盘时同一个查询可连续收到多批更新。先显示已找到的结果，再补一次最新的。
            if self.namesNeedRefresh && self.isShown { self.searchNames(resetSelection: false) }
        }
    }

    private func invalidateContentSearch() {
        pendingContentSearch?.cancel()
        contentNeedsRefresh = false
        contentCancelled.set(true)
        contentCancelled = Locked(false)
    }

    /// 内容搜索稍等一下再发（打字很快时只搜最后一次），旧的结果先留着，新的来了再换，免得列表一闪一闪。
    private func scheduleContentSearch() {
        invalidateContentSearch()
        let q = query
        let folderPath = searchFolder?.path
        guard searchesTextForQuery, !hasConflictingFolders, !appliedPanelOptions.foldersOnly,
              ContentIndex.qualifies(parsedQuery.contentText) else {
            searchingContent = false
            if !contentResults.isEmpty {
                contentResults = []
                merge(resetSelection: false)
            }
            return
        }
        searchingContent = true
        let cancelled = contentCancelled
        let options = searchOptions
        let limit = usesPanelResults ? pageLimit + 1 : 30
        let work = DispatchWorkItem { [weak self] in
            guard let self, !cancelled.get() else { return }
            self.contentIndex.search(q, limit: limit, within: folderPath, options: options, cancelled: cancelled) { [weak self] hits in
                // 关键词、范围变了就不要了（只看关键词：文件名重搜不影响内容结果）
                guard let self, self.isShown, self.contentCancelled === cancelled else { return }
                // 打开过的文件往前放，其余按相关程度
                let boosts = self.history?.boosts() ?? [:]
                self.contentResults = hits.enumerated().map { position, hit in
                    FileSearchResult(path: hit.path, name: (hit.path as NSString).lastPathComponent,
                                     isDirectory: false, score: (boosts[hit.path] ?? 0) - Double(position) * 0.01,
                                     snippet: hit.snippet, metadata: hit.metadata)
                }
                .sorted { $0.score > $1.score }
                self.contentResultsQuery = q
                self.searchingContent = false
                self.merge(resetSelection: false)
                self.finishSelectionAction()
                if self.contentNeedsRefresh && self.isShown { self.scheduleContentSearch() }
            }
        }
        pendingContentSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 合并两路结果。同一个文件名字和内容都匹配时只列在文件名里。选中的那条尽量不动。
    private func merge(resetSelection: Bool) {
        let selectedID = resetSelection ? nil : selectedRow?.id
        defer {
            let kept = selectedID.flatMap { id in rows.firstIndex { $0.id == id } }
            selection = kept ?? 0
            if kept == nil { closeQuickLook() }
        }
        if showsPinnedFolders {
            hasMoreResults = false
            rows = pins.folders.map(LauncherRow.project)
            return
        }
        let namesFound = nameResultsQuery == query ? nameResults : []
        let contentsFound = searchesTextForQuery && contentResultsQuery == query ? contentResults : []
        if usesPanelResults {
            mergePanelResults(names: searchesNames ? namesFound : [], contents: contentsFound)
            return
        }
        hasMoreResults = false
        switch effectiveScope {
        case .files:
            rows = featureResults.map(LauncherRow.feature) + namesFound.map(LauncherRow.file)
            return
        case .system:
            rows = featureResults.map(LauncherRow.feature)
            return
        case .contents:
            rows = contentsFound.map(LauncherRow.file)
            return
        case .all:
            break
        }
        // 内容结果都是名字也匹配的文件时，不用为它们腾地方
        let allNamePaths = Set(namesFound.map(\.path))
        let hasContentOnly = contentsFound.contains { !allNamePaths.contains($0.path) }
        let names = hasContentOnly ? Array(namesFound.prefix(Self.maxNameResultsWithContent)) : namesFound
        let shown = Set(names.map(\.path))
        rows = featureResults.map(LauncherRow.feature) + (names + contentsFound.filter { !shown.contains($0.path) }).map(LauncherRow.file)
    }

    private func mergePanelResults(names: [FileSearchResult], contents: [FileSearchResult]) {
        let files: [FileSearchResult]
        if panelOptions.order == .relevance {
            hasMoreResults = names.count > pageLimit || contents.count > pageLimit
            let names = Array(names.prefix(pageLimit))
            let paths = Set(names.map(\.path))
            files = names + contents.prefix(pageLimit).filter { !paths.contains($0.path) }
        } else {
            let paths = Set(names.map(\.path))
            let ordered = (names + contents.filter { !paths.contains($0.path) }).sorted(by: panelOptions.order.precedes)
            hasMoreResults = ordered.count > pageLimit
            files = Array(ordered.prefix(pageLimit))
        }
        rows = featureResults.map(LauncherRow.feature) + files.map(LauncherRow.file)
    }

    #if DEBUG
    /// 截图用：直接显示给定的结果。假文件不存在，系统只给空白图标，可以按路径给图标。
    func showPreview(query: String, results: [FileSearchResult], icons: [String: NSImage] = [:]) {
        self.query = query
        activeNameSearch?.set(true)
        activeNameSearch = nil
        pendingContentSearch?.cancel()
        for (path, image) in icons {
            iconCache.setObject(image, forKey: path as NSString)
        }
        self.rows = results.map(LauncherRow.file)
        selection = 0
    }
    #endif

    var selectedRow: LauncherRow? { rows.indices.contains(selection) ? rows[selection] : nil }
    var selectedResult: FileSearchResult? { selectedRow?.file }

    func toggleQuickLook() {
        if isPreviewing { closeQuickLook(); return }
        if pendingSelectionAction == .preview { pendingSelectionAction = nil; return }
        pendingSelectionAction = .preview
        finishSelectionAction()
    }

    private func showQuickLook(_ result: FileSearchResult) {
        guard let index = rows.firstIndex(where: { $0.id == .file(result.path) }) else { return }
        selection = index
        pendingSelectionAction = nil
        cancelDelete()
        isPreviewing = true
    }

    func closeQuickLook(refocus: Bool = true) {
        guard isPreviewing else { return }
        isPreviewing = false
        if refocus { focusToken += 1 }
    }

    func handleFolderKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f",
           let result = selectedResult, result.canSearchInside {
            if !event.isARepeat { searchInside(result) }
            return true
        }
        if modifiers.isEmpty, event.keyCode == KeyCode.escape, folder != nil {
            if !event.isARepeat { cancelSearch() }
            return true
        }
        return false
    }

    func handlePanelKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == KeyCode.o, modifiers == .control || modifiers == .command {
            if !event.isARepeat { onShowResultMenu() }
            return true
        }
        if modifiers == .control, event.keyCode == KeyCode.e {
            if !event.isARepeat { toggleExpanded() }
            return true
        }
        if isExpanded && modifiers.isEmpty && event.keyCode == KeyCode.escape {
            if !event.isARepeat { toggleExpanded() }
            return true
        }
        if isExpanded && !isPreviewing && modifiers.isEmpty && (event.keyCode == KeyCode.pageUp || event.keyCode == KeyCode.pageDown) {
            move(event.keyCode == KeyCode.pageUp ? -visiblePageRows : visiblePageRows)
            return true
        }
        return false
    }

    func handleQuickLookKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "y" {
            if !event.isARepeat { toggleQuickLook() }
            return true
        }
        guard isPreviewing, modifiers.isEmpty else { return false }
        switch event.keyCode {
        case KeyCode.escape: closeQuickLook()
        case KeyCode.upArrow: move(-1)
        case KeyCode.downArrow: move(1)
        default: return false
        }
        return true
    }

    func adjacentPreviewIndex(_ direction: Int) -> Int? {
        guard direction == 1 || direction == -1 else { return nil }
        var index = selection + direction
        while rows.indices.contains(index) {
            if rows[index].file != nil { return index }
            index += direction
        }
        return nil
    }

    func move(_ delta: Int) {
        restoreFolderSelection = nil
        guard !rows.isEmpty else { return }
        if isPreviewing {
            if let next = adjacentPreviewIndex(delta) { selection = next }
        } else {
            selection = min(max(selection + delta, 0), rows.count - 1)
        }
    }

    /// Enter 打开；按着 Ctrl 或 ⌘ 时在访达中显示。
    func openSelected(clicked: FileSearchResult? = nil) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let reveal = flags.contains(.control) || flags.contains(.command)
        if let clicked {
            pendingSelectionAction = nil
            onAction(clicked, reveal ? .reveal : primaryAction)
        } else {
            openSelected(reveal: reveal)
        }
    }

    func openSelected(reveal: Bool) {
        pendingSelectionAction = reveal ? .reveal : .open
        finishSelectionAction()
    }

    var waitingForNames: Bool {
        searchesNames && activeNameSearch != nil && nameResultsQuery != query
    }

    /// 快速打字后立即回车时，只打开这一轮的结果。全文检索可能比文件名晚返回。
    private func finishSelectionAction() {
        guard let action = pendingSelectionAction, isShown else { return }
        if case .feature(let feature) = selectedRow {
            pendingSelectionAction = nil
            if case .open = action { onFeature(feature) }
            return
        }
        if case .project(let project) = selectedRow {
            pendingSelectionAction = nil
            if case .open = action { openProject(project) }
            return
        }
        guard !waitingForNames else { return }
        if searchingContent && contentResultsQuery != query && (selectedResult?.snippet != nil || selectedResult == nil) { return }
        pendingSelectionAction = nil
        guard let result = selectedResult else { return }
        switch action {
        case .preview: showQuickLook(result)
        case .open: onAction(result, primaryAction)
        case .reveal: onAction(result, .reveal)
        }
    }

    var canShowResultMenu: Bool {
        switch selectedRow {
        case .file(let result):
            return !waitingForNames && (result.snippet == nil || !searchingContent || contentResultsQuery == query)
        case .project: return true
        default: return false
        }
    }

    func contextMenuForSelection() -> NSMenu? {
        guard canShowResultMenu else { return nil }
        pendingSelectionAction = nil
        cancelDelete()
        switch selectedRow {
        case .file(let result): return contextMenu(for: result)
        case .project(let project): return contextMenu(for: project)
        default: return nil
        }
    }

    /// 右键菜单。先选中这一条（像访达那样），看得出菜单是对哪一条的
    func contextMenu(for result: FileSearchResult) -> NSMenu? {
        guard let position = rows.firstIndex(where: { $0.id == .file(result.path) }) else { return nil }
        selection = position
        let pinItem: NSMenuItem?
        if result.canSearchInside && !inFileDialog {
            if pins.contains(result.path) {
                pinItem = ActionMenuItem(L("取消固定"), symbol: "pin.slash") { [weak self] in self?.unpinProject(result.path) }
            } else {
                pinItem = ActionMenuItem(L("固定到常用项目夹"), symbol: "pin") { [weak self] in
                    self?.pins.pin(.init(path: result.path, name: result.name))
                }
            }
        } else {
            pinItem = nil
        }
        return FileContextMenu.make(for: result, inFileDialog: inFileDialog, pinItem: pinItem, searchInside: { [weak self] in self?.searchInside(result) },
                                    preview: { [weak self] in self?.showQuickLook(result) }) { [weak self] action in
            self?.onAction(result, action)
        }
    }

    func contextMenu(for project: PinnedSearchFolder) -> NSMenu? {
        guard let position = rows.firstIndex(where: { $0.id == .project(project.path) }) else { return nil }
        selection = position
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(L("在此文件夹中搜索"), symbol: "magnifyingglass") { [weak self] in self?.openProject(project) })
        menu.addItem(ActionMenuItem(L("取消固定"), symbol: "pin.slash") { [weak self] in self?.unpinProject(project.path) })
        return menu
    }

    func unpinProject(_ path: String) {
        pins.unpin(path)
        merge(resetSelection: false)
    }

    /// 结果右边的按钮。定位、复制做完关掉搜索框（和右键菜单一样）；删除要点两下
    func tapped(_ button: FileRowButton, on result: FileSearchResult, clickCount: Int = 1) {
        switch button {
        case .reveal:
            cancelDelete()
            onAction(result, .reveal)
        case .copy:
            cancelDelete()
            onAction(result, .copy)
        case .delete:
            deleteTapped(result, clickCount: clickCount)
        }
    }

    /// “删除”点一下变成“确定删除”，再点一下才移到废纸篓。双击的第二下不算，免得一双击就删了；
    /// 3 秒内没再点、打了字就取消（双击速度调得很慢时多等一会儿，不然等过了双击时间就取消了）
    private func deleteTapped(_ result: FileSearchResult, clickCount: Int) {
        guard confirmingDelete == result.path else {
            cancelDelete()
            confirmingDelete = result.path
            let timeout = DispatchWorkItem { [weak self] in self?.confirmingDelete = nil }
            deleteTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + max(3, NSEvent.doubleClickInterval + 2), execute: timeout)
            return
        }
        guard clickCount < 2 else { return }
        cancelDelete()
        onAction(result, .trash)
    }

    private func cancelDelete() {
        deleteTimeout?.cancel()
        deleteTimeout = nil
        if confirmingDelete != nil { confirmingDelete = nil }
    }

    /// 文件已经不在了（移到了废纸篓）：从结果里拿掉，选中的位置不动，下一条顶上来
    func remove(_ path: String) {
        let removingSelected = selectedResult?.path == path
        let position = selection
        nameResults.removeAll { $0.path == path }
        contentResults.removeAll { $0.path == path }
        merge(resetSelection: false)
        if removingSelected { selection = min(position, max(rows.count - 1, 0)) }
    }

    func cachedIcon(for result: FileSearchResult) -> NSImage? {
        iconCache.object(forKey: result.path as NSString)
    }

    /// 零磁盘 I/O 的即时类型图标，避免在网络盘或慢速外接盘上滚列表时阻塞主线程。
    func placeholderIcon(for result: FileSearchResult) -> NSImage {
        let ext = (result.path as NSString).pathExtension.lowercased()
        let key: String = if result.isDirectory && ext != "app" {
            "__folder__"
        } else if ext.isEmpty {
            "__data__"
        } else {
            "ext:\(ext)"
        }
        if let cached = Self.typeIconCache.object(forKey: key as NSString) { return cached }
        let type: UTType = if result.isDirectory && ext != "app" {
            .folder
        } else if !ext.isEmpty, let matched = UTType(filenameExtension: ext) {
            matched
        } else {
            .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        Self.typeIconCache.setObject(image, forKey: key as NSString)
        return image
    }

    func icon(for result: FileSearchResult) -> NSImage {
        cachedIcon(for: result) ?? placeholderIcon(for: result)
    }

    func loadIcon(for result: FileSearchResult, completion: @escaping (NSImage) -> Void) {
        let path = result.path
        if let cached = iconCache.object(forKey: path as NSString) {
            completion(cached)
            return
        }
        Self.iconQueue.async { [weak self] in
            let image = NSWorkspace.shared.icon(forFile: path)
            let cost = max(32_768, Int(image.size.width * image.size.height * 16))
            DispatchQueue.main.async {
                self?.iconCache.setObject(image, forKey: path as NSString, cost: cost)
                completion(image)
            }
        }
    }
}

// MARK: - 界面

struct FileSearchView: View {
    @ObservedObject var model: FileSearchModel
    let index: FileIndex
    let contentIndex: ContentIndex

    /// 仅在自测与单元测试里采集按钮坐标，正式版（.app）省掉每行 GeometryReader + PreferenceKey 开销。
    static let recordsButtonFrames: Bool = SelfTest.isRequested || Bundle.main.bundleURL.pathExtension != "app"

    static let capsuleHeight: CGFloat = 56
    private static let expandedSearchHeight: CGFloat = 54
    private static let sidebarWidth: CGFloat = 198
    private static let sidebarBreakpoint: CGFloat = 680
    static let folderBarHeight: CGFloat = 34
    static let rowHeight: CGFloat = 46
    static let expandedRowHeight: CGFloat = 39
    static let maxVisibleRows = 8
    /// 四周给阴影留的空白
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let listPadding: CGFloat = 6
    private static let footerHeight: CGFloat = 36
    private static let statusHeight: CGFloat = 56
    static let sectionHeaderHeight: CGFloat = 26

    static func inputHeaderHeight(expanded: Bool) -> CGFloat {
        expanded ? expandedSearchHeight : capsuleHeight
    }

    static let fileTypeAreaHeight = gap + FileSearchTypeCapsule.height
    static let minimumResultAreaHeight = gap + rowHeight + listPadding * 2 + footerHeight

    static func compactHeaderHeight(inFolder: Bool, typeAreaHeight: CGFloat) -> CGFloat {
        capsuleHeight + (inFolder ? folderBarHeight : 0) + typeAreaHeight
    }

    static func height(resultCount: Int, hasSectionHeader: Bool, showsStatus: Bool, previewing: Bool = false,
                       inFolder: Bool = false, typeAreaHeight: CGFloat) -> CGFloat {
        let header = compactHeaderHeight(inFolder: inFolder, typeAreaHeight: typeAreaHeight)
        return header + margin * 2 + resultAreaHeight(resultCount: resultCount, hasSectionHeader: hasSectionHeader,
                                                       showsStatus: showsStatus, previewing: previewing)
    }

    static func resultAreaHeight(resultCount: Int, hasSectionHeader: Bool, showsStatus: Bool, previewing: Bool) -> CGFloat {
        if previewing { return gap + 386 }
        if resultCount > 0 {
            return gap + CGFloat(min(resultCount, maxVisibleRows)) * rowHeight + listPadding * 2 + footerHeight
                + (hasSectionHeader ? sectionHeaderHeight : 0)
        }
        return showsStatus ? gap + statusHeight : 0
    }

    var body: some View {
        let expanded = model.isExpanded
        return VStack(spacing: 0) {
            searchHeader
            if expanded {
                Divider()
                expandedBody
                Divider()
                expandedFooter
            } else {
                let layout = model.compactLayout
                if layout.visible.fileTypes > 0 {
                    let interactive = layout.target.fileTypes > 0 && layout.fileTypesOpacity == 1
                    FileSearchTypeCapsule(model: model)
                        .padding(.top, Self.gap)
                        .opacity(layout.fileTypesOpacity)
                        .allowsHitTesting(interactive)
                        .accessibilityHidden(!interactive)
                }
                if layout.visible.results > 0 { compactResults(layout) }
            }
        }
        .background {
            if expanded { VisualEffectBackground().clipShape(panelShape) }
        }
        .clipShape(expanded ? AnyShape(panelShape) : AnyShape(Rectangle().inset(by: -Self.margin)))
        .overlay {
            if expanded { panelShape.strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5).allowsHitTesting(false) }
        }
        .overlay(alignment: .bottomTrailing) {
            if expanded {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .overlay { FileSearchResizeRegion() }
                    .accessibilityHidden(true)
            }
        }
        .shadow(color: .black.opacity(expanded ? 0.28 : 0), radius: 10, y: 4)
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func compactResults(_ layout: CompactSearchPresentation) -> some View {
        GeometryReader { geometry in
            let height = model.compactPresentation == nil ? geometry.size.height : layout.visible.results
            searchBody
                .frame(height: max(0, height - Self.gap))
                .padding(.top, Self.gap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: layout.visible.results)
        .clipped()
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: 15, style: .continuous) }

    private var searchHeader: some View {
        let expanded = model.isExpanded
        let capsule = RoundedRectangle(cornerRadius: model.folder == nil ? Self.capsuleHeight / 2 : 16, style: .continuous)
        return VStack(spacing: 0) {
            inputRow
            if let folder = model.folder {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 14)
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.head).help(folder.path)
                        Spacer(minLength: 8)
                        searchButton(model.returnsToProjects ? L("返回常用项目夹") : L("返回上次搜索"),
                                     key: expanded || model.isPreviewing ? nil : "Esc", symbol: "arrow.uturn.backward") {
                            model.leaveFolder()
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                }
                .frame(height: Self.folderBarHeight)
            }
        }
        .background {
            if !expanded { VisualEffectBackground().clipShape(capsule) }
        }
        .overlay {
            if !expanded { capsule.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        }
        .overlay(alignment: .top) {
            FileSearchWindowGrip(height: expanded ? 12 : 15, toggle: model.toggleExpanded)
                .padding(.top, expanded ? 4 : 0)
        }
        .shadow(color: .black.opacity(expanded ? 0 : 0.25), radius: 10, y: 4)
    }

    private var inputRow: some View {
        let expanded = model.isExpanded
        let height = Self.inputHeaderHeight(expanded: expanded)
        return GeometryReader { geometry in
            let scopePresentation: ScopePicker.Presentation = if geometry.size.width < (expanded ? 470 : 400) {
                .icons
            } else if expanded && geometry.size.width >= 590 {
                .fullTitles
            } else {
                .shortTitles
            }
            let showsFileTools = expanded && model.effectiveScope != .system
            HStack(spacing: expanded ? 9 : 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: expanded ? 17 : 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .overlay { FileSearchDragRegion(toggle: model.toggleExpanded) }
                SearchField(
                    text: $model.query,
                    placeholder: showsFileTools && scopePresentation == .icons ? L("搜索") : placeholder,
                    focusToken: model.focusToken,
                    fontSize: 20,
                    onMove: { model.move($0) },
                    onSubmit: { model.openSelected() },
                    onCancel: { model.cancelSearch() },
                    onTab: model.availableScopes.count > 1 ? { model.cycleScope(reverse: $0) } : nil
                )
                if model.folder == nil && model.searchesNames {
                    FileSearchIndexingSpinner(index: index)
                }
                if model.availableScopes.count > 1 {
                    ScopePicker(selection: model.effectiveScope, scopes: model.availableScopes,
                                inFolder: !model.includesSystemFeatures, presentation: scopePresentation) { scope in
                        model.scope = scope
                        model.focusSearch()
                    }
                    .padding(.leading, expanded ? 0 : 8)
                }
                if showsFileTools {
                    Divider().frame(height: 18).padding(.horizontal, 2)
                    headerTools
                }
                panelToggle
            }
            .padding(.horizontal, expanded ? 12 : 17)
            .frame(maxHeight: .infinity)
            .padding(.top, expanded ? Self.gap : 0)
        }
        .frame(height: height)
    }

    private var headerTools: some View {
        let visible = model.showsPanelFilters
        let title = visible ? L("隐藏筛选") : L("显示筛选")
        return HStack(spacing: 4) {
            Menu {
                Picker(L("排序"), selection: $model.panelOptions.order) {
                    ForEach(FileSearchOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L("排序"))
            .accessibilityValue(model.panelOptions.order.title)
            .help(L("排序"))

            Button {
                model.showsPanelFilters.toggle()
                model.focusSearch()
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.searchPanelTool(active: visible || model.hasPanelFilters))
            .accessibilityLabel(title)
            .accessibilityValue(model.hasPanelFilters ? L("筛选已启用") : "")
            .help(title)
        }
    }

    private var expandedBody: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.sidebarBreakpoint
            let top = model.filtersOnTop || !wide
            let showsFilters = model.showsPanelFilters && model.effectiveScope != .system
            VStack(spacing: 0) {
                if showsFilters && top {
                    FileSearchPanelControls(model: model, onTop: true, canShowSidebar: wide)
                    Divider()
                }
                HStack(spacing: 0) {
                    if showsFilters && !top {
                        FileSearchPanelControls(model: model, onTop: false, canShowSidebar: true)
                            .frame(width: Self.sidebarWidth)
                        Divider()
                    }
                    searchBody.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var searchBody: some View {
        if model.isPreviewing, let result = model.selectedResult {
            FileQuickLook(model: model, result: result)
        } else if !model.rows.isEmpty {
            GeometryReader { geometry in
                resultList(compact: geometry.size.width < (model.isExpanded ? 760 : 500), viewportHeight: geometry.size.height,
                           fileColumns: fileColumns(for: geometry.size.width))
            }
        } else if model.isExpanded {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    let columns = fileColumns(for: geometry.size.width)
                    if columns.showsFolder { columnHeaders(columns) }
                    status
                }
            }
        } else if model.showsStatus {
            status
        }
    }

    private func fileColumns(for width: CGFloat) -> FileResultColumns {
        guard model.isExpanded, model.effectiveScope != .system, !model.showsPinnedFolders,
              model.rows.isEmpty || model.rows.contains(where: { $0.file != nil }) else { return .none }
        return FileResultColumns(width: width)
    }

    private var panelToggle: some View {
        let title = model.isExpanded ? L("收起搜索面板") : L("展开搜索面板")
        return Button { model.toggleExpanded() } label: {
            Image(systemName: model.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    if model.hasPanelFilters && !model.isExpanded {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(3)
                    }
                }
        }
        .buttonStyle(.searchPanelTool())
        .accessibilityLabel(title)
        .accessibilityValue(model.hasPanelFilters ? L("筛选已启用") : "")
        .help("\(title)  Ctrl+E")
    }

    private var placeholder: String {
        if model.showsPinnedFolders { return L("输入关键词") }
        if model.folder != nil {
            return model.effectiveScope == .contents ? L("搜索此文件夹里的正文") : L("搜索此文件夹及子文件夹")
        }
        if model.inFileDialog && model.effectiveScope != .contents { return L("查找要前往的位置") }
        return switch model.effectiveScope {
        case .files: L("搜索文件或系统功能")
        case .contents: L("搜索文件里的文字")
        case .all: L("搜索文件、内容或系统功能")
        case .system: L("试试“耳机连不上”")
        }
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private struct ScrollRequest: Equatable {
        let selection: LauncherRow.ID?
        let position: Int
        let viewportHeight: CGFloat
    }
    private enum ListAnchor: Hashable { case top }

    private func resultList(compact: Bool, viewportHeight: CGFloat, fileColumns: FileResultColumns) -> some View {
        let expanded = model.isExpanded
        let listHeight = viewportHeight - (fileColumns.showsFolder ? FileResultColumns.headerHeight : 0)
        return VStack(spacing: 0) {
            if fileColumns.showsFolder { columnHeaders(fileColumns) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let contentStart = model.contentStart
                        Color.clear.frame(height: Self.listPadding).id(ListAnchor.top)
                        if model.showsPinnedFolders { sectionHeader(L("常用项目夹")) }
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { position, row in
                            if position == contentStart { sectionHeader(L("文件内容")) }
                            switch row {
                            case .feature(let feature):
                                SystemFeatureRow(feature: feature, selected: position == model.selection, expanded: expanded) {
                                    model.selection = position
                                    model.openSelected(reveal: false)
                                }
                                .id(row.id)
                            case .project(let project):
                                PinnedFolderRow(project: project, selected: position == model.selection, expanded: expanded) {
                                    model.openProject(project)
                                }
                                .id(row.id)
                                .overlay(ContextMenuArea { model.contextMenu(for: project) })
                            case .file(let result):
                                fileRow(result, position: position, compact: compact, columns: fileColumns)
                                    .id(row.id)
                            }
                        }
                        if expanded && model.hasMoreResults {
                            FileSearchLoadMoreSentinel(model: model)
                                .id(model.rows.count)
                        }
                    }
                    .padding(.horizontal, Self.listPadding)
                    .padding(.bottom, Self.listPadding)
                    .onPreferenceChange(RowButtonFrames.self) {
                        if Self.recordsButtonFrames { model.buttonFrames = $0 }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: ScrollRequest(selection: model.selectedRow?.id, position: model.selection,
                                            viewportHeight: listHeight), initial: true) { old, new in
                    if expanded {
                        let bodyHeight = max(0, listHeight - 2 * Self.listPadding)
                        model.visiblePageRows = max(1, Int(bodyHeight / Self.expandedRowHeight))
                    }
                    let minHeight = expanded ? Self.expandedRowHeight : Self.rowHeight + Self.footerHeight
                    // 结果先到、原生面板后变高。不能在折叠高度里滚动，否则首行会留在可视区上方。
                    guard new.viewportHeight >= minHeight else { return }
                    let selectionChanged = old.selection != new.selection || old.position != new.position
                    let becameVisible = old.viewportHeight < minHeight
                    guard selectionChanged || becameVisible || !expanded else { return }
                    guard let selected = model.selectedRow else { return }
                    if model.selection == 0 { proxy.scrollTo(ListAnchor.top, anchor: .top) }
                    else { proxy.scrollTo(selected.id) }
                }
            }
            if !expanded {
                Divider().opacity(0.6)
                adaptiveResultFooter
                    .padding(.horizontal, 12)
                    .frame(height: Self.footerHeight)
            }
        }
        .background {
            if !expanded { VisualEffectBackground().clipShape(card) }
        }
        .overlay {
            if !expanded { card.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        }
        .shadow(color: .black.opacity(expanded ? 0 : 0.25), radius: 10, y: 4)
    }

    private var expandedFooter: some View {
        adaptiveResultFooter
            .padding(.horizontal, 12)
            .padding(.trailing, 7)
            .frame(height: Self.footerHeight)
    }

    private enum FooterDensity: Equatable { case detailed, compact, icons }

    private var adaptiveResultFooter: some View {
        ViewThatFits(in: .horizontal) {
            resultFooter(density: .detailed)
            resultFooter(density: .compact)
            resultFooter(density: .icons)
        }
    }

    private func pageControls(iconOnly: Bool) -> some View {
        HStack(spacing: 8) {
            if !model.rows.isEmpty {
                Text(model.hasMoreResults ? L("已显示 %ld 项", model.rows.count) : L("%ld 项结果", model.rows.count))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize(horizontal: !iconOnly, vertical: false)
            }
            if model.hasMoreResults && !model.isPreviewing {
                if model.isLoadingResults { ProgressView().controlSize(.mini) }
                searchButton(L("继续加载"), key: nil, symbol: "plus", showTitle: !iconOnly) { model.loadMoreResults() }
                    .disabled(model.isLoadingResults)
            }
        }
    }

    private func fileRow(_ result: FileSearchResult, position: Int, compact: Bool, columns: FileResultColumns) -> some View {
        let row = FileResultRow(
            model: model,
            result: result,
            isSelected: position == model.selection,
            confirmingDelete: model.confirmingDelete == result.path,
            expanded: model.isExpanded,
            inFileDialog: model.inFileDialog,
            distinctFolder: model.duplicateFolderLabels[result.path],
            nameHighlightTerms: model.nameHighlightTerms,
            folderHighlightTerms: model.folderHighlightTerms,
            contentHighlightTerms: model.contentHighlightTerms,
            compact: compact,
            columns: columns
        )
        return Group {
            if model.isExpanded {
                row.onTapGesture(count: 2) {
                    model.selection = position
                    model.openSelected(clicked: result)
                }
                .simultaneousGesture(TapGesture().onEnded { model.selection = position })
            } else {
                row.onTapGesture {
                    model.selection = position
                    model.openSelected(clicked: result)
                }
            }
        }
        .onDrag { NSItemProvider(object: result.fileURL as NSURL) }
        .overlay(ContextMenuArea { model.contextMenu(for: result) })
    }

    private func columnHeaders(_ columns: FileResultColumns) -> some View {
        let inset = Self.listPadding + FileSearchRowStyle.inset
        return HStack(spacing: FileSearchRowStyle.spacing) {
            sortColumn(L("名称"), first: .nameAscending, second: .nameDescending, firstIsAscending: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortColumn(L("所在目录"), first: .folder, second: .folderDescending, firstIsAscending: true)
                .frame(width: FileResultColumns.folderWidth, alignment: .leading)
            if columns.showsDate {
                sortColumn(L("修改时间"), first: .newest, second: .oldest)
                    .frame(width: FileResultColumns.dateWidth, alignment: .leading)
            }
            if columns.showsSize {
                sortColumn(L("大小"), first: .largest, second: .smallest)
                    .frame(width: FileResultColumns.sizeWidth, alignment: .trailing)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.leading, inset + FileSearchRowStyle.iconSize(expanded: true) + FileSearchRowStyle.spacing)
        .padding(.trailing, inset)
        .frame(height: FileResultColumns.headerHeight)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, inset).opacity(0.6) }
    }

    private func sortColumn(_ title: String, first: FileSearchOrder, second: FileSearchOrder,
                            firstIsAscending: Bool = false) -> some View {
        let order = model.panelOptions.order
        let active = order == first || order == second
        return Button {
            model.panelOptions.order = order == first ? second : first
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if active {
                    Image(systemName: (order == first) == firstIsAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .accessibilityValue(active ? order.title : "")
        .help(L("按“%@”排序", title))
    }

    private func resultFooter(density: FooterDensity) -> some View {
        let detailed = density == .detailed
        let iconOnly = density == .icons
        return HStack(spacing: iconOnly ? 6 : 8) {
            if model.isExpanded { pageControls(iconOnly: iconOnly) }
            if model.canShowResultMenu {
                searchButton(L("更多操作"), key: "Ctrl+O / ⌘O", symbol: "ellipsis", showKey: false, showTitle: detailed) {
                    model.onShowResultMenu()
                }
            }
            if let result = model.selectedResult {
                if result.canSearchInside {
                    searchButton(L("在此搜索"), key: "⌘F", symbol: "magnifyingglass", showKey: detailed, showTitle: !iconOnly) {
                        model.searchInside(result)
                    }
                }
                searchButton(model.isPreviewing ? L("关闭预览") : L("快速查看"), key: "⌘Y",
                             symbol: model.isPreviewing ? "eye.slash" : "eye", showKey: detailed, showTitle: !iconOnly) {
                    model.toggleQuickLook()
                }
            } else if case .project(let project) = model.selectedRow {
                searchButton(L("取消固定"), key: nil, symbol: "pin.slash", showTitle: !iconOnly) { model.unpinProject(project.path) }
            }
            Spacer(minLength: 0)
            if !iconOnly && !model.rows.isEmpty {
                KeyHint(key: "Enter", action: model.showsPinnedFolders ? L("在此搜索") : model.inFileDialog ? L("前往文件夹") : L("打开"))
            }
            if detailed, let result = model.selectedResult, !result.canSearchInside {
                KeyHint(key: "Ctrl+Enter", action: L("在访达中显示"))
            }
            FileSearchFooterContentStatus(
                contentIndex: contentIndex,
                searchesContent: model.searchesContent && [.all, .contents].contains(model.effectiveScope),
                detailed: detailed,
                hasMultipleScopes: model.availableScopes.count > 1,
                isExpanded: model.isExpanded,
                inFolder: model.folder != nil
            )
        }
    }

    private func searchButton(_ title: String, key: String?, symbol: String, showKey: Bool = true, showTitle: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if showTitle { Text(title) }
                if showKey, let key { Text(key).foregroundStyle(.secondary).font(.caption2) }
            }
            .font(.caption).padding(.horizontal, 7).frame(minWidth: 26, minHeight: 23).fixedSize()
        }
        .buttonStyle(.chip())
        .accessibilityLabel(title)
        .help(key.map { "\(title)  \($0)" } ?? title)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: Self.sectionHeaderHeight)
    }

    private var status: some View {
        FileSearchEmptyStatus(model: model, index: index, contentIndex: contentIndex, statusHeight: Self.statusHeight)
    }
}

private enum FileResultColumns: Equatable {
    case none, folder, folderAndDate, all

    static let headerHeight: CGFloat = 29
    static let folderWidth: CGFloat = 178
    static let dateWidth: CGFloat = 132
    static let sizeWidth: CGFloat = 70

    init(width: CGFloat) {
        let spacing = FileSearchRowStyle.spacing
        let leadingArea = 2 * (FileSearchView.listPadding + FileSearchRowStyle.inset)
            + FileSearchRowStyle.iconSize(expanded: true) + 2 * spacing
        // Leave room for two lines of filename and a content match before adding metadata columns.
        let available = width - leadingArea - 220
        let folder = Self.folderWidth + spacing
        let date = Self.dateWidth + spacing
        if available >= folder + date + Self.sizeWidth + spacing { self = .all }
        else if available >= folder + date { self = .folderAndDate }
        else if available >= folder { self = .folder }
        else { self = .none }
    }

    var showsFolder: Bool { self != .none }
    var showsDate: Bool { self == .folderAndDate || self == .all }
    var showsSize: Bool { self == .all }
}

/// 仅在文件索引运行中时显示的小旋转器，避免索引计数刷新重绘整个搜索面板。
private struct FileSearchIndexingSpinner: View {
    @ObservedObject var index: FileIndex

    var body: some View {
        if index.isIndexing {
            ProgressView().controlSize(.small)
        }
    }
}

/// 页脚右侧的正文读取进度，局部订阅 ContentIndex。
private struct FileSearchFooterContentStatus: View {
    @ObservedObject var contentIndex: ContentIndex
    let searchesContent: Bool
    let detailed: Bool
    let hasMultipleScopes: Bool
    let isExpanded: Bool
    let inFolder: Bool

    var body: some View {
        if searchesContent && contentIndex.pendingCount > 0 {
            ProgressView().controlSize(.mini).accessibilityLabel(L("正在读取文件内容")).help(L("正在读取文件内容"))
            if detailed { Text(L("正在读取文件内容")).font(.caption).foregroundStyle(.secondary).fixedSize() }
        } else if detailed {
            if hasMultipleScopes { KeyHint(key: "Tab", action: L("切换范围")) }
            if isExpanded { KeyHint(key: "Esc", action: L("收起")) }
            else if !inFolder { KeyHint(key: "Esc", action: L("关闭")) }
        }
    }
}

/// 空结果状态栏：仅在无结果时挂载，局部订阅 FileIndex / ContentIndex。
private struct FileSearchEmptyStatus: View {
    @ObservedObject var model: FileSearchModel
    @ObservedObject var index: FileIndex
    @ObservedObject var contentIndex: ContentIndex
    let statusHeight: CGFloat

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            if model.waitingForNames || model.searchingContent {
                ProgressView().controlSize(.small)
                Text(L("正在搜索…"))
            } else if model.needsLongerQuery || (model.effectiveScope == .contents && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.tertiary)
                Text(model.hasOnlyFileFilters || model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? L("输入要在文件内容里查找的关键词") : L("至少输入两个汉字或三个字母才搜内容"))
            } else if model.effectiveScope == .contents && contentIndex.pendingCount > 0 {
                ProgressView().controlSize(.small)
                Text(L("正在读取文件内容，结果可能还不全…"))
            } else if model.searchesNames, let directory = model.directoryStatus {
                Image(systemName: directory == .unavailable ? "folder.badge.questionmark" : "folder").foregroundStyle(.tertiary)
                switch directory {
                case .partial: Text(L("部分子文件夹无法读取，其余位置没有匹配项"))
                case .outsideFolder: Text(L("这个路径在当前搜索范围之外"))
                case .unavailable: Text(L("无法打开这个文件夹，请检查路径或访问权限"))
                case .listing: Text(L("这个文件夹里没有匹配的项目"))
                case .offline: Text(L("共享已离线，用访达重新连接"))
                case .indexing: Text(L("正在收录共享中的文件…"))
                }
            } else if model.folder == nil && index.isIndexing && model.searchesNames {
                ProgressView().controlSize(.small)
                Text(L("正在建立索引，马上就好…"))
            } else if model.folder == nil && index.isScanningDrives && model.searchesNames {
                ProgressView().controlSize(.small)
                Text(L("正在扫描外接硬盘，结果可能还不全…"))
            } else if model.effectiveScope == .contents && model.searchFolder != nil {
                Image(systemName: "folder").foregroundStyle(.tertiary)
                Text(L("此范围内没有匹配的已收录正文"))
            } else if model.folder != nil {
                Image(systemName: "folder").foregroundStyle(.tertiary)
                Text(L("此文件夹及子文件夹中没有匹配项"))
            } else if model.hasPanelFilters {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.tertiary)
                Text(L("没有匹配筛选条件的项目"))
            } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                Text(model.effectiveScope == .contents ? L("输入要在文件内容里查找的关键词") : L("输入关键词或选择筛选条件"))
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                Text(L("没有找到，换个关键词或试试拼音首字母"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: model.isExpanded ? .infinity : nil)
        .frame(height: model.isExpanded ? nil : statusHeight)
        .background {
            if !model.isExpanded { VisualEffectBackground().clipShape(card) }
        }
        .overlay {
            if !model.isExpanded { card.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        }
        .shadow(color: .black.opacity(model.isExpanded ? 0 : 0.25), radius: 10, y: 4)
    }
}

/// 展开列表底部的自动翻页哨兵：仅在实际处于视口内时才触发继续加载，防止翻页级联。
private final class LoadMoreSentinelState: ObservableObject {
    var visible = false
}

private struct FileSearchLoadMoreSentinel: View {
    @ObservedObject var model: FileSearchModel
    @StateObject private var state = LoadMoreSentinelState()

    var body: some View {
        Color.clear.frame(height: 1)
            .accessibilityHidden(true)
            .onAppear {
                state.visible = true
                model.loadMoreResults(refocus: false)
            }
            .onDisappear {
                state.visible = false
            }
            .onChange(of: model.isLoadingResults) { wasLoading, loading in
                if wasLoading && !loading && state.visible {
                    model.loadMoreResults(refocus: false)
                }
            }
    }
}

/// 单行异步图标：先用零磁盘 I/O 的类型图标占位，后台取真实图标后只刷新这一格。
@MainActor
private final class FileIconLoader: ObservableObject {
    @Published var image: NSImage?
    private var loadedPath: String?

    func ensureLoaded(model: FileSearchModel, result: FileSearchResult) {
        guard loadedPath != result.path else { return }
        loadedPath = result.path
        if let cached = model.cachedIcon(for: result) {
            image = cached
            return
        }
        image = nil
        let targetPath = result.path
        model.loadIcon(for: result) { [weak self] resolved in
            guard let self, self.loadedPath == targetPath else { return }
            self.image = resolved
        }
    }
}

private struct FileResultIcon: View {
    let model: FileSearchModel
    let result: FileSearchResult
    let size: CGFloat
    @StateObject private var loader = FileIconLoader()

    var body: some View {
        Image(nsImage: loader.image ?? model.cachedIcon(for: result) ?? model.placeholderIcon(for: result))
            .resizable()
            .frame(width: size, height: size)
            .onAppear { loader.ensureLoaded(model: model, result: result) }
            .onChange(of: result.path) { _, _ in loader.ensureLoaded(model: model, result: result) }
    }
}

private struct FileResultRow: View {
    let model: FileSearchModel
    let result: FileSearchResult
    let isSelected: Bool
    let confirmingDelete: Bool
    let expanded: Bool
    let inFileDialog: Bool
    let distinctFolder: String?
    let nameHighlightTerms: [String]
    let folderHighlightTerms: [String]
    let contentHighlightTerms: [String]
    let compact: Bool
    let columns: FileResultColumns

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()
    private static var dateFormatterLocale: String?
    private static var cachedDateFormatter: DateFormatter?

    private static func formatModified(_ timestamp: Double) -> String {
        let locale = AppLanguage.uiLocale
        if cachedDateFormatter == nil || dateFormatterLocale != locale.identifier {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            cachedDateFormatter = formatter
            dateFormatterLocale = locale.identifier
        }
        return cachedDateFormatter!.string(from: Date(timeIntervalSince1970: timestamp))
    }

    /// 所在的文件夹，个人文件夹写成 ~
    private var fullFolder: String {
        let parent = (result.path as NSString).deletingLastPathComponent
        if parent == Self.home { return "~" }
        if parent.hasPrefix(Self.home + "/") { return "~" + parent.dropFirst(Self.home.count) }
        return parent
    }

    private var folder: String { distinctFolder ?? fullFolder }
    private var folderTruncation: Text.TruncationMode { distinctFolder == nil ? .head : .tail }

    private var modified: String? {
        result.metadata.map { Self.formatModified($0.modified) }
    }

    private var size: String? {
        result.metadata?.size.map { Self.sizeFormatter.string(fromByteCount: $0) }
    }

    var body: some View {
        let iconSize = FileSearchRowStyle.iconSize(expanded: expanded)
        let folderText = folder
        let fullFolderText = fullFolder
        return HoverReader { hovering in
            let wantsHelp = hovering && (expanded || distinctFolder != nil)
            let modifiedText = (columns.showsDate || wantsHelp) ? modified : nil
            let sizeText = (columns.showsSize || wantsHelp) ? size : nil
            let helpText = wantsHelp
                ? ([result.path] + [modifiedText, sizeText].compactMap { $0 }).joined(separator: "\n")
                : ""
            HStack(spacing: FileSearchRowStyle.spacing) {
                FileResultIcon(model: model, result: result, size: iconSize)
                if let snippet = result.snippet {
                    // 正文命中显示文件名和摘要。没有独立目录列时才在第一行补位置。
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(result.name)
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            if !columns.showsFolder {
                                Text(folderText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(folderTruncation)
                                    .accessibilityLabel(fullFolderText)
                            }
                        }
                        Text(highlighted(snippet, terms: contentHighlightTerms, size: 12))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(highlighted(result.name, terms: nameHighlightTerms, size: 14))
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if result.isHomophone { Text(L("同音")).font(.caption2).foregroundStyle(.secondary) }
                        }
                        if !columns.showsFolder {
                            Text(highlighted(folderText, terms: folderHighlightTerms, size: 11))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(folderTruncation)
                                .accessibilityLabel(fullFolderText)
                        }
                    }
                }
                Spacer(minLength: 0)
                // 选中的、鼠标停着的、等着确认删除的那条才显示，免得每条都是按钮
                if !expanded && !inFileDialog && (isSelected || hovering || confirmingDelete) {
                    actions
                }
                if columns.showsFolder {
                    Text(highlighted(folderText, terms: folderHighlightTerms, size: 11))
                        .frame(width: FileResultColumns.folderWidth, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(folderTruncation)
                        .accessibilityLabel(fullFolderText)
                }
                if columns.showsDate {
                    Text(modifiedText ?? "—").frame(width: FileResultColumns.dateWidth, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                if columns.showsSize {
                    Text(sizeText ?? "—").frame(width: FileResultColumns.sizeWidth, alignment: .trailing)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            .modifier(FileSearchRowStyle(expanded: expanded, selected: isSelected, hovering: hovering))
            .help(helpText)
            .onChange(of: hovering) { _, inside in
                if inside {
                    model.hoveredPath = result.path
                } else if model.hoveredPath == result.path {
                    model.hoveredPath = nil
                }
            }
        }
    }

    /// 定位、复制、删除。删除放最右边：点一下变成红色的“确定删除”，往左变宽，鼠标下面还是它
    private var actions: some View {
        HStack(spacing: 4) {
            button(.reveal, L("定位"), symbol: "folder", help: L("在访达中显示"))
            button(.copy, L("复制"), symbol: "doc.on.doc", help: L("复制文件，可以粘贴到访达或聊天窗口"))
            button(.delete, confirmingDelete ? L("确定删除") : L("删除"), symbol: "trash",
                   help: L("移到废纸篓，要点两下"), destructive: confirmingDelete)
        }
    }

    private func button(_ kind: FileRowButton, _ title: String, symbol: String, help: String, destructive: Bool = false) -> some View {
        Button {
            model.tapped(kind, on: result, clickCount: NSApp.currentEvent?.clickCount ?? 1)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                if !compact || destructive {
                    Text(title).font(.system(size: 11, weight: destructive ? .semibold : .regular))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .fixedSize()
        }
        .buttonStyle(.chip(destructive: destructive))
        .accessibilityLabel(title)
        .help(help)
        .background {
            if FileSearchView.recordsButtonFrames {
                GeometryReader { geo in
                    Color.clear.preference(key: RowButtonFrames.self,
                                           value: [FileRowButton.Slot(path: result.path, button: kind): geo.frame(in: .global)])
                }
            }
        }
    }

    /// 搜索词在文件名、父目录或正文摘要中的实际命中位置。
    private func highlighted(_ value: String, terms: [String], size: CGFloat) -> AttributedString {
        var text = AttributedString(value)
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let found = text[from...].range(of: term, options: .caseInsensitive) {
                text[found].foregroundColor = expanded ? .accentColor : .primary
                text[found].font = .system(size: size, weight: .semibold)
                from = found.upperBound
            }
        }
        return text
    }
}

/// 显示着的按钮在窗口里的位置（自测用）
private struct RowButtonFrames: PreferenceKey {
    static let defaultValue: [FileRowButton.Slot: CGRect] = [:]

    static func reduce(value: inout [FileRowButton.Slot: CGRect], nextValue: () -> [FileRowButton.Slot: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 结果的右键菜单：打开、打开方式、在访达中显示、复制、复制路径、移到废纸篓。
enum FileContextMenu {
    static func make(for result: FileSearchResult, inFileDialog: Bool = false, pinItem: NSMenuItem? = nil,
                     searchInside: @escaping () -> Void, preview: @escaping () -> Void, perform: @escaping (FileAction) -> Void) -> NSMenu {
        let url = result.fileURL
        let menu = NSMenu()
        if inFileDialog {
            menu.addItem(ActionMenuItem(L("前往文件夹"), symbol: "folder") { perform(.goToFolder) })
        } else {
            menu.addItem(ActionMenuItem(L("打开"), symbol: "arrow.up.forward.app") { perform(.open) })
        }
        if result.canSearchInside {
            menu.addItem(ActionMenuItem(L("在此文件夹中搜索"), symbol: "folder", handler: searchInside))
            if let pinItem { menu.addItem(pinItem) }
        }
        if let openWith = openWithItem(url, perform: perform) { menu.addItem(openWith) }
        menu.addItem(ActionMenuItem(L("快速查看"), symbol: "eye", handler: preview))
        menu.addItem(ActionMenuItem(L("在访达中显示"), symbol: "folder") { perform(.reveal) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L("复制"), symbol: "doc.on.doc") { perform(.copy) })
        menu.addItem(ActionMenuItem(L("复制路径"), symbol: "link") { perform(.copyPath) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L("移到废纸篓"), symbol: "trash") { perform(.trash) })
        return menu
    }

    /// 能打开它的应用，默认的那个放最上面。应用程序本身不用选
    private static func openWithItem(_ url: URL, perform: @escaping (FileAction) -> Void) -> NSMenuItem? {
        guard url.pathExtension.lowercased() != "app" else { return nil }
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(toOpen: url)?.standardizedFileURL
        // 同一个应用装了几份时（比如“下载”里还有一份）只列一个
        var seen = Set<String>()
        let apps = workspace.urlsForApplications(toOpen: url)
            .map { (url: $0.standardizedFileURL, name: FileManager.default.displayName(atPath: $0.path)) }
            .sorted { a, b in
                if (a.url == preferred) != (b.url == preferred) { return a.url == preferred }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .filter { seen.insert($0.name).inserted }
        guard !apps.isEmpty else { return nil }

        let submenu = NSMenu()
        for app in apps {
            let isDefault = app.url == preferred
            let item = ActionMenuItem(isDefault ? L("%@（默认）", app.name) : app.name) { perform(.openWith(app.url)) }
            let icon = workspace.icon(forFile: app.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
            if isDefault && apps.count > 1 { submenu.addItem(.separator()) }
        }
        let item = NSMenuItem(title: L("打开方式"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }
}

/// 点了就执行一段代码的菜单项
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}

/// 盖在一条结果上：右键（和按着 Ctrl 点）弹出菜单，左键、滚轮照常交给下面的 SwiftUI。
private struct ContextMenuArea: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> MenuView { MenuView() }

    func updateNSView(_ view: MenuView, context: Context) { view.makeMenu = menu }

    final class MenuView: NSView {
        var makeMenu: (() -> NSMenu?)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let wantsMenu = event.type == .rightMouseDown || event.type == .leftMouseDown && event.modifierFlags.contains(.control)
            return wantsMenu ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }
    }
}

/// 搜索框右边的范围选择器。
private struct ScopePicker: View {
    enum Presentation { case fullTitles, shortTitles, icons }

    let selection: FileSearchScope
    let scopes: [FileSearchScope]
    let inFolder: Bool
    let presentation: Presentation
    let choose: (FileSearchScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(scopes) { scope in
                let selected = scope == selection
                let title = scope.title(inFolder: inFolder)
                Button { choose(scope) } label: {
                    HoverReader { hovering in
                        label(for: scope, title: title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected || hovering ? .primary : .secondary)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottom) {
                                if selected {
                                    Capsule().fill(Color.accentColor).frame(width: 14, height: 2)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(title)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("搜索范围"))
    }

    @ViewBuilder private func label(for scope: FileSearchScope, title: String) -> some View {
        if presentation == .icons {
            let symbol = switch scope {
            case .all: "square.grid.2x2"
            case .files: "folder"
            case .contents: "text.alignleft"
            case .system: "gearshape"
            }
            Image(systemName: symbol)
        } else {
            Text(presentation == .shortTitles && scope == .files ? L("文件") : title)
                .padding(.horizontal, presentation == .fullTitles ? 9 : 7)
        }
    }
}
