// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Combine
import SwiftUI

/// 文件搜索（F1）：连按两下 Ctrl 弹出胶囊形的搜索框，边打字边出结果。只在主线程上使用。
final class FileSearchController {
    private let configStore: ConfigStore
    private let index = FileIndex.shared
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var subscriptions: Set<AnyCancellable> = []
    /// 打开前的输入法。搜索框只允许英文输入，关闭时切回来。
    private var savedInputSource: TISInputSource?

    init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    /// 按配置开始或停止建立索引。
    func applyConfig() {
        let cfg = configStore.config.fileSearch
        if index.includeExternalDrives != cfg.includeExternalDrives {
            index.includeExternalDrives = cfg.includeExternalDrives
            if cfg.enabled && cfg.activated && index.lastIndexed != nil { index.rebuild() }
        }
        if cfg.enabled && cfg.activated {
            index.start()
        } else if !cfg.enabled {
            index.stop()
            hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        guard configStore.config.fileSearch.enabled else { return }
        if !configStore.config.fileSearch.activated {
            configStore.config.fileSearch.activated = true
        }
        index.includeExternalDrives = configStore.config.fileSearch.includeExternalDrives
        index.start()
        model.prepareForShow()
        resize()
        position()
        savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        FrontAppTracker.shared.fileSearchPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        FrontAppTracker.shared.fileSearchPanelActive.set(false)
        if panel.isVisible { panel.orderOut(nil) }
        restoreInputSource()
    }

    private func restoreInputSource() {
        guard let saved = savedInputSource else { return }
        savedInputSource = nil
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        if current.map({ CFEqual($0, saved) }) != true {
            TISSelectInputSource(saved)
        }
    }

    private func open(_ result: FileSearchResult, reveal: Bool) {
        hide()
        let url = URL(fileURLWithPath: result.path)
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 面板

    private func makeModel() -> FileSearchModel {
        let model = FileSearchModel(index: index)
        model.onOpen = { [weak self] result, reveal in self?.open(result, reveal: reveal) }
        model.onClose = { [weak self] in self?.hide() }
        // 结果多少变了，面板跟着变高变矮
        model.$results.combineLatest(model.$query, index.$isIndexing)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resize() }
            .store(in: &subscriptions)
        return model
    }

    private func makePanel() -> FileSearchPanel {
        let panel = FileSearchPanel()
        let host = NSHostingView(rootView: FileSearchView(model: model, index: index))
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }

    /// 面板高度：胶囊加上下面的结果列表。保持顶边不动。
    private func resize() {
        let height = FileSearchView.height(resultCount: model.results.count, showsStatus: model.showsStatus)
        var frame = panel.frame
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
        let size = panel.frame.size
        let top = visible.maxY - visible.height * 0.22
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
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

/// 搜索框的数据和操作。
final class FileSearchModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results: [FileSearchResult] = []
    @Published var selection = 0
    @Published private(set) var focusToken = 0

    let index: FileIndex
    var onOpen: (FileSearchResult, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    private var generation = 0
    private var icons: [String: NSImage] = [:]
    private var indexSubscription: AnyCancellable?

    init(index: FileIndex) {
        self.index = index
        // 索引建好、文件有变化时，按现在的关键词重新搜一次
        indexSubscription = index.$fileCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleSearch() }
    }

    /// 结果下面要不要显示一行状态（正在建立索引、没有找到）
    var showsStatus: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty && results.isEmpty }

    func prepareForShow() {
        query = ""
        results = []
        selection = 0
        focusToken += 1
    }

    private func scheduleSearch() {
        generation += 1
        let current = generation
        let q = query
        index.search(q) { [weak self] found in
            guard let self, current == self.generation else { return }
            self.results = found
            self.selection = 0
        }
    }

    #if DEBUG
    /// 截图用：直接显示给定的结果
    func showPreview(query: String, results: [FileSearchResult]) {
        self.query = query
        generation += 1
        self.results = results
        selection = 0
    }
    #endif

    var selectedResult: FileSearchResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    /// Enter 打开；按着 Ctrl 或 ⌘ 时在访达中显示。
    func openSelected() {
        guard let result = selectedResult else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        onOpen(result, flags.contains(.control) || flags.contains(.command))
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

    static let capsuleHeight: CGFloat = 56
    static let rowHeight: CGFloat = 46
    static let maxVisibleRows = 8
    /// 四周给阴影留的空白
    static let margin: CGFloat = 12
    private static let gap: CGFloat = 8
    private static let footerHeight: CGFloat = 30
    private static let statusHeight: CGFloat = 56

    static func height(resultCount: Int, showsStatus: Bool) -> CGFloat {
        var h = capsuleHeight + margin * 2
        if resultCount > 0 {
            h += gap + CGFloat(min(resultCount, maxVisibleRows)) * rowHeight + 12 + footerHeight
        } else if showsStatus {
            h += gap + statusHeight
        }
        return h
    }

    var body: some View {
        VStack(spacing: Self.gap) {
            capsule
            if !model.results.isEmpty {
                resultList
            } else if model.showsStatus {
                status
            }
        }
        .padding(Self.margin)
        .frame(width: FileSearchPanel.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var capsule: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(
                text: $model.query,
                placeholder: L("搜索文件，支持拼音和首字母"),
                focusToken: model.focusToken,
                fontSize: 20,
                onMove: { model.move($0) },
                onSubmit: { model.openSelected() },
                onCancel: { model.onClose() }
            )
            if index.isIndexing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.capsuleHeight)
        .background(VisualEffectBackground().clipShape(Capsule(style: .continuous)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var resultList: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { position, result in
                            FileResultRow(model: model, result: result, isSelected: position == model.selection)
                                .id(result.id)
                                .onTapGesture {
                                    model.selection = position
                                    model.openSelected()
                                }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, newValue in
                    guard model.results.indices.contains(newValue) else { return }
                    proxy.scrollTo(model.results[newValue].id)
                }
            }
            Divider().opacity(0.6)
            HStack(spacing: 12) {
                KeyHint(key: "Enter", action: L("打开"))
                KeyHint(key: "Ctrl+Enter", action: L("在访达中显示"))
                Spacer(minLength: 0)
                KeyHint(key: "Esc", action: L("关闭"))
            }
            .padding(.horizontal, 14)
            .frame(height: Self.footerHeight)
        }
        .background(VisualEffectBackground().clipShape(card))
        .overlay(card.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private var status: some View {
        HStack(spacing: 10) {
            if index.isIndexing {
                ProgressView().controlSize(.small)
                Text(L("正在建立索引，马上就好…"))
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

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

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
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: FileSearchView.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
    }
}
