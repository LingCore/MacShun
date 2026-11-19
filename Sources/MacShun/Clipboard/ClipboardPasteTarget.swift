// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

/// Paste back into the window that was active when history opened.
@MainActor
struct ClipboardPasteTarget {
    let pid: pid_t
    private let localWindow: Int?
    private let application: AXUIElement?
    private let window: AXUIElement?
    private let input: AXUIElement?

    init(pid: pid_t) {
        self.pid = pid
        if pid == ProcessInfo.processInfo.processIdentifier {
            localWindow = NSApp.keyWindow?.windowNumber
            application = nil
            window = nil
            input = nil
        } else if Permissions.accessibility {
            localWindow = nil
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            application = app
            window = app.value(kAXFocusedWindowAttribute)
            let focused: AXUIElement? = app.value(kAXFocusedUIElementAttribute)
            input = focused.flatMap { FocusInspector.focusKind(of: $0) == .text ? $0 : nil }
        } else {
            localWindow = nil
            application = nil
            window = nil
            input = nil
        }
    }

    var isCurrent: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let localWindow { return NSApp.keyWindow?.windowNumber == localWindow }
        guard let application else { return true }
        return Self.stillFocused(window, in: application, attribute: kAXFocusedWindowAttribute)
            && Self.stillFocused(input, in: application, attribute: kAXFocusedUIElementAttribute)
    }

    private static func stillFocused(_ original: AXUIElement?, in app: AXUIElement, attribute: String) -> Bool {
        guard let original else { return true }
        guard let current: AXUIElement = app.value(attribute) else { return false }
        return CFEqual(original, current)
    }
}
