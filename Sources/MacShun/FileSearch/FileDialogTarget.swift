// SPDX-License-Identifier: MIT

import AppKit

/// 搜索面板取得键盘焦点前，记住发起搜索的原生文件面板。
@MainActor
struct FileDialogTarget {
    private let owner: NSRunningApplication
    private let application: AXUIElement
    private let panel: AXUIElement

    private static let axTimeout: Float = 0.15

    private static func timed(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return element
    }

    private static func isDialog(_ element: AXUIElement) -> Bool {
        let id = timed(element).string(kAXIdentifierAttribute)
        return id == "open-panel" || id == "save-panel"
    }

    static func focused() -> Self? {
        guard AXIsProcessTrusted(), let owner = NSWorkspace.shared.frontmostApplication, owner != .current else { return nil }
        let application = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        guard let window = application.axElement(kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, axTimeout)
        if isDialog(window) {
            return Self(owner: owner, application: application, panel: window)
        }
        // 支持文稿窗口附带的表单式（beginSheetModal）打开/存储面板。
        for sheet in window.axElements("AXSheets") where isDialog(sheet) {
            return Self(owner: owner, application: application, panel: sheet)
        }
        for child in window.axElements(kAXChildrenAttribute) where timed(child).string(kAXRoleAttribute) == kAXSheetRole && isDialog(child) {
            return Self(owner: owner, application: application, panel: child)
        }
        return nil
    }

    nonisolated static func folder(for url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return nil }
        let directory = values.isDirectory == true && values.isPackage != true ? url : url.deletingLastPathComponent()
        guard let path = realpath(directory.path, nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private var focusedWindow: AXUIElement? {
        guard owner.isActive, !Task.isCancelled else { return nil }
        return application.axElement(kAXFocusedWindowAttribute).map(Self.timed)
    }

    private func isTargetPanelActive(_ window: AXUIElement) -> Bool {
        if CFEqual(window, panel) { return true }
        if let parent = panel.axElement(kAXParentAttribute), CFEqual(window, parent) { return true }
        return false
    }

    /// 文件面板由 AppKit 的独立服务接收键盘输入。沿当前面板的分隔条找它，不能按进程名选第一个。
    private var panelService: pid_t? {
        let groups = panel.axElements(kAXChildrenAttribute)
        for group in groups where Self.timed(group).string(kAXRoleAttribute) == kAXSplitGroupRole {
            let children = group.axElements(kAXChildrenAttribute)
            for splitter in children where Self.timed(splitter).string(kAXRoleAttribute) == kAXSplitterRole {
                var pid: pid_t = 0
                if AXUIElementGetPid(splitter, &pid) == .success, pid > 0, pid != owner.processIdentifier { return pid }
            }
        }
        return nil
    }

    private func isPathSheet(_ sheet: AXUIElement) -> Bool {
        guard Self.timed(sheet).string(kAXIdentifierAttribute) == "GoToWindow",
              let parent = sheet.axElement(kAXParentAttribute) else { return false }
        return CFEqual(parent, panel) || isTargetPanelActive(parent)
    }

    /// 只认系统明确列出的目标目录；输入后系统异步补全，过早回车可能会选中上次的位置。
    private func exactRow(in sheet: AXUIElement, for folder: URL) -> AXUIElement? {
        let children = Self.timed(sheet).axElements(kAXChildrenAttribute)
        guard let scroll = children.first(where: { Self.timed($0).string(kAXRoleAttribute) == kAXScrollAreaRole }),
              let table = scroll.axElements(kAXChildrenAttribute).first(where: { Self.timed($0).string(kAXRoleAttribute) == kAXTableRole })
        else { return nil }
        let rows = table.axElements(kAXRowsAttribute)
        for row in rows.prefix(20) {
            let cells = Self.timed(row).axElements(kAXChildrenAttribute)
            for cell in cells {
                let items = Self.timed(cell).axElements(kAXChildrenAttribute)
                if items.contains(where: { item in
                    guard let id = Self.timed(item).string(kAXIdentifierAttribute), id.hasPrefix("/") else { return false }
                    return URL(fileURLWithPath: id).standardizedFileURL.path == folder.path
                }) { return row }
            }
        }
        return nil
    }

    enum Navigation { case submitted, readyForConfirmation, interrupted }

    func navigate(to folder: URL) async -> Navigation {
        let service = panelService
        guard let window = focusedWindow, isTargetPanelActive(window) else { return .interrupted }
        let receiver = service ?? owner.processIdentifier
        send(KeyStroke(KeyCode.g, [.maskCommand, .maskShift]), to: receiver)
        guard let (sheet, field) = await waitForPathField(),
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, folder.path as CFString) == .success else {
            return .interrupted
        }
        let deadline = ContinuousClock.now + .seconds(2)
        let destination = folder.standardizedFileURL
        repeat {
            try? await Task.sleep(for: .milliseconds(35))
            guard let window = focusedWindow, CFEqual(window, sheet),
                  let focus = application.axElement(kAXFocusedUIElementAttribute), CFEqual(field, focus),
                  field.string(kAXValueAttribute) == folder.path else { return .interrupted }
            if let row = exactRow(in: sheet, for: destination), row.value(kAXSelectedAttribute) == true {
                guard let window = focusedWindow, CFEqual(window, sheet) else { return .interrupted }
                send(KeyStroke(KeyCode.returnKey), to: receiver)
                return .submitted
            }
        } while ContinuousClock.now < deadline
        return .readyForConfirmation
    }

    private func waitForPathField() async -> (AXUIElement, AXUIElement)? {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            guard owner.isActive, !Task.isCancelled else { return nil }
            if let window = focusedWindow {
                if isPathSheet(window) {
                    if let field = application.axElement(kAXFocusedUIElementAttribute),
                       Self.timed(field).string(kAXIdentifierAttribute) == "PathTextField",
                       window.axElements(kAXChildrenAttribute).contains(where: { CFEqual($0, field) }) {
                        return (window, field)
                    }
                } else if !isTargetPanelActive(window) { return nil }
            }
            // 两个窗口交接焦点时，AXFocusedWindow 会短暂为空。
            try? await Task.sleep(for: .milliseconds(35))
        } while ContinuousClock.now < deadline
        return nil
    }

    private func send(_ stroke: KeyStroke, to pid: pid_t) {
        for down in [true, false] { Synthetic.keyEvent(stroke, down: down)?.postToPid(pid) }
    }
}
