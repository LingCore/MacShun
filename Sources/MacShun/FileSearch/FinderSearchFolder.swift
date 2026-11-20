// SPDX-License-Identifier: MIT

import AppKit

struct FinderSearchFolder {
    let path: String?
    let title: String

    /// 只在从访达呼出时取一次位置。无需额外授权，虚拟位置和没有窗口时照常全局搜索。
    @MainActor
    static func current() -> Self? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == AppCatalog.finder,
              AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.05)
        guard window.string(kAXIdentifierAttribute) == "FinderWindow",
              let title = window.string(kAXTitleAttribute), !title.isEmpty else { return nil }
        if let document = window.string(kAXDocumentAttribute), let url = URL(string: document), url.isFileURL,
           let path = (url as NSURL).filePathURL?.standardizedFileURL.path {
            return Self(path: path, title: title)
        }
        let windowOnly = Self(path: nil, title: title)
        guard let view = app.axElement(kAXFocusedUIElementAttribute) else { return windowOnly }
        AXUIElementSetMessagingTimeout(view, 0.03)
        let identifier = view.string(kAXIdentifierAttribute)
        let column = identifier == nil && view.string(kAXRoleAttribute) == kAXListRole
        guard ["ListView", "IconView", "GalleryView"].contains(identifier ?? "") || column else { return windowOnly }

        // 按个数取子项，不能把一个几万行的访达列表跨进程复制过来。
        let deadline = ContinuousClock.now + .milliseconds(40)
        func folder(in element: AXUIElement, depth: Int) -> String? {
            guard ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.025)
            if let reference: URL = element.value(kAXURLAttribute), reference.isFileURL,
               let item = (reference as NSURL).filePathURL {
                let parent = item.deletingLastPathComponent()
                if parent.lastPathComponent == title { return parent.standardizedFileURL.path }
                if column && item.hasDirectoryPath && item.lastPathComponent == title { return item.standardizedFileURL.path }
            }
            var children: CFArray?
            guard depth < 4, AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString,
                                                            0, 3, &children) == .success else { return nil }
            for child in children as? [AXUIElement] ?? [] {
                if let path = folder(in: child, depth: depth + 1) { return path }
            }
            return nil
        }
        return Self(path: folder(in: view, depth: 0), title: title)
    }
}
