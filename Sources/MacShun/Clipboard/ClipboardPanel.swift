// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI

/// 剪贴板历史面板（C1）。不会把本程序切到前台，原来的应用保持在前台，选中后直接粘贴到它里面。
final class ClipboardPanel: NSPanel {
    static let size = NSSize(width: 400, height: 460)
    static let previewWidth: CGFloat = 344
    static let expandedWidth = size.width + previewWidth

    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
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

/// 面板的数据和操作。
@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { resetResults() } }
    }
    @Published var filter: ClipboardFilter = .all {
        didSet { if filter != oldValue { resetResults() } }
    }
    @Published private(set) var results: [ClipboardItem] = []
    @Published private(set) var isPreviewOpen = false
    @Published private(set) var opensAbove = false
    /// 点了一次“全部清除”，等着再点一次确认（过几秒自动取消）
    @Published private(set) var confirmingClear = false
    @Published var selection = 0 {
        didSet { if selection != oldValue { previewSelection = nil } }
    }
    /// 鼠标停在哪一条上
    @Published var hoveredID: UUID? {
        didSet { if hoveredID != oldValue { onHoverChange(hoveredID) } }
    }
    @Published var showsQuickPasteNumbers = false
    @Published private(set) var visibleRowIDs: Set<UUID> = []
    @Published private(set) var previewSelection: String?
    /// 每次打开面板时加一，搜索框据此重新获得焦点。
    @Published private(set) var focusToken = 0

    let store: ClipboardStore
    private let pasteboard: NSPasteboard
    var onPaste: (ClipboardItem) -> Void = { _ in }
    var onCopy: (ClipboardItem) -> Void = { _ in }
    var onPreviewChange: (Bool) -> Void = { _ in }
    var onHoverChange: (UUID?) -> Void = { _ in }
    var onClose: () -> Void = {}
    @Published private(set) var copyFeedback: String?
    private var textCopy: Task<Void, Never>?
    var onFloat: (ClipboardItem) -> Void = { _ in }

    let thumbnails = ClipboardImageCache(size: .row)
    let previews = ClipboardImageCache(size: .preview)
    private var subscription: AnyCancellable?
    private var clearTimeout: DispatchWorkItem?

    init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        subscription = store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(keepingSelection: true) }
    }

    func prepareForShow(opensAbove: Bool = false) {
        cancelTextCopy()
        setPreviewOpen(false)
        self.opensAbove = opensAbove
        filter = .all
        query = ""
        selection = 0
        hoveredID = nil
        cancelClear()
        refresh()
        thumbnails.prepareForOpening(selectedItem.flatMap { store.imageURL(for: $0) })
        focusToken += 1
    }

    private func resetResults() {
        cancelClear()
        selection = 0
        hoveredID = nil
        refresh()
    }

    /// 只在完整历史中提供“全部清除”，避免被误解为只清除筛选结果。
    var canClear: Bool { filter == .all && query.isEmpty && store.items.contains { !$0.pinned } }

    /// 全部清除：点两下才清，免得误点。固定的条目保留（和 Windows 一样）
    func clearTapped() {
        guard canClear else { return }
        guard confirmingClear else {
            confirmingClear = true
            let timeout = DispatchWorkItem { [weak self] in self?.confirmingClear = false }
            clearTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
            return
        }
        cancelClear()
        store.clearUnpinned()
        selection = 0
    }

    private func cancelClear() {
        clearTimeout?.cancel()
        clearTimeout = nil
        if confirmingClear { confirmingClear = false }
    }

    func refresh(keepingSelection: Bool = false) {
        let previous = selectedItem
        results = store.search(query, filter: filter)
        if keepingSelection, let previous,
           let index = results.firstIndex(where: { $0.id == previous.id || $0.tiffFingerprint == previous.fingerprint }) {
            selection = index
        }
        if selection >= results.count { selection = max(results.count - 1, 0) }
        if selectedItem?.id != previous?.id { previewSelection = nil }
        if let hoveredID, !results.contains(where: { $0.id == hoveredID }) { self.hoveredID = nil }
        if results.isEmpty { setPreviewOpen(false) }
    }

    var selectedItem: ClipboardItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + (opensAbove ? -delta : delta), 0), results.count - 1)
    }

    func select(_ item: ClipboardItem) {
        if let index = results.firstIndex(where: { $0.id == item.id }) { selection = index }
    }

    func setPreviewOpen(_ open: Bool) {
        guard open != isPreviewOpen, !open || selectedItem != nil else { return }
        previewSelection = nil
        hoveredID = nil
        isPreviewOpen = open
        onPreviewChange(open)
    }

    func updateVisibleRows(_ ids: Set<UUID>) {
        if visibleRowIDs != ids { visibleRowIDs = ids }
    }

    private var quickPasteRows: [ClipboardItem] {
        Array(results.lazy.filter { self.visibleRowIDs.contains($0.id) }.prefix(9))
    }

    func quickPasteNumber(for id: UUID) -> Int? {
        guard showsQuickPasteNumbers else { return nil }
        return quickPasteRows.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    func pasteVisibleRow(_ number: Int) {
        let rows = quickPasteRows
        guard number > 0, number <= rows.count else { return }
        onPaste(rows[number - 1])
    }

    func selectPreviewText(_ text: String?, for id: UUID) {
        guard isPreviewOpen, selectedItem?.id == id, previewSelection != text else { return }
        previewSelection = text
    }

    func pastePreview(_ item: ClipboardItem) {
        guard let text = previewSelection, selectedItem?.id == item.id else { onPaste(item); return }
        var excerpt = item
        excerpt.kind = .text
        excerpt.text = text
        excerpt.extraFiles = [:]
        onPaste(excerpt)
    }

    func cancel() {
        if isPreviewOpen {
            setPreviewOpen(false)
            focusToken += 1
        } else {
            onClose()
        }
    }

    func pasteSelected() {
        if let item = selectedItem { onPaste(item) }
    }

    func pasteAsPlainText(_ item: ClipboardItem) {
        guard item.kind == .text, item.text != nil else { return }
        var plainItem = item
        plainItem.extraFiles = [:]
        onPaste(plainItem)
    }

    func togglePinSelected() {
        if let item = selectedItem { store.togglePin(item.id) }
    }

    func handleDeleteShortcut(_ key: CGKeyCode, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) -> Bool {
        // ⌥⌦（含 Windows 布局转来的 Ctrl+Delete）交给编辑器向右删词。
        guard modifiers == .command, key == KeyCode.forwardDelete || key == KeyCode.backspace else { return false }
        if !isRepeat, let item = selectedItem { store.delete(item.id) }
        return true
    }

    func cancelTextCopy() {
        textCopy?.cancel()
        textCopy = nil
        copyFeedback = nil
    }

    func showFeedback(_ message: String) {
        cancelTextCopy()
        copyFeedback = message
    }

    func copyImageText(_ item: ClipboardItem, to board: NSPasteboard? = nil) {
        let board = board ?? pasteboard
        cancelTextCopy()
        let count = board.changeCount
        copyFeedback = L("正在识别文字…")
        textCopy = Task {
            let value = await store.recognizedText(for: item.id)
            guard !Task.isCancelled else { return }
            guard store.items.contains(where: { $0.id == item.id }), let value, !value.isEmpty else {
                copyFeedback = L("图片里没有可复制的文字")
                return
            }
            guard board.changeCount == count else { copyFeedback = L("剪贴板已更改，请重新取字"); return }
            let textItem = NSPasteboardItem()
            guard textItem.setString(value, forType: .string) else { copyFeedback = L("未能写入剪贴板"); return }
            board.clearContents()
            copyFeedback = board.writeObjects([textItem]) ? L("已复制识别的文字") : L("未能写入剪贴板")
        }
    }

}

