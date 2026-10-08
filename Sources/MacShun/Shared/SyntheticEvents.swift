// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 一次按键：键码加修饰键。
struct KeyStroke: Equatable, CustomStringConvertible {
    var keyCode: CGKeyCode
    var flags: CGEventFlags

    init(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) {
        self.keyCode = keyCode
        self.flags = flags.intersection(.modifierKeys)
    }

    var description: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + String(format: "0x%02X", keyCode)
    }
}

/// 本程序模拟出来的事件。都带一个标记，事件拦截时看到这个标记就原样放行，避免自己改写自己。
enum Synthetic {
    static let marker: Int64 = 0x5749_4E53  // "WINS"

    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = marker
        return s
    }()

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// 生成一个按键事件。`original` 是被替换掉的原始事件，用来继承“按住重复”等字段。
    static func keyEvent(_ stroke: KeyStroke, down: Bool, original: CGEvent? = nil) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: down) else {
            return nil
        }
        var flags = stroke.flags
        if KeyCode.functionFlagKeys.contains(stroke.keyCode) { flags.insert(.maskSecondaryFn) }
        if KeyCode.arrows.contains(stroke.keyCode) { flags.insert(.maskNumericPad) }
        if let original {
            if original.flags.contains(.maskAlphaShift) { flags.insert(.maskAlphaShift) }
            event.setIntegerValueField(.keyboardEventAutorepeat, value: original.getIntegerValueField(.keyboardEventAutorepeat))
            event.setIntegerValueField(.keyboardEventKeyboardType, value: original.getIntegerValueField(.keyboardEventKeyboardType))
            event.timestamp = original.timestamp
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    /// 修饰键按下或松开的事件（flagsChanged）。
    static func modifierEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: !flags.isEmpty) else {
            return nil
        }
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    /// 在事件拦截回调之外模拟一次完整的按键（按下加松开）。
    static func tap(_ stroke: KeyStroke, at location: CGEventTapLocation = .cgSessionEventTap) {
        keyEvent(stroke, down: true)?.post(tap: location)
        keyEvent(stroke, down: false)?.post(tap: location)
    }

    /// 等用户松开所有修饰键再执行。例如按 Win+D 时，Win 键还按着，马上模拟按键会混进 ⌘。
    static func afterModifiersReleased(timeout: TimeInterval = 1.5, _ action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let held = CGEventSource.flagsState(.hidSystemState).intersection(.modifierKeys)
            if held.isEmpty || Date() >= deadline {
                action()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
            }
        }
        check()
    }
}
