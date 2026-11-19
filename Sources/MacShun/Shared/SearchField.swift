// SPDX-License-Identifier: MIT

import SwiftUI

extension NSTextField {
    /// 组字中的文本归输入法管理，两端都等上屏后再同步。
    var committedSearchQuery: String? {
        guard let editor = currentEditor() as? NSTextView else { return stringValue }
        return editor.hasMarkedText() ? nil : editor.string
    }

    func applySearchQuery(_ query: String, force: Bool = false) {
        if force {
            if let editor = currentEditor() as? NSTextView {
                if editor.hasMarkedText() { editor.unmarkText() }
                if editor.string != query {
                    stringValue = query
                    editor.selectedRange = NSRange(location: (query as NSString).length, length: 0)
                }
            } else if stringValue != query {
                stringValue = query
            }
            return
        }
        guard let current = committedSearchQuery, current != query else { return }
        stringValue = query
    }
}

/// 文件搜索和剪贴板共用的单行搜索框。选词时让输入法优先处理面板快捷键。
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusToken: Int
    var fontSize: CGFloat = 16
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Tab（false）、Shift+Tab（true）。nil 时照常处理
    var onTab: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // 粘贴进来的换行变成空格（从终端、聊天里复制的路径后面常带一个换行）
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncFromBinding(in: field)
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak field] in
                guard let field, field.currentEditor() == nil else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastFocusToken = -1
        var lastSyncedText: String
        var isApplyingQuery = false
        private var driftCheckScheduled = false

        init(_ parent: SearchField) {
            self.parent = parent
            self.lastSyncedText = parent.text
        }

        func syncFromBinding(in field: NSTextField) {
            let query = parent.text
            let programmatic = query != lastSyncedText
            if programmatic {
                lastSyncedText = query
            }
            isApplyingQuery = true
            field.applySearchQuery(query, force: programmatic)
            isApplyingQuery = false
        }

        func controlTextDidChange(_ note: Notification) {
            guard !isApplyingQuery,
                  let field = note.object as? NSTextField, let query = field.committedSearchQuery else { return }
            lastSyncedText = query
            guard query != parent.text else { return }
            parent.text = query
            // 若外部在同一帧把绑定改回旧值，SwiftUI 可能跳过 updateNSView；下一轮主循环补查一次绑定实时值。
            guard !driftCheckScheduled else { return }
            driftCheckScheduled = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self else { return }
                self.driftCheckScheduled = false
                guard let field, self.parent.text != self.lastSyncedText else { return }
                self.syncFromBinding(in: field)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
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
