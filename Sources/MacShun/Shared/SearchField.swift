// SPDX-License-Identifier: MIT

import SwiftUI

extension NSTextField {
    /// 组字中的文本归输入法管理，两端都等上屏后再同步。
    var committedSearchQuery: String? {
        guard let editor = currentEditor() as? NSTextView else { return stringValue }
        return editor.hasMarkedText() ? nil : editor.string
    }

    func applySearchQuery(_ query: String) {
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
        field.applySearchQuery(text)
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

        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField, let query = field.committedSearchQuery,
                  query != parent.text else { return }
            parent.text = query
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
