// SPDX-License-Identifier: GPL-3.0-or-later

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

    private var thumbnails: [UUID: NSImage] = [:]
    private var subscription: AnyCancellable?
    private var clearTimeout: DispatchWorkItem?

    init(store: ClipboardStore) {
        self.store = store
        subscription = store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func prepareForShow() {
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

    func refresh() {
        results = store.search(query)
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
        .frame(width: ClipboardPanel.size.width, height: ClipboardPanel.size.height)
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
                .foregroundStyle(confirming ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(confirming ? Color.red.opacity(0.85) : Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.plain)
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
        ViewThatFits(in: .horizontal) {
            hints(spacing: 12, all: true)
            hints(spacing: 8, all: true)
            hints(spacing: 12, all: false)
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
                meta
            }
            Spacer(minLength: 0)
            if hovering {
                actions
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(Rectangle())
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
        parts.append(Self.timeFormatter.localizedString(for: item.lastUsed, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 2) {
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
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
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

/// 搜索框。默认获得焦点时只允许英文输入，这样直接打 “jtb” 就能搜索，不会先进入中文输入法的候选状态。
/// 方向键、Enter、Esc 交给面板处理；输入法正在组字时这些键仍归输入法。
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int
    var fontSize: CGFloat = 16
    /// false 时也能切到中文输入法（文件搜索要能打中文搜内容）
    var romanOnly = true
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Tab（false）、Shift+Tab（true）。nil 时照常处理
    var onTab: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RomanOnlyTextField {
        let field = RomanOnlyTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.romanOnly = romanOnly
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // 粘贴进来的换行变成空格（从终端、聊天里复制的路径后面常带一个换行）
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ field: RomanOnlyTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastFocusToken = -1

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            // Alt+Enter（⌥↩）、Ctrl+Enter、⌥Tab 会往一行的搜索框里插入真的换行、Tab，不要
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
                return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            case #selector(NSResponder.insertTab(_:)):
                guard let onTab = parent.onTab else { return false }
                onTab(false)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                guard let onTab = parent.onTab else { return false }
                onTab(true)
                return true
            default: return false
            }
        }
    }
}

final class RomanOnlyTextField: NSTextField {
    var romanOnly = true

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, romanOnly, let editor = currentEditor() as? NSTextView {
            editor.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        return ok
    }
}
