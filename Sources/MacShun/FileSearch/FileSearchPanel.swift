// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI

/// 文件搜索（F1、F2）：连按两下 Ctrl 弹出胶囊形的搜索框，边打字边出结果，按文件名和文件内容搜。只在主线程上使用。
@MainActor
final class FileSearchController {
    private let configStore: ConfigStore
    private let history = OpenHistory()
    private let index = FileIndex.shared
    private let contentIndex = ContentIndex.shared
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var subscriptions: Set<AnyCancellable> = []
    /// 接住 Ctrl+Enter 的事件监听（见 makePanel）
    private var keyMonitor: Any?
    /// 剪贴板面板正叠在搜索框上（见 clipboardHost）
    private var hostingClipboard = false
    private var dialog: FileDialogTarget?
    private var dialogNavigation: Task<Void, Never>?
    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// 按配置开始或停止建立索引。
    func applyConfig() {
        let cfg = configStore.config.fileSearch
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
        model.searchesContent = searchesContent
    }

    var isVisible: Bool { panel.isVisible }
    /// 自测用
    var currentQuery: String { model.query }
    var isKey: Bool { panel.isKeyWindow }
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
        let top = FileSearchView.margin + FileSearchView.capsuleHeight + (model.folder == nil ? 0 : FileSearchView.folderBarHeight) + FileSearchView.gap + FileSearchView.listPadding
            + (CGFloat(index) + 0.5) * FileSearchView.rowHeight
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: frame.minX + 200, y: primaryHeight - (frame.maxY - top))
    }

    /// 在搜索框里按 Win+V：剪贴板面板放在胶囊下面，选中的文字填到光标处，关掉以后回到搜索框。
    func clipboardHost() -> ClipboardController.Host {
        let frame = panel.frame
        let capsuleBottom = frame.maxY - FileSearchView.margin - FileSearchView.capsuleHeight
        let anchor = NSRect(x: frame.minX + 64, y: capsuleBottom, width: 0, height: FileSearchView.capsuleHeight)
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

    /// 连按两下 Ctrl：打开。已经开着时不关（多半是想接着输入或粘贴），只放到前面；关用 Esc。
    func summon() {
        if panel.isVisible { panel.makeKeyAndOrderFront(nil) } else { show() }
    }

    func show() {
        guard configStore.config.fileSearch.enabled else { return }
        if !configStore.config.fileSearch.activated {
            configStore.config.fileSearch.activated = true
        }
        index.includeExternalDrives = configStore.config.fileSearch.includeExternalDrives
        index.start()
        dialogNavigation?.cancel()
        dialog = FileDialogTarget.focused()
        model.preferredFolder = dialog == nil ? Self.finderFolder() : nil
        model.prepareForShow(inFileDialog: dialog != nil)
        model.isShown = true
        resize()
        position()
        FrontAppTracker.shared.fileSearchPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// 只在从访达呼出时取一次位置。无需额外授权，虚拟位置和没有窗口时照常全局搜索。
    private static func finderFolder() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == AppCatalog.finder,
              AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)
        guard let document = FocusInspector.string(window, kAXDocumentAttribute),
              let url = URL(string: document), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }

    func hide() {
        FrontAppTracker.shared.fileSearchPanelActive.set(false)
        if panel.isVisible {
            // orderOut 会保留正在组字的编辑器；下次打开面板应从空查询开始。
            panel.endEditing(for: nil)
            panel.orderOut(nil)
        }
        // 关着时不用跟着文件变化重新搜
        model.isShown = false
        dialog = nil
    }

    /// 打开、在访达中显示，和右键菜单、结果右边按钮里的操作。除了移到废纸篓，做完都关掉搜索框。
    private func perform(_ action: FileAction, on result: FileSearchResult) {
        let url = URL(fileURLWithPath: result.path)
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
        let model = FileSearchModel(index: index, contentIndex: contentIndex)
        model.history = history
        model.onAction = { [weak self] result, action in self?.perform(action, on: result) }
        model.onFeature = { [weak self] feature in
            if NSWorkspace.shared.open(feature.destination.url) { self?.hide() }
            else { NSSound.beep() }
        }
        model.onClose = { [weak self] in self?.hide() }
        // 结果多少变了，面板跟着变高变矮
        model.$rows.combineLatest(model.$query, index.$isIndexing, model.$searchingContent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &subscriptions)
        model.$isPreviewing.combineLatest(model.$folder)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &subscriptions)
        return model
    }

    private func makePanel() -> FileSearchPanel {
        let panel = FileSearchPanel()
        let host = NSHostingView(rootView: FileSearchView(model: model, index: index, contentIndex: contentIndex))
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        // 在搜索框里按 Win+V 打开的剪贴板面板叠在上面时不关
        panel.onResignKey = { [weak self] in
            guard let self, !self.hostingClipboard else { return }
            self.hide()
        }
        // Ctrl+Enter 是系统“显示快捷菜单”的快捷键：系统在把按键交给窗口之前就处理了，输入框上会弹出右键菜单。
        // 本程序的事件监听在那之前，在这里接住。⌘+Enter 输入框不处理，也在这里接。
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, event.window === panel else { return event }
            let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
            if !composing {
                if self.model.handleQuickLookKey(event) { return nil }
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

    /// Ctrl+Enter、⌘+Enter：在访达中显示
    static func isRevealKey(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.intersection([.control, .command]).isEmpty
    }

    /// 面板高度：胶囊加上下面的结果列表。保持顶边不动。
    private func resize() {
        var height = FileSearchView.height(resultCount: model.rows.count, hasContentSection: model.contentStart != nil,
                                           showsStatus: model.showsStatus, previewing: model.isPreviewing, inFolder: model.folder != nil)
        var frame = panel.frame
        if model.isPreviewing, let visible = panel.screen?.visibleFrame {
            height = min(height, visible.height, max(200, frame.maxY - visible.minY))
            if frame.maxY - height < visible.minY { frame.origin.y += visible.minY - (frame.maxY - height) }
        }
        guard abs(frame.height - height) > 0.5 else { return }
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// 放在鼠标所在屏幕的上方中间，和聚焦搜索差不多的位置。
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(FileSearchPanel.width, visible.width)
        let top = visible.maxY - visible.height * 0.22
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: top - panel.frame.height,
                              width: width, height: panel.frame.height), display: false)
    }
}

