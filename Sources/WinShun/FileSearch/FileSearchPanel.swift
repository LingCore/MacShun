// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Combine
import SwiftUI

/// 文件搜索（F1、F2）：连按两下 Ctrl 弹出胶囊形的搜索框，边打字边出结果，按文件名和文件内容搜。只在主线程上使用。
final class FileSearchController {
    private let configStore: ConfigStore
    private let history = OpenHistory()
    private let index = FileIndex.shared
    private let contentIndex = ContentIndex.shared
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var subscriptions: Set<AnyCancellable> = []
    /// 打开前的输入法。打开时切到英文（直接打拼音首字母），关闭时切回来。
    private var savedInputSource: TISInputSource?

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
        if cfg.enabled && cfg.activated {
            index.start()
        } else if !cfg.enabled {
            index.stop()
            hide()
            history.clear()
        }
        // 认不认图片文字变了：重新扫一遍，把图片交给内容索引，或者从内容索引里去掉
        if ContentExtractor.readsImages.get() != cfg.searchImageText {
            ContentExtractor.readsImages.set(cfg.searchImageText)
            if cfg.enabled && cfg.activated && (index.isIndexing || index.lastIndexed != nil) { index.rebuild() }
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
        model.isShown = true
        resize()
        position()
        savedInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        // 先切到英文，直接打拼音首字母就能搜；要搜中文内容时可以再切回中文输入法
        if let english = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
           savedInputSource.map({ !CFEqual($0, english) }) ?? true {
            TISSelectInputSource(english)
        }
        FrontAppTracker.shared.fileSearchPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        FrontAppTracker.shared.fileSearchPanelActive.set(false)
        if panel.isVisible { panel.orderOut(nil) }
        restoreInputSource()
        // 关着时不用跟着文件变化重新搜
        model.isShown = false
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
        history.record(result.path)
        let url = URL(fileURLWithPath: result.path)
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 面板

    private func makeModel() -> FileSearchModel {
        let model = FileSearchModel(index: index, contentIndex: contentIndex)
        model.history = history
        model.onOpen = { [weak self] result, reveal in self?.open(result, reveal: reveal) }
        model.onClose = { [weak self] in self?.hide() }
        // 结果多少变了，面板跟着变高变矮
        model.$results.combineLatest(model.$query, index.$isIndexing, model.$searchingContent)
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
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.onReveal = { [weak self] in self?.model.openSelected(reveal: true) }
        return panel
    }

    /// 面板高度：胶囊加上下面的结果列表。保持顶边不动。
    private func resize() {
        let height = FileSearchView.height(resultCount: model.results.count, hasContentSection: model.contentStart != nil,
                                           showsStatus: model.showsStatus)
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
    /// Ctrl+Enter、⌘+Enter：在访达中显示
    var onReveal: (() -> Void)?

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

    /// 输入框会把 Ctrl+Enter 当成插入换行、⌘+Enter 什么也不做，到不了“打开”，所以在面板这一层先接住。
    /// 输入法还在拼字时不接，回车留给输入法。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
           !event.modifierFlags.intersection([.control, .command]).isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true, let onReveal {
            onReveal()
            return
        }
        super.sendEvent(event)
    }
}

/// 搜索范围：全部、只看文件名、只看内容。
enum FileSearchScope: Int, CaseIterable, Identifiable {
    case all, files, contents

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: L("全部")
        case .files: L("文件")
        case .contents: L("内容")
        }
    }
}

