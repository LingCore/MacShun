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
        didSet { refresh() }
    }
    @Published private(set) var results: [ClipboardItem] = []
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

    init(store: ClipboardStore) {
        self.store = store
        subscription = store.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func prepareForShow() {
        query = ""
        selection = 0
        refresh()
        focusToken += 1
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
                placeholder: "搜索剪贴板历史，支持拼音和首字母",
                focusToken: model.focusToken,
                onMove: { model.move($0) },
                onSubmit: { model.pasteSelected() },
                onCancel: { model.onClose() }
            )
            if !model.results.isEmpty {
                Text("\(model.results.count) 条")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
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
        if index == 0 { return "已固定" }
        if !results[index].pinned && results[index - 1].pinned { return "最近" }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(model.query.isEmpty ? "还没有记录" : "没有找到")
                .font(.headline)
            Text(model.query.isEmpty ? "复制的文字和图片会出现在这里" : "换个关键词，或者试试拼音首字母")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(key: "↑↓", action: "选择")
            KeyHint(key: "Enter", action: "粘贴")
            KeyHint(key: "Ctrl+P", action: "固定")
            KeyHint(key: "Ctrl+Del", action: "删除")
            Spacer(minLength: 0)
            KeyHint(key: "Esc", action: "关闭")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

/// 底部的按键提示，按键画成键帽的样子。
private struct KeyHint: View {
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
        f.locale = Locale(identifier: "zh_CN")
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
                Text("图片").font(.system(size: 13))
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
            parts.append("图片 \(w)×\(h)")
        }
        if let app = item.sourceApp { parts.append(AppInfo.name(app)) }
        parts.append(Self.timeFormatter.localizedString(for: item.lastUsed, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            RowButton(symbol: item.pinned ? "pin.slash" : "pin", help: item.pinned ? "取消固定" : "固定") {
                model.store.togglePin(item.id)
            }
            RowButton(symbol: "trash", help: "删除") {
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

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 搜索框。获得焦点时只允许英文输入，这样直接打 “jtb” 就能搜索，不会先进入中文输入法的候选状态。
/// 方向键、Enter、Esc 交给面板处理；输入法正在组字时这些键仍归输入法。
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RomanOnlyTextField {
        let field = RomanOnlyTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ field: RomanOnlyTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
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
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

final class RomanOnlyTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }
        return ok
    }
}