/// 无边框、透明的浮动面板，形状由里面的界面画出来。
final class FileSearchPanel: NSPanel {
    static let width: CGFloat = 640

    var onResignKey: (() -> Void)?

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
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
            closeQuickLook(refocus: false)
            cancelDelete()
            pendingSelectionAction = nil
            invalidateContentSearch()
            parsedQuery = FileMatcher.Query(query)
            directoryStatus = nil
            restoreFolderSelection = nil
            updateFeatures()
            merge(resetSelection: true)
            searchNames(resetSelection: false)
            scheduleContentSearch()
        }
    }
    /// 明确匹配的系统功能、文件名、文件正文，各自保留类型与操作。
    @Published private(set) var rows: [LauncherRow] = []
    /// File-only view used by file search diagnostics.
    var results: [FileSearchResult] { rows.compactMap(\.file) }
    private var featureResults: [SystemFeature] = []
    @Published var selection = 0
    @Published private(set) var isPreviewing = false
    @Published private(set) var focusToken = 0
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
        let selection: String
    }
    private var returnPoints: [ReturnPoint] = []
    private var changingFolder = false
    private var restoreFolderSelection: String?

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

    private func updateFeatures() {
        featureResults = includesSystemFeatures && effectiveScope != .contents && parsedQuery.isPlainName && parsedQuery.filters.isEmpty
            ? SystemFeature.search(query, browse: effectiveScope == .system) : []
    }

    private func refreshScope() {
        closeQuickLook(refocus: false)
        invalidateContentSearch()
        pendingSelectionAction = nil
        updateFeatures()
        merge(resetSelection: true)
        if !searchesNames || nameResultsQuery != query { searchNames(resetSelection: false) }
        scheduleContentSearch()
    }
    /// 内容搜索已经发出去、结果还没回来
    @Published private(set) var searchingContent = false
    /// 鼠标停在哪一条上。这一条和选中的那条右边显示按钮
    @Published var hoveredPath: String?
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
                invalidateContentSearch()
                if folder != nil {
                    activeNameSearch?.set(true)
                    activeNameSearch = nil
                    folder = nil
                }
                returnPoints.removeAll()
                restoreFolderSelection = nil
            }
        }
    }

    let index: FileIndex
    let contentIndex: ContentIndex
    /// 打开过的文件排在前面
    var history: OpenHistory?
    var onAction: (FileSearchResult, FileAction) -> Void = { _, _ in }
    var onFeature: (SystemFeature) -> Void = { _ in }
    var onClose: () -> Void = {}

    var preferredFolder: String?
    @Published private(set) var directoryStatus: FileNameSearch.DirectoryStatus?
    private var parsedQuery = FileMatcher.Query("")
    private var activeNameSearch: Locked<Bool>?
    private var namesNeedRefresh = false
    private var nameResults: [FileSearchResult] = []
    private var nameResultsQuery: String?
    private enum SelectionAction { case open, reveal, preview }
    private var pendingSelectionAction: SelectionAction?
    private var contentResults: [FileSearchResult] = []
    private var contentResultsQuery: String?
    private var contentCancelled = Locked(false)
    private var pendingContentSearch: DispatchWorkItem?
    private var deleteTimeout: DispatchWorkItem?
    private var icons: [String: NSImage] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    /// 有内容结果时，文件名结果最多显示几条，免得内容结果被挤到很下面
    static let maxNameResultsWithContent = 6

    init(index: FileIndex, contentIndex: ContentIndex) {
        self.index = index
        self.contentIndex = contentIndex
        // 索引建好、文件有变化时，按现在的关键词重新搜一次。扫描外接硬盘时一秒会有好几次，选中的那条不动
        index.$fileCount
            // 改名和移动常常不改变数量，也要刷新当前搜索。
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown, self.searchesNames, !self.query.isEmpty || self.folder != nil else { return }
                // 只重搜文件名：内容搜索不跟着重来，不然文件一直在变时（扫描外接硬盘、装依赖）内容结果总被丢掉
                if self.activeNameSearch == nil {
                    self.searchNames(resetSelection: false)
                } else {
                    self.namesNeedRefresh = true
                }
            }
            .store(in: &subscriptions)
        // 内容索引读完一批文件后也重新搜一次（每次最多半秒发布一次）
        contentIndex.$documentCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown else { return }
                self.scheduleContentSearch()
            }
            .store(in: &subscriptions)
    }

    private var searchesTextForQuery: Bool {
        searchesContent && (effectiveScope == .contents || (effectiveScope == .all && parsedQuery.directoryInput == nil))
    }

    /// 内容结果从第几条开始（在这里显示“文件内容”的小标题）；没有内容结果、或者只看内容时为 nil
    var contentStart: Int? { effectiveScope == .all ? rows.firstIndex { $0.file?.snippet != nil } : nil }

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

    /// 结果下面要不要显示一行状态（正在建立索引、没有找到）
    /// 内容还在搜的时候先不说“没有找到”，免得一闪
    var showsStatus: Bool {
        (!query.trimmingCharacters(in: .whitespaces).isEmpty || (folder != nil && searchesNames)) && rows.isEmpty && !searchingContent
    }

    func prepareForShow(inFileDialog: Bool = false) {
        self.inFileDialog = inFileDialog
        returnPoints.removeAll()
        folder = nil
        query = ""
        nameResults = []
        contentResults = []
        rows = []
        selection = 0
        scope = .files
        searchingContent = false
        hoveredPath = nil
        cancelDelete()
        focusToken += 1
    }

    func searchInside(_ result: FileSearchResult) {
        guard result.canSearchInside, result.path != folder?.path, rows.contains(where: { $0.id == .file(result.path) }) else { return }
        returnPoints.append(ReturnPoint(path: folder?.path, query: query, scope: effectiveScope, selection: result.path))
        navigate(to: result.path, query: "", scope: effectiveScope, selecting: nil)
    }

    func leaveFolder() {
        guard let previous = returnPoints.popLast() else { return }
        navigate(to: previous.path, query: previous.query, scope: previous.scope, selecting: previous.selection)
    }

    func cancelSearch() {
        if isPreviewing { closeQuickLook() }
        else if folder != nil { leaveFolder() }
        else { onClose() }
    }

    private func navigate(to path: String?, query text: String, scope requested: FileSearchScope, selecting: String?) {
        changingFolder = true
        folder = path.map(FileSearchFolder.init(path:))
        scope = availableScopes.contains(requested) ? requested : .files
        changingFolder = false
        // 相同的关键词在不同目录里是不同的查询。旧结果和待执行的回车不能跨范围使用。
        nameResults = []
        nameResultsQuery = nil
        contentResults = []
        contentResultsQuery = nil
        query = text
        restoreFolderSelection = selecting
        focusToken += 1
    }

    /// 打了字时从第一条选起；文件有变化重新搜时，选中的那条不动
    private func searchNames(resetSelection: Bool) {
        activeNameSearch?.set(true)
        guard searchesNames else { activeNameSearch = nil; return }
        let cancelled = Locked(false)
        activeNameSearch = cancelled
        namesNeedRefresh = false
        index.searchPage(parsedQuery, boosts: history?.boosts() ?? [:], preferredFolder: preferredFolder, within: folder,
                         isCancelled: cancelled.get) { [weak self] page in
            guard let self, self.activeNameSearch === cancelled else { return }
            self.activeNameSearch = nil
            self.directoryStatus = page.directory
            self.nameResults = page.results
            self.nameResultsQuery = self.query
            self.merge(resetSelection: resetSelection)
            if let path = self.restoreFolderSelection {
                self.restoreFolderSelection = nil
                if let i = self.rows.firstIndex(where: { $0.id == .file(path) }) { self.selection = i }
            }
            self.finishSelectionAction()
            // 扫盘时同一个查询可连续收到多批更新。先显示已找到的结果，再补一次最新的。
            if self.namesNeedRefresh && self.isShown { self.searchNames(resetSelection: false) }
        }
    }

    private func invalidateContentSearch() {
        pendingContentSearch?.cancel()
        contentCancelled.set(true)
        contentCancelled = Locked(false)
    }

    /// 内容搜索稍等一下再发（打字很快时只搜最后一次），旧的结果先留着，新的来了再换，免得列表一闪一闪。
    private func scheduleContentSearch() {
        pendingContentSearch?.cancel()
        let q = query
        let folderPath = folder?.path
        guard searchesTextForQuery, ContentIndex.qualifies(parsedQuery.contentText) else {
            searchingContent = false
            if !contentResults.isEmpty {
                contentResults = []
                merge(resetSelection: false)
            }
            return
        }
        searchingContent = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.contentIndex.search(q, within: folderPath, cancelled: self.contentCancelled) { [weak self] hits in
                // 关键词、范围变了就不要了（只看关键词：文件名重搜不影响内容结果）
                guard let self, self.isShown, q == self.query, folderPath == self.folder?.path, self.searchesTextForQuery else { return }
                // 打开过的文件往前放，其余按相关程度
                let boosts = self.history?.boosts() ?? [:]
                self.contentResults = hits.enumerated().map { position, hit in
                    FileSearchResult(path: hit.path, name: (hit.path as NSString).lastPathComponent,
                                     isDirectory: false, score: (boosts[hit.path] ?? 0) - Double(position) * 0.01, snippet: hit.snippet)
                }
                .sorted { $0.score > $1.score }
                self.contentResultsQuery = q
                self.searchingContent = false
                self.merge(resetSelection: false)
                self.finishSelectionAction()
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
        let namesFound = nameResultsQuery == query ? nameResults : []
        let contentsFound = searchesTextForQuery && contentResultsQuery == query ? contentResults : []
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

    #if DEBUG
    /// 截图用：直接显示给定的结果。假文件不存在，系统只给空白图标，可以按路径给图标。
    func showPreview(query: String, results: [FileSearchResult], icons: [String: NSImage] = [:]) {
        self.query = query
        activeNameSearch?.set(true)
        activeNameSearch = nil
        pendingContentSearch?.cancel()
        self.icons.merge(icons) { $1 }
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

    /// 右键菜单。先选中这一条（像访达那样），看得出菜单是对哪一条的
    func contextMenu(for result: FileSearchResult) -> NSMenu? {
        guard let position = rows.firstIndex(where: { $0.id == .file(result.path) }) else { return nil }
        selection = position
        return FileContextMenu.make(for: result, inFileDialog: inFileDialog, searchInside: { [weak self] in self?.searchInside(result) },
                                    preview: { [weak self] in self?.showQuickLook(result) }) { [weak self] action in
            self?.onAction(result, action)
        }
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

    func icon(for result: FileSearchResult) -> NSImage {
        if let cached = icons[result.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: result.path)
        if icons.count > 500 { icons.removeAll() }
        icons[result.path] = image
        return image
    }
}

// MARK: - 界面

struct FileSearchView: View {
    @ObservedObject var model: FileSearchModel
    @ObservedObject var index: FileIndex
    @ObservedObject var contentIndex: ContentIndex

    static let capsuleHeight: CGFloat = 56
    static let folderBarHeight: CGFloat = 34
    static let rowHeight: CGFloat = 46
    static let maxVisibleRows = 8
    /// 四周给阴影留的空白
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let listPadding: CGFloat = 6
    private static let footerHeight: CGFloat = 36
    private static let statusHeight: CGFloat = 56
    static let sectionHeaderHeight: CGFloat = 26

    static func height(resultCount: Int, hasContentSection: Bool, showsStatus: Bool, previewing: Bool = false, inFolder: Bool = false) -> CGFloat {
        var h = capsuleHeight + margin * 2 + (inFolder ? folderBarHeight : 0)
        if previewing { return h + gap + 386 }
        if resultCount > 0 {
            h += gap + CGFloat(min(resultCount, maxVisibleRows)) * rowHeight + 12 + footerHeight
            if hasContentSection { h += sectionHeaderHeight }
        } else if showsStatus {
            h += gap + statusHeight
        }
        return h
    }

    var body: some View {
        VStack(spacing: Self.gap) {
            capsule
            if model.isPreviewing, let result = model.selectedResult {
                FileQuickLook(model: model, result: result)
            } else if !model.rows.isEmpty {
                GeometryReader { geometry in resultList(compact: geometry.size.width < 500) }
            } else if model.showsStatus {
                status
            }
        }
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var capsule: some View {
        let shape = RoundedRectangle(cornerRadius: model.folder == nil ? Self.capsuleHeight / 2 : 16, style: .continuous)
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
                        searchButton(L("返回上次搜索"), key: model.isPreviewing ? nil : "Esc", symbol: "arrow.uturn.backward") {
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
        .background(VisualEffectBackground().clipShape(shape))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private var inputRow: some View {
        GeometryReader { geometry in
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                SearchField(
                    text: $model.query,
                    placeholder: placeholder,
                    focusToken: model.focusToken,
                    fontSize: 20,
                    onMove: { model.move($0) },
                    onSubmit: { model.openSelected() },
                    onCancel: { model.cancelSearch() },
                    onTab: model.availableScopes.count > 1 ? { model.cycleScope(reverse: $0) } : nil
                )
                if model.folder == nil && model.searchesNames && index.isIndexing { ProgressView().controlSize(.small) }
                if model.availableScopes.count > 1 && geometry.size.width < 540 {
                    Menu(model.effectiveScope.title(inFolder: !model.includesSystemFeatures)) {
                        Picker(L("搜索范围"), selection: $model.scope) {
                            ForEach(model.availableScopes) { Text($0.title(inFolder: !model.includesSystemFeatures)).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                    .fixedSize()
                    .accessibilityLabel(L("搜索范围"))
                } else if model.availableScopes.count > 1 {
                    ScopePicker(selection: $model.scope, scopes: model.availableScopes, inFolder: !model.includesSystemFeatures)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: Self.capsuleHeight)
        }
        .frame(height: Self.capsuleHeight)
    }

    private var placeholder: String {
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

    private func resultList(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { position, row in
                            if position == model.contentStart { sectionHeader }
                            switch row {
                            case .feature(let feature):
                                SystemFeatureRow(feature: feature, selected: position == model.selection) {
                                    model.selection = position
                                    model.openSelected(reveal: false)
                                }
                                .id(row.id)
                            case .file(let result):
                                FileResultRow(model: model, result: result, isSelected: position == model.selection, compact: compact)
                                    .id(row.id)
                                    .onTapGesture {
                                        model.selection = position
                                        model.openSelected(clicked: result)
                                    }
                                    .overlay(ContextMenuArea { model.contextMenu(for: result) })
                            }
                        }
                    }
                    .padding(Self.listPadding)
                    .onPreferenceChange(RowButtonFrames.self) { model.buttonFrames = $0 }
                }
                .scrollIndicators(.never)
                .onAppear { if let selected = model.selectedRow { proxy.scrollTo(selected.id) } }
                .onChange(of: model.selection) { _, newValue in
                    guard model.rows.indices.contains(newValue) else { return }
                    proxy.scrollTo(model.rows[newValue].id)
                }
            }
            Divider().opacity(0.6)
            ViewThatFits(in: .horizontal) {
                resultFooter(detailed: true)
                resultFooter(detailed: false)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.footerHeight)
        }
        .background(VisualEffectBackground().clipShape(card))
        .overlay(card.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func resultFooter(detailed: Bool) -> some View {
        HStack(spacing: 8) {
            if let result = model.selectedResult {
                if result.canSearchInside {
                    searchButton(L("在此搜索"), key: "⌘F", symbol: "magnifyingglass", showKey: detailed) { model.searchInside(result) }
                }
                searchButton(L("快速查看"), key: "⌘Y", symbol: "eye", showKey: detailed) { model.toggleQuickLook() }
            }
            Spacer(minLength: 0)
            KeyHint(key: "Enter", action: model.inFileDialog ? L("前往文件夹") : L("打开"))
            if detailed, let result = model.selectedResult, !result.canSearchInside {
                KeyHint(key: "Ctrl+Enter", action: L("在访达中显示"))
            }
            if model.searchesContent && [.all, .contents].contains(model.effectiveScope) && contentIndex.pendingCount > 0 {
                ProgressView().controlSize(.mini).accessibilityLabel(L("正在读取文件内容")).help(L("正在读取文件内容"))
                if detailed { Text(L("正在读取文件内容")).font(.caption).foregroundStyle(.secondary).fixedSize() }
            } else if detailed {
                if model.availableScopes.count > 1 { KeyHint(key: "Tab", action: L("切换范围")) }
                if model.folder == nil { KeyHint(key: "Esc", action: L("关闭")) }
            }
        }
    }

    private func searchButton(_ title: String, key: String?, symbol: String, showKey: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
                if showKey, let key { Text(key).foregroundStyle(.secondary).font(.caption2) }
            }
            .font(.caption).padding(.horizontal, 7).frame(minHeight: 23).fixedSize()
        }
        .buttonStyle(.chip())
        .accessibilityLabel(title)
        .help(key.map { "\(title)  \($0)" } ?? title)
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Text(L("文件内容"))
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: Self.sectionHeaderHeight)
    }

    private var status: some View {
        HStack(spacing: 10) {
            if model.needsLongerQuery {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.tertiary)
                Text(model.hasOnlyFileFilters ? L("输入要在文件内容里查找的关键词") : L("至少输入两个汉字或三个字母才搜内容"))
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
                }
            } else if model.folder == nil && index.isIndexing && model.searchesNames {
                ProgressView().controlSize(.small)
                Text(L("正在建立索引，马上就好…"))
            } else if model.folder == nil && index.isScanningDrives && model.searchesNames {
                ProgressView().controlSize(.small)
                Text(L("正在扫描外接硬盘，结果可能还不全…"))
            } else if model.waitingForNames {
                ProgressView().controlSize(.small)
                Text(L("正在搜索…"))
            } else if model.folder != nil {
                Image(systemName: "folder").foregroundStyle(.tertiary)
                Text(model.effectiveScope == .contents ? L("此范围内没有匹配的已收录正文") : L("此文件夹及子文件夹中没有匹配项"))
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                Text(L("没有找到，换个关键词或试试拼音首字母"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: Self.statusHeight)
        .background(VisualEffectBackground().clipShape(card))
        .overlay(card.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

private struct FileResultRow: View {
    @ObservedObject var model: FileSearchModel
    let result: FileSearchResult
    let isSelected: Bool
    let compact: Bool

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private var hovering: Bool { model.hoveredPath == result.path }
    private var confirmingDelete: Bool { model.confirmingDelete == result.path }

    /// 所在的文件夹，个人文件夹写成 ~
    private var folder: String {
        let parent = (result.path as NSString).deletingLastPathComponent
        if parent == Self.home { return "~" }
        if parent.hasPrefix(Self.home + "/") { return "~" + parent.dropFirst(Self.home.count) }
        return parent
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: model.icon(for: result))
                .resizable()
                .frame(width: 30, height: 30)
            if let snippet = result.snippet {
                // 按内容搜到的：第一行文件名和位置，第二行匹配的那段文字
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(result.name)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Text(folder)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(highlighted(snippet, terms: model.contentHighlightTerms, size: 12))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(result.name, terms: model.nameHighlightTerms, size: 14))
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(highlighted(folder, terms: model.folderHighlightTerms, size: 11))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            // 选中的、鼠标停着的、等着确认删除的那条才显示，免得每条都是按钮
            if !model.inFileDialog && (isSelected || hovering || confirmingDelete) {
                actions
            }
        }
        .padding(.horizontal, 10)
        .frame(height: FileSearchView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                model.hoveredPath = result.path
            } else if model.hoveredPath == result.path {
                model.hoveredPath = nil
            }
        }
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
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
        .background(GeometryReader { geo in
            Color.clear.preference(key: RowButtonFrames.self,
                                   value: [FileRowButton.Slot(path: result.path, button: kind): geo.frame(in: .global)])
        })
    }

    /// 搜索词在文件名、父目录或正文摘要中的实际命中位置。
    private func highlighted(_ value: String, terms: [String], size: CGFloat) -> AttributedString {
        var text = AttributedString(value)
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let found = text[from...].range(of: term, options: .caseInsensitive) {
                text[found].foregroundColor = .primary
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
    static func make(for result: FileSearchResult, inFileDialog: Bool = false, searchInside: @escaping () -> Void, preview: @escaping () -> Void, perform: @escaping (FileAction) -> Void) -> NSMenu {
        let url = URL(fileURLWithPath: result.path)
        let menu = NSMenu()
        if inFileDialog {
            menu.addItem(ActionMenuItem(L("前往文件夹"), symbol: "folder") { perform(.goToFolder) })
        } else {
            menu.addItem(ActionMenuItem(L("打开"), symbol: "arrow.up.forward.app") { perform(.open) })
        }
        if result.canSearchInside {
            menu.addItem(ActionMenuItem(L("在此文件夹中搜索"), symbol: "folder", handler: searchInside))
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
    @Binding var selection: FileSearchScope
    let scopes: [FileSearchScope]
    var inFolder = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(scopes) { scope in
                let selected = scope == selection
                // 没选中的那几个：鼠标停在上面时浅浅的底色，字变清楚
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = scope }
                } label: {
                    HoverReader { hovering in
                        Text(scope.title(inFolder: inFolder))
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected || hovering ? .primary : .secondary)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(selected ? 0.14 : hovering ? 0.07 : 0))
                                    .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1, y: 0.5)
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("搜索范围"))
    }
}