// MARK: - 界面

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    static let searchBarHeight: CGFloat = 50

    var body: some View {
        GeometryReader { geometry in
            let showBoth = model.isPreviewOpen && geometry.size.width >= ClipboardPanel.expandedWidth - 1
            HStack(spacing: 0) {
                if !model.isPreviewOpen || showBoth {
                    history.frame(width: showBoth ? ClipboardPanel.size.width : nil)
                }
                if model.isPreviewOpen, let item = model.selectedItem {
                    if showBoth { Divider().padding(.vertical, 12) }
                    ClipboardPreview(model: model, item: item, showsFeedback: !showBoth)
                        .id(item.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(idealWidth: ClipboardPanel.size.width, idealHeight: ClipboardPanel.size.height)
        .background(VisualEffectBackground())
        .onPreferenceChange(VisibleClipboardRows.self) { model.updateVisibleRows($0) }
    }

    private var history: some View {
        VStack(spacing: 0) {
            if model.opensAbove {
                footer
            } else {
                searchBar
                filters
            }
            Divider().opacity(0.6)
            if model.results.isEmpty {
                emptyState
            } else {
                list.id(model.opensAbove)
            }
            Divider().opacity(0.6)
            if model.opensAbove {
                filters
                searchBar
            } else {
                footer
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(
                text: $model.query,
                placeholder: L("搜索剪贴板"),
                focusToken: model.focusToken,
                onMove: { model.move($0) },
                onSubmit: { model.pasteSelected() },
                onCancel: { model.cancel() }
            )
            .help(L("搜索剪贴板，支持拼音和首字母"))
            // 等着确认清除时，按钮变宽，条数先不显示
            if !model.results.isEmpty && !model.confirmingClear {
                Text(L("%ld 条", model.results.count))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            if model.canClear {
                clearButton
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.searchBarHeight)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            filterPicker
            filterPicker.controlSize(.small)
            filterPicker.controlSize(.mini)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(model.opensAbove ? .top : .bottom, 9)
    }

    private var filterPicker: some View {
        Picker(L("筛选"), selection: $model.filter) {
            ForEach(ClipboardFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    /// 搜索栏右侧的“全部清除”。点一下变红，再点一下才清
    private var clearButton: some View {
        let confirming = model.confirmingClear
        return Button { model.clearTapped() } label: {
            Text(confirming ? L("再点一次清除") : L("全部清除"))
                .font(.system(size: 11, weight: confirming ? .semibold : .regular))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .fixedSize()
        }
        .buttonStyle(.chip(destructive: confirming))
        .help(L("清除没固定的记录，固定的保留"))
    }

    private var list: some View {
        enum ListEdge { case nearest }
        let nearestEdge: UnitPoint = model.opensAbove ? .bottom : .top
        let edge = Color.clear.frame(height: 0).id(ListEdge.nearest).accessibilityHidden(true)
        let rows = Array(model.results.enumerated())
        let initialRowCount = 8
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if !model.opensAbove { edge }
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if model.opensAbove {
                            ForEach(Array(rows.dropFirst(initialRowCount).reversed()), id: \.element.id) { index, item in
                                historyRow(item, at: index)
                            }
                        } else {
                            ForEach(rows, id: \.element.id) { index, item in
                                historyRow(item, at: index)
                            }
                        }
                    }
                    if model.opensAbove {
                        // 先测出靠近搜索框的几项，向上展开时可以直接定位到列表底端。
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(rows.prefix(initialRowCount).reversed()), id: \.element.id) { index, item in
                                historyRow(item, at: index)
                            }
                        }
                        edge
                    }
                }
            }
            .contentMargins(8, for: .scrollContent)
            .defaultScrollAnchor(nearestEdge)
            .scrollIndicators(.never)
            .onChange(of: model.selectedItem?.id) { _, id in
                if model.selection == 0 { proxy.scrollTo(ListEdge.nearest, anchor: nearestEdge) }
                else if let id { proxy.scrollTo(id) }
            }
            .onChange(of: model.focusToken) {
                // Reopening can resize the native panel as SwiftUI lays out the list.
                // Wait for the new viewport before restoring the edge near the search field.
                DispatchQueue.main.async {
                    if model.selection == 0 { proxy.scrollTo(ListEdge.nearest, anchor: nearestEdge) }
                }
            }
            .onAppear {
                guard model.opensAbove else { return }
                DispatchQueue.main.async {
                    if model.selection == 0 { proxy.scrollTo(ListEdge.nearest, anchor: nearestEdge) }
                }
            }
        }
    }

    private func historyRow(_ item: ClipboardItem, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !model.opensAbove { groupHeading(at: index) }
            ClipboardRow(model: model, item: item, isSelected: index == model.selection)
                .background(GeometryReader { geometry in
                    let frame = geometry.frame(in: .scrollView)
                    let viewport = CGRect(origin: .zero, size: geometry.bounds(of: .scrollView)?.size ?? .zero)
                    let visible = frame.height > 0 && viewport.intersection(frame).height >= frame.height / 2
                    Color.clear.preference(key: VisibleClipboardRows.self, value: visible ? [item.id] : [])
                })
            if model.opensAbove { groupHeading(at: index) }
        }
        .id(item.id)
    }

    @ViewBuilder
    private func groupHeading(at index: Int) -> some View {
        if model.filter != .pinned, let title = groupTitle(at: index) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(model.opensAbove ? .bottom : .top, index == 0 ? 2 : 10)
                .padding(model.opensAbove ? .top : .bottom, 4)
        }
    }

    /// 有固定的条目时分成“已固定”和“最近”两组（固定的排在前面）。
    private func groupTitle(at index: Int) -> String? {
        let results = model.results
        guard results.first?.pinned == true else { return nil }
        if index == 0 { return L("已固定") }
        if !results[index].pinned && results[index - 1].pinned { return L("最近") }
        return nil
    }

    private var emptyState: some View {
        let emptyHistory = model.query.isEmpty && model.filter == .all
        return VStack(spacing: 8) {
            Image(systemName: emptyHistory ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(emptyHistory ? L("还没有记录") : L("没有找到"))
                .font(.headline)
            Text(emptyHistory ? L("复制的文字和图片会出现在这里")
                : model.query.isEmpty ? L("这个分类还没有记录") : L("换个关键词，或者试试拼音首字母"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let feedback = model.copyFeedback {
                Text(feedback)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(feedback)
            } else if model.selectedItem != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        KeyHint(key: "↑↓", action: L("选择"))
                        KeyHint(key: "⌘Y", action: L("预览"))
                    }
                    KeyHint(key: "⌘Y", action: L("预览"))
                }
            }
            Spacer(minLength: 0)
            if !model.isPreviewOpen {
                Button { model.pasteSelected() } label: {
                    Label(L("粘贴"), systemImage: "return")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 9)
                        .frame(minHeight: 24)
                }
                .buttonStyle(.chip())
                .disabled(model.selectedItem == nil)
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct VisibleClipboardRows: PreferenceKey {
    static let defaultValue: Set<UUID> = []

    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}

/// 底部的按键提示，按键画成键帽的样子。
struct KeyHint: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(action)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}

private struct ClipboardRow: View {
    @ObservedObject var model: ClipboardPanelModel
    let item: ClipboardItem
    let isSelected: Bool

    private var hovering: Bool { model.hoveredID == item.id }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = AppLanguage.uiLocale
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                if let number = model.quickPasteNumber(for: item.id) {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                } else {
                    sourceIcon
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                content
                HStack(spacing: 6) {
                    meta
                    Spacer(minLength: 0)
                    if hovering || isSelected { actions }
                }
                // 操作放在来源行，鼠标经过时正文保持原有换行，下一条也不会跳动。
                .frame(minHeight: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.onPaste(item) }
        .onTapGesture { model.select(item) }
        .contextMenu { rowMenu }
        .accessibilityAction(named: Text(L("粘贴"))) { model.onPaste(item) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { inside in
            if inside {
                model.hoveredID = item.id
            } else if model.hoveredID == item.id {
                model.hoveredID = nil
            }
        }
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    /// 从哪个应用复制的，找不到应用时按内容类型显示图标。
    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = AppInfo.icon(item.sourceApp) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: item.kind == .image ? "photo" : item.isWebLink ? "link" : "text.alignleft")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(preview(item.text ?? ""))
                .font(.system(size: 13))
                .lineLimit(2)
                .truncationMode(.tail)
        case .image:
            ClipboardImageView(url: model.store.imageURL(for: item), cache: model.thumbnails)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1))
                }
            if !model.query.isEmpty, let text = item.imageText,
               let line = text.split(whereSeparator: \.isNewline).first(where: {
                   $0.localizedCaseInsensitiveContains(model.query)
               }) ?? text.split(whereSeparator: \.isNewline).first {
                Text(String(line)).font(.caption).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    /// 缩略图最高 72、最宽 220，保持原来的比例。
    private var thumbnailSize: CGSize {
        let w = CGFloat(max(item.imageWidth ?? 72, 1)), h = CGFloat(max(item.imageHeight ?? 72, 1))
        let scale = min(72 / h, 220 / w, 1)
        return CGSize(width: max(w * scale, 24), height: max(h * scale, 24))
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Text(metaText)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var metaText: String {
        var parts: [String] = []
        if item.kind == .image, let w = item.imageWidth, let h = item.imageHeight {
            parts.append(L("图片 %@×%@", "\(w)", "\(h)"))
        }
        if let app = item.sourceApp { parts.append(AppInfo.name(app)) }
        let now = Date()
        parts.append(now.timeIntervalSince(item.lastUsed) < 60 ? L("刚刚") :
            Self.timeFormatter.localizedString(for: item.lastUsed, relativeTo: now))
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 4) {
            RowButton(symbol: "eye", help: L("预览")) {
                model.select(item)
                model.setPreviewOpen(true)
            }
            RowButton(symbol: "return", help: L("粘贴")) { model.onPaste(item) }
            RowButton(symbol: item.pinned ? "pin.slash" : "pin", help: item.pinned ? L("取消固定") : L("固定")) {
                model.store.togglePin(item.id)
            }
            Menu {
                rowMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("更多操作"))
            .accessibilityLabel(L("更多操作"))
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button(L("粘贴")) { model.onPaste(item) }
        Button(L("复制")) { model.onCopy(item) }
        if item.kind == .image {
            Button(L("复制图中文字")) { model.copyImageText(item) }
            Button(L("贴到屏幕")) { model.onFloat(item) }
        } else {
            Button(L("粘贴为纯文本")) { model.pasteAsPlainText(item) }
        }
        Divider()
        Button(item.pinned ? L("取消固定") : L("固定")) { model.store.togglePin(item.id) }
        Button(L("删除"), role: .destructive) { model.store.delete(item.id) }
    }

    /// 预览只显示一段：去掉首尾空白，连续的空白和换行合成一个空格。
    private func preview(_ text: String) -> String {
        let head = text.prefix(400)
        return head.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.chip())
        .help(help)
        .accessibilityLabel(help)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
