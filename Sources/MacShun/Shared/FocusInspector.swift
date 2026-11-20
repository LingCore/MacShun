// SPDX-License-Identifier: MIT

import ApplicationServices

/// 键盘焦点所在控件的大致类别。
enum FocusKind: Equatable {
    /// 可以输入文字的地方：输入框、文本区、可编辑的网页内容
    case text
    /// 文件列表、表格、网页正文这类可以浏览但不能输入的地方
    case browsing
    /// 按钮、复选框等其他控件
    case other
    /// 问不到（应用没有响应辅助功能查询，或者超时）
    case unknown
}

/// 通过辅助功能接口查询键盘焦点。每次查询是一次跨进程调用，只在需要时才查。
final class FocusInspector {
    /// 只初始化一次系统级超时，避免每次构造对象反复改写进程级默认超时。
    private static let sharedSystemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }()
    private let systemWide = FocusInspector.sharedSystemWide
    private static let elementTimeout: Float = 0.08

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// 明确不可直接编辑的列表/表格/树形控件：先于 isEditable 判定，省去 1–2 次跨进程 AX 查询。
    private static let strictBrowsingRoles: Set<String> = [
        "AXOutline", "AXList", "AXTable", "AXBrowser",
    ]

    /// 网页正文、表格单元格或容器可能是 contenteditable / gridcell，需先核对 isEditable。
    private static let containerBrowsingRoles: Set<String> = [
        "AXScrollArea", "AXGroup", "AXWebArea", "AXLayoutArea", "AXRow", "AXCell",
    ]

    init() {}

    func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.elementTimeout)
        return element
    }

    func focusKind() -> FocusKind {
        guard let element = focusedElement() else { return .unknown }
        return Self.focusKind(of: element)
    }

    static func focusKind(of element: AXUIElement) -> FocusKind {
        guard let role = string(element, kAXRoleAttribute) else { return .unknown }
        if textRoles.contains(role) { return .text }
        if strictBrowsingRoles.contains(role) { return .browsing }
        if isEditable(element) { return .text }
        if containerBrowsingRoles.contains(role) { return .browsing }
        return .other
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 网页里的可编辑区域（contenteditable）没有固定的角色，看它的文字选区能不能改。
    private static func isEditable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
        else { return false }
        if !settable.boolValue { return false }
        var valueSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success
        else { return false }
        return valueSettable.boolValue
    }
}