/// 搜索框的数据和操作。
final class FileSearchModel: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    /// 文件名结果在前，内容结果在后
    @Published private(set) var results: [FileSearchResult] = []
    @Published var selection = 0
    @Published private(set) var focusToken = 0
    /// 也按内容搜（F2）。设置里关掉了就没有范围可选，只搜文件名
    @Published var searchesContent = false
    /// 搜索范围，每次打开都是“文件”
    @Published var scope: FileSearchScope = .files {
        didSet {
            guard scope != oldValue else { return }
            merge(resetSelection: true)
            scheduleContentSearch()
        }
    }
    /// 设置里没关内容搜索时才看范围
    var effectiveScope: FileSearchScope { searchesContent ? scope : .files }
    /// 内容搜索已经发出去、结果还没回来
    @Published private(set) var searchingContent = false
    /// 搜索框开着
    var isShown = false

    let index: FileIndex
    let contentIndex: ContentIndex
    /// 打开过的文件排在前面
    var history: OpenHistory?
    var onOpen: (FileSearchResult, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    private var generation = 0
    private var nameResults: [FileSearchResult] = []
    private var contentResults: [FileSearchResult] = []
    private var pendingContentSearch: DispatchWorkItem?
    private var icons: [String: NSImage] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    /// 有内容结果时，文件名结果最多显示几条，免得内容结果被挤到很下面
    static let maxNameResultsWithContent = 6

    init(index: FileIndex, contentIndex: ContentIndex) {
        self.index = index
        self.contentIndex = contentIndex
        // 索引建好、文件有变化时，按现在的关键词重新搜一次。扫描外接硬盘时一秒会有好几次，选中的那条不动
        index.$fileCount
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isShown, !self.query.isEmpty else { return }
                self.scheduleSearch(resetSelection: false)
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

    /// 内容结果从第几条开始（在这里显示“文件内容”的小标题）；没有内容结果、或者只看内容时为 nil
    var contentStart: Int? { effectiveScope == .all ? results.firstIndex { $0.snippet != nil } : nil }

    /// 只看内容时，打的字太少还不会搜
    var needsLongerQuery: Bool {
        effectiveScope == .contents && !query.trimmingCharacters(in: .whitespaces).isEmpty && !ContentIndex.qualifies(query)
    }

    /// Tab、Shift+Tab 切换范围
    func cycleScope(reverse: Bool) {
        guard searchesContent else { return }
        let all = FileSearchScope.allCases
        scope = all[(scope.rawValue + (reverse ? all.count - 1 : 1)) % all.count]
    }

    /// 结果下面要不要显示一行状态（正在建立索引、没有找到）
    /// 内容还在搜的时候先不说“没有找到”，免得一闪
    var showsStatus: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && results.isEmpty && !(searchingContent && effectiveScope != .files)
    }

    func prepareForShow() {
        query = ""
        nameResults = []
        contentResults = []
        results = []
        selection = 0
        scope = .files
        searchingContent = false
        focusToken += 1
    }

    /// 打了字时从第一条选起；文件有变化重新搜时，选中的那条不动
    private func scheduleSearch(resetSelection: Bool = true) {
        generation += 1
        let current = generation
        let q = query
        index.search(q, boosts: history?.boosts() ?? [:]) { [weak self] found in
            guard let self, current == self.generation else { return }
            self.nameResults = found
            self.merge(resetSelection: resetSelection)
        }
        scheduleContentSearch()
    }

    /// 内容搜索稍等一下再发（打字很快时只搜最后一次），旧的结果先留着，新的来了再换，免得列表一闪一闪。
    private func scheduleContentSearch() {
        pendingContentSearch?.cancel()
        let q = query
        guard effectiveScope != .files, ContentIndex.qualifies(q) else {
            searchingContent = false
            if !contentResults.isEmpty {
                contentResults = []
                merge(resetSelection: false)
            }
            return
        }
        let current = generation
        searchingContent = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.contentIndex.search(q) { [weak self] hits in
                guard let self, current == self.generation else { return }
                // 打开过的文件往前放，其余按相关程度
                let boosts = self.history?.boosts() ?? [:]
                self.contentResults = hits.enumerated().map { position, hit in
                    FileSearchResult(path: hit.path, name: (hit.path as NSString).lastPathComponent,
                                     isDirectory: false, score: (boosts[hit.path] ?? 0) - Double(position) * 0.01, snippet: hit.snippet)
                }
                .sorted { $0.score > $1.score }
                self.searchingContent = false
                self.merge(resetSelection: false)
            }
        }
        pendingContentSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 合并两路结果。同一个文件名字和内容都匹配时只列在文件名里。选中的那条尽量不动。
    private func merge(resetSelection: Bool) {
        let selectedPath = resetSelection ? nil : selectedResult?.path
        defer { selection = selectedPath.flatMap { path in results.firstIndex { $0.path == path } } ?? 0 }
        switch effectiveScope {
        case .files:
            results = nameResults
            return
        case .contents:
            results = contentResults
            return
        case .all:
            break
        }
        // 内容结果都是名字也匹配的文件时，不用为它们腾地方
        let allNamePaths = Set(nameResults.map(\.path))
        let hasContentOnly = contentResults.contains { !allNamePaths.contains($0.path) }
        let names = hasContentOnly ? Array(nameResults.prefix(Self.maxNameResultsWithContent)) : nameResults
        let shown = Set(names.map(\.path))
        results = names + contentResults.filter { !shown.contains($0.path) }
    }

    #if DEBUG
    /// 截图用：直接显示给定的结果
    func showPreview(query: String, results: [FileSearchResult]) {
        self.query = query
        generation += 1
        pendingContentSearch?.cancel()
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
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        openSelected(reveal: flags.contains(.control) || flags.contains(.command))
    }

    func openSelected(reveal: Bool) {
        guard let result = selectedResult else { return }
        onOpen(result, reveal)
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
    static let rowHeight: CGFloat = 46
    static let maxVisibleRows = 8
    /// 四周给阴影留的空白
    static let margin: CGFloat = 12
    private static let gap: CGFloat = 8
    private static let footerHeight: CGFloat = 30
    private static let statusHeight: CGFloat = 56
    static let sectionHeaderHeight: CGFloat = 26

    static func height(resultCount: Int, hasContentSection: Bool, showsStatus: Bool) -> CGFloat {
        var h = capsuleHeight + margin * 2
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
                placeholder: placeholder,
                focusToken: model.focusToken,
                fontSize: 20,
                romanOnly: false,
                onMove: { model.move($0) },
                onSubmit: { model.openSelected() },
                onCancel: { model.onClose() },
                onTab: model.searchesContent ? { model.cycleScope(reverse: $0) } : nil
            )
            if index.isIndexing {
                ProgressView().controlSize(.small)
            }
            if model.searchesContent {
                ScopePicker(selection: $model.scope)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Self.capsuleHeight)
        .background(VisualEffectBackground().clipShape(Capsule(style: .continuous)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private var placeholder: String {
        switch model.effectiveScope {
        case .files: L("搜索文件，支持拼音和首字母")
        case .contents: L("搜索文件里的文字")
        case .all: L("搜索文件名或内容，文件名支持拼音首字母")
        }
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    private var resultList: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { position, result in
                            if position == model.contentStart {
                                sectionHeader
                            }
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
                if model.searchesContent {
                    KeyHint(key: "Tab", action: L("切换范围"))
                }
                Spacer(minLength: 0)
                if model.effectiveScope != .files && contentIndex.pendingCount > 0 {
                    // 内容还没读完，结果可能不全
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(L("正在读取文件内容"))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    KeyHint(key: "Esc", action: L("关闭"))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.footerHeight)
        }
        .background(VisualEffectBackground().clipShape(card))
        .overlay(card.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
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
                Text(L("至少输入两个汉字或三个字母才搜内容"))
            } else if model.effectiveScope == .contents && contentIndex.pendingCount > 0 {
                ProgressView().controlSize(.small)
                Text(L("正在读取文件内容，结果可能还不全…"))
            } else if index.isIndexing && model.effectiveScope != .contents {
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
                    Text(highlighted(snippet))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
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

    /// 搜索词在摘要里加粗、用正文颜色
    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        for term in model.query.split(whereSeparator: { $0.isWhitespace }) {
            var from = text.startIndex
            while from < text.endIndex, let found = text[from...].range(of: String(term), options: .caseInsensitive) {
                text[found].foregroundColor = .primary
                text[found].font = .system(size: 12, weight: .semibold)
                from = found.upperBound
            }
        }
        return text
    }
}

/// 搜索框右边的“全部 / 文件 / 内容”。
private struct ScopePicker: View {
    @Binding var selection: FileSearchScope

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FileSearchScope.allCases) { scope in
                let selected = scope == selection
                Text(scope.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selected ? Color.primary.opacity(0.14) : .clear)
                            .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 1, y: 0.5)
                    )
                    .contentShape(Capsule(style: .continuous))
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) { selection = scope }
                    }
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("搜索范围"))
    }
}
