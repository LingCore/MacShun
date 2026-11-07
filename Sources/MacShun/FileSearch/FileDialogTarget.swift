// SPDX-License-Identifier: MIT

import AppKit

/// 搜索面板取得键盘焦点前，记住发起搜索的原生文件面板。
@MainActor
struct FileDialogTarget {
    private let owner: NSRunningApplication
    private let application: AXUIElement
    private let panel: AXUIElement

    static func focused() -> Self? {
        guard AXIsProcessTrusted(), let owner = NSWorkspace.shared.frontmostApplication, owner != .current else { return nil }
        let application = AXUIElementCreateApplication(owner.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.12)
        guard let panel: AXUIElement = application.value(kAXFocusedWindowAttribute),
              let id = panel.string(kAXIdentifierAttribute), id == "open-panel" || id == "save-panel" else { return nil }
        return Self(owner: owner, application: application, panel: panel)
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
        return application.value(kAXFocusedWindowAttribute)
    }

    /// 文件面板由 AppKit 的独立服务接收键盘输入。沿当前面板的分隔条找它，不能按进程名选第一个。
    private var panelService: pid_t? {
        let groups: [AXUIElement] = panel.value(kAXChildrenAttribute) ?? []
        for group in groups where group.string(kAXRoleAttribute) == kAXSplitGroupRole {
            let children: [AXUIElement] = group.value(kAXChildrenAttribute) ?? []
            for splitter in children where splitter.string(kAXRoleAttribute) == kAXSplitterRole {
                var pid: pid_t = 0
                if AXUIElementGetPid(splitter, &pid) == .success, pid > 0, pid != owner.processIdentifier { return pid }
            }
        }
        return nil
    }

    private func isPathSheet(_ sheet: AXUIElement) -> Bool {
        guard sheet.string(kAXIdentifierAttribute) == "GoToWindow",
              let parent: AXUIElement = sheet.value(kAXParentAttribute) else { return false }
        return CFEqual(parent, panel)
    }

    /// 只认系统明确列出的目标目录；输入后系统异步补全，过早回车可能会选中上次的位置。
    private func exactRow(in sheet: AXUIElement, for folder: URL) -> AXUIElement? {
        let children: [AXUIElement] = sheet.value(kAXChildrenAttribute) ?? []
        guard let scroll = children.first(where: { $0.string(kAXRoleAttribute) == kAXScrollAreaRole }),
              let table = (scroll.value(kAXChildrenAttribute) as [AXUIElement]?)?.first(where: { $0.string(kAXRoleAttribute) == kAXTableRole }),
              let rows: [AXUIElement] = table.value(kAXRowsAttribute) else { return nil }
        for row in rows.prefix(20) {
            let cells: [AXUIElement] = row.value(kAXChildrenAttribute) ?? []
            for cell in cells {
                let items: [AXUIElement] = cell.value(kAXChildrenAttribute) ?? []
                if items.contains(where: { item in
                    guard let id = item.string(kAXIdentifierAttribute), id.hasPrefix("/") else { return false }
                    return URL(fileURLWithPath: id).standardizedFileURL.path == folder.path
                }) { return row }
            }
        }
        return nil
    }

    enum Navigation { case submitted, readyForConfirmation, interrupted }

    func navigate(to folder: URL) async -> Navigation {
        let service = panelService
        guard let window = focusedWindow, CFEqual(window, panel) else { return .interrupted }
        let receiver = service ?? owner.processIdentifier
        send(KeyStroke(KeyCode.g, [.maskCommand, .maskShift]), to: receiver)
        guard let (sheet, field) = await waitForPathField(),
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, folder.path as CFString) == .success else {
            return .interrupted
        }
        // 部分系统版本只提供路径输入框，此时让人在原生面板确认。
        guard let service else { return .readyForConfirmation }
        let deadline = ContinuousClock.now + .seconds(2)
        let destination = folder.standardizedFileURL
        repeat {
            try? await Task.sleep(for: .milliseconds(35))
            guard let window = focusedWindow, CFEqual(window, sheet),
                  let focus: AXUIElement = application.value(kAXFocusedUIElementAttribute), CFEqual(field, focus),
                  field.string(kAXValueAttribute) == folder.path else { return .interrupted }
            if let row = exactRow(in: sheet, for: destination), row.value(kAXSelectedAttribute) == true {
                guard let window = focusedWindow, CFEqual(window, sheet) else { return .interrupted }
                send(KeyStroke(KeyCode.returnKey), to: service)
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
                    if let field: AXUIElement = application.value(kAXFocusedUIElementAttribute),
                       field.string(kAXIdentifierAttribute) == "PathTextField",
                       (window.value(kAXChildrenAttribute) as [AXUIElement]? ?? []).contains(where: { CFEqual($0, field) }) {
                        return (window, field)
                    }
                } else if !CFEqual(window, panel) { return nil }
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
