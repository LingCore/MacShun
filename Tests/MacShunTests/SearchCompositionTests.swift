// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
@testable import MacShun

@Suite("搜索框输入法", .serialized)
@MainActor
struct SearchCompositionTests {
    enum Field: CaseIterable { case panel, settings }

    @Test(arguments: Field.allCases)
    func refreshPreservesCompositionUntilCommit(_ kind: Field) async throws {
        _ = NSApplication.shared
        let selection = SettingsSelection()
        let view = SearchHarness(kind: kind, selection: selection)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try #require(findField(in: host))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let insertion = NSRange(location: NSNotFound, length: 0)
        editor.insertText("a", replacementRange: insertion)
        #expect(selection.query == "a")
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: insertion)
        #expect(editor.hasMarkedText())
        #expect(selection.query == "a")

        // 已有搜索结果可能在等候选词时才到达；驱动一次真实的 SwiftUI 刷新。
        selection.windowVisible.toggle()
        try await Task.sleep(for: .milliseconds(60))
        #expect(window.firstResponder === editor)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "azhong")
        #expect(selection.query == "a")
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)),
                         #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:))] {
            #expect(field.delegate?.control?(field, textView: editor, doCommandBy: selector) == false)
        }
        #expect(selection.query == "a")
        editor.insertText("中", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        #expect(selection.query == "a中")

        editor.setMarkedText("wen", selectedRange: NSRange(location: 3, length: 0), replacementRange: insertion)
        editor.insertText("", replacementRange: editor.markedRange())
        #expect(selection.query == "a中")

        // 输入法也可以原样确认当前拼写。
        editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: insertion)
        editor.unmarkText()
        try await Task.sleep(for: .milliseconds(60))
        #expect(selection.query == "a中x")

        // 清除和英文/拼音首字母仍然即时生效。
        selection.query = ""
        try await Task.sleep(for: .milliseconds(60))
        #expect(editor.string.isEmpty)
        editor.insertText("jtb", replacementRange: insertion)
        #expect(selection.query == "jtb")
    }

    private func findField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { self.findField(in: $0) }.first
    }
}

private struct SearchHarness: View {
    let kind: SearchCompositionTests.Field
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        VStack {
            switch kind {
            case .panel:
                SearchField(text: $selection.query, placeholder: selection.windowVisible ? "Search" : "", focusToken: 0,
                            onMove: { _ in }, onSubmit: {}, onCancel: {}, onTab: { _ in })
            case .settings:
                SettingsSearchField(selection: selection, onSubmit: {})
            }
            Text(selection.windowVisible ? "1" : "0")
        }
    }
}
