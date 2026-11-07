// SPDX-License-Identifier: MIT

import AppKit

/// 一个操作只提交一次。历史只保留标注值，图片始终共用同一张底图。
struct CaptureAnnotations {
    private(set) var marks: [CaptureMark]
    private var past: [[CaptureMark]] = []
    private var future: [[CaptureMark]] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var nextNumber: Int { (marks.filter { $0.kind == .number }.map(\.number).max() ?? 0) + 1 }

    init(_ marks: [CaptureMark] = []) { self.marks = marks }

    mutating func change(_ edit: (inout [CaptureMark]) -> Void) {
        let before = marks
        edit(&marks)
        guard before != marks else { return }
        past.append(before)
        if past.count > 100 { past.removeFirst() }
        future.removeAll()
    }

    mutating func undo() {
        guard let before = past.popLast() else { return }
        future.append(marks)
        marks = before
    }

    mutating func redo() {
        guard let after = future.popLast() else { return }
        past.append(marks)
        marks = after
    }
}

/// 保留原生输入法和候选窗。正在组字的按键全部交由 NSTextView 处理。
final class AnnotationTextInput: NSTextView {
    var finish: ((Bool) -> Void)?
    private var wasComposing = false
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }

    override func keyDown(with event: NSEvent) {
        wasComposing = hasMarkedText()
        defer { wasComposing = false }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if !wasComposing && !hasMarkedText() {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): finish?(true); return
            case #selector(NSResponder.cancelOperation(_:)): finish?(false); return
            default: break
            }
        }
        super.doCommand(by: selector)
    }
}
