// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

/// Paste back into the window that was active when history opened.
@MainActor
struct ClipboardPasteTarget {
    let pid: pid_t
    let isLocal: Bool
    private let localWindow: Int?
    private let application: AXUIElement?
    private let window: AXUIElement?
    private let input: AXUIElement?

    /// 已通过当前前台应用查到的文本焦点元素，供 CaretLocator 复用，避免呼出剪贴板面板时重复 AX IPC。
    var focusedTextElement: AXUIElement? { input }

    init(pid: pid_t) {
        self.pid = pid
        if pid == ProcessInfo.processInfo.processIdentifier {
            isLocal = true
            localWindow = NSApp.keyWindow?.windowNumber
            application = nil
            window = nil
            input = nil
        } else if Permissions.accessibility {
            isLocal = false
            localWindow = nil
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            application = app
            window = app.axElement(kAXFocusedWindowAttribute)
            let focused = app.axElement(kAXFocusedUIElementAttribute)
            if let focused { AXUIElementSetMessagingTimeout(focused, 0.08) }
            input = focused.flatMap { FocusInspector.focusKind(of: $0) == .text ? $0 : nil }
        } else {
            isLocal = false
            localWindow = nil
            application = nil
            window = nil
            input = nil
        }
    }

    var isCurrent: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if isLocal {
            guard let localWindow else { return false }
            return NSApp.keyWindow?.windowNumber == localWindow
        }
        guard let application else { return true }
        return Self.stillFocused(window, in: application, attribute: kAXFocusedWindowAttribute)
            && Self.stillFocused(input, in: application, attribute: kAXFocusedUIElementAttribute)
    }

    private static func stillFocused(_ original: AXUIElement?, in app: AXUIElement, attribute: String) -> Bool {
        guard let original else { return true }
        guard let current = app.axElement(attribute) else { return false }
        return CFEqual(original, current)
    }
}
