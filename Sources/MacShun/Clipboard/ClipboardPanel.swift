// SPDX-License-Identifier: MIT

import AppKit
import Combine
import ImageIO
import SwiftUI

/// 剪贴板历史面板（C1）。不会把本程序切到前台，原来的应用保持在前台，选中后直接粘贴到它里面。
final class ClipboardPanel: NSPanel {
    static let size = NSSize(width: 400, height: 460)

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
        didSet {
            cancelClear()
            refresh()
        }
    }
    @Published private(set) var results: [ClipboardItem] = []
    /// 点了一次“全部清除”，等着再点一次确认（过几秒自动取消）
    @Published private(set) var confirmingClear = false
    @Published var selection = 0
    /// 鼠标停在哪一条上
    @Published var hoveredID: UUID?
    /// 每次打开面板时加一，搜索框据此重新获得焦点。
    @Published private(set) var focusToken = 0

    let store: ClipboardStore
    var onPaste: (ClipboardItem) -> Void = { _ in }
    var onClose: () -> Void = {}
    @Published private(set) var copyFeedback: String?
    private var textCopy: Task<Void, Never>?
    var onFloat: (ClipboardItem) -> Void = { _ in }

    private var thumbnails: [UUID: NSImage] = [:]
    private var subscription: AnyCancellable?
    private var clearTimeout: DispatchWorkItem?

    init(store: ClipboardStore) {
        self.store = store
        subscription = store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(keepingSelection: true) }
    }

    func prepareForShow() {
        cancelTextCopy()
        query = ""
        selection = 0
        cancelClear()
        refresh()
        focusToken += 1
    }

    /// 有没固定的记录可以清。搜索时不显示“全部清除”，免得以为只清搜到的那些
    var canClear: Bool { query.isEmpty && store.items.contains { !$0.pinned } }

    /// 全部清除：点两下才清，免得误点。固定的条目保留（和 Windows 一样）
    func clearTapped() {
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
        let previous = keepingSelection && !query.isEmpty ? selectedItem?.id : nil
        results = store.search(query)
        if let previous, let index = results.firstIndex(where: { $0.id == previous }) { selection = index }
        if selection >= results.count { selection = max(results.count - 1, 0) }
        let ids = Set(store.items.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
    }

    var selectedItem: ClipboardItem? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    func pasteSelected() {
        if let item = selectedItem { onPaste(item) }
    }

    func togglePinSelected() {
        if let item = selectedItem { store.togglePin(item.id) }
    }

    func deleteSelected() {
        if let item = selectedItem { store.delete(item.id) }
    }

    func cancelTextCopy() {
        textCopy?.cancel()
        textCopy = nil
        copyFeedback = nil
    }

    func copyImageText(_ item: ClipboardItem, to board: NSPasteboard = .general) {
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

    /// 缩略图，按需生成并缓存。
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let url = store.imageURL(for: item),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails[item.id] = image
        return image
    }
}

// MARK: - 界面

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            if model.results.isEmpty {
                emptyState
            } else {
                list
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(idealWidth: ClipboardPanel.size.width, maxWidth: .infinity,
               idealHeight: ClipboardPanel.size.height, maxHeight: .infinity)
        .background(VisualEffectBackground())
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            SearchField(
                text: $model.query,
                placeholder: L("搜索剪贴板，支持拼音和首字母"),
                focusToken: model.focusToken,
                onMove: { model.move($0) },
                onSubmit: { model.pasteSelected() },
                onCancel: { model.onClose() }
            )
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
        .frame(height: 50)
    }

    /// 右上角的“全部清除”，和 Windows 的剪贴板历史一样的位置。点一下变红，再点一下才清
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        if let title = groupTitle(at: index) {
                            Text(title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 2 : 10)
                                .padding(.bottom, 4)
                        }
                        ClipboardRow(model: model, item: item, isSelected: index == model.selection)
                            .id(item.id)
                            .onTapGesture {
                                model.selection = index
                                model.pasteSelected()
                            }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, newValue in
                guard model.results.indices.contains(newValue) else { return }
                proxy.scrollTo(model.results[newValue].id)
            }
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
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(model.query.isEmpty ? L("还没有记录") : L("没有找到"))
                .font(.headline)
            Text(model.query.isEmpty ? L("复制的文字和图片会出现在这里") : L("换个关键词，或者试试拼音首字母"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 放不下（英文的字比中文长）时先收紧间距，再省掉谁都知道的“↑↓ 选择”和“Esc 关闭”。
    private var footer: some View {
        Group {
            if let feedback = model.copyFeedback {
                Text(feedback).font(.callout).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    hints(spacing: 12, all: true)
                    hints(spacing: 8, all: true)
                    hints(spacing: 12, all: false)
                    KeyHint(key: "Enter", action: L("粘贴"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func hints(spacing: CGFloat, all: Bool) -> some View {
        HStack(spacing: spacing) {
            if all { KeyHint(key: "↑↓", action: L("选择")) }
            KeyHint(key: "Enter", action: L("粘贴"))
            KeyHint(key: "Ctrl+P", action: L("固定"))
            KeyHint(key: "Ctrl+Del", action: L("删除"))
            if all {
                Spacer(minLength: 0)
                KeyHint(key: "Esc", action: L("关闭"))
            }
        }
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
            sourceIcon
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
        .contextMenu {
            if item.kind == .image {
                Button(L("复制图中文字")) { model.copyImageText(item) }
                Button(L("贴到屏幕")) { model.onFloat(item) }
            }
        }
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
                    Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
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
            if let image = model.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailSize(image).width, height: thumbnailSize(image).height)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1))
                    )
            } else {
                Text(L("图片")).font(.system(size: 13))
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
    private func thumbnailSize(_ image: NSImage) -> CGSize {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
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
            if item.kind == .image {
                RowButton(symbol: "text.viewfinder", help: L("复制图中文字")) { model.copyImageText(item) }
                RowButton(symbol: "macwindow.on.rectangle", help: L("贴到屏幕")) { model.onFloat(item) }
            }
            RowButton(symbol: item.pinned ? "pin.slash" : "pin", help: item.pinned ? L("取消固定") : L("固定")) {
                model.store.togglePin(item.id)
            }
            RowButton(symbol: "trash", help: L("删除")) {
                model.store.delete(item.id)
            }
        }
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
