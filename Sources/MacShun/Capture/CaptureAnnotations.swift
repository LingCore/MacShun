// SPDX-License-Identifier: MIT

import AppKit

/// 标注和闭合的锚点选区共享操作顺序，历史不复制底图。
struct CaptureAnnotations {
    private enum Edit {
        case marks([CaptureMark])
        case polygon(before: CapturePolygon, after: CapturePolygon)
    }

    private(set) var marks: [CaptureMark]
    private var past: [Edit] = []
    private var future: [Edit] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var nextNumber: Int {
        let highest = marks.lazy.filter { $0.kind == .number }.map(\.number).max() ?? 0
        return highest == Int.max ? highest : highest + 1
    }

    init(_ marks: [CaptureMark] = []) { self.marks = marks }

    mutating func change(_ edit: (inout [CaptureMark]) -> Void) {
        let before = marks
        edit(&marks)
        guard before != marks else { return }
        record(.marks(before))
    }

    mutating func removeMark(at index: Int) {
        change { marks in
            let removed = marks.remove(at: index)
            guard removed.kind == .number,
                  !marks.contains(where: { $0.kind == .number && $0.number == removed.number }) else { return }
            for i in marks.indices where marks[i].kind == .number && marks[i].number > removed.number {
                marks[i].number -= 1
            }
        }
    }

    mutating func recordPolygonChange(from before: CapturePolygon, to after: CapturePolygon) {
        guard before != after else { return }
        record(.polygon(before: before, after: after))
    }

    private mutating func record(_ edit: Edit) {
        past.append(edit)
        if past.count > 100 { past.removeFirst() }
        future.removeAll()
    }

    mutating func undo() -> CapturePolygon? {
        guard let edit = past.popLast() else { return nil }
        switch edit {
        case .marks(let before):
            future.append(.marks(marks))
            marks = before
            return nil
        case .polygon(let before, _):
            future.append(edit)
            return before
        }
    }

    mutating func redo() -> CapturePolygon? {
        guard let edit = future.popLast() else { return nil }
        switch edit {
        case .marks(let after):
            past.append(.marks(marks))
            marks = after
            return nil
        case .polygon(_, let after):
            past.append(edit)
            return after
        }
    }
}

/// 保留原生输入法和候选窗。正在组字的按键全部交由 NSTextView 处理。
final class AnnotationTextInput: NSTextView {
    var finish: ((Bool) -> Void)?
    var allowsManualLineBreak = false
    private var wasComposing = false
    private let typingUndo = UndoManager()
    override var undoManager: UndoManager? { typingUndo }

    override func keyDown(with event: NSEvent) {
        wasComposing = hasMarkedText()
        defer { wasComposing = false }
        if allowsManualLineBreak, !wasComposing,
           event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift {
            insertNewline(nil)
            return
        }
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
