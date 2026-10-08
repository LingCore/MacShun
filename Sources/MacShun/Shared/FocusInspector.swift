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
    private let systemWide = AXUIElementCreateSystemWide()

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    private static let browsingRoles: Set<String> = [
        "AXOutline", "AXList", "AXTable", "AXBrowser", "AXScrollArea",
        "AXGroup", "AXRow", "AXCell", "AXWebArea", "AXLayoutArea",
    ]

    init() {
        // 对系统级元素设置超时，会成为所有元素的默认超时。应用卡住时最多等这么久。
        AXUIElementSetMessagingTimeout(systemWide, 0.15)
    }

    func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    func focusKind() -> FocusKind {
        guard let element = focusedElement() else { return .unknown }
        guard let role = Self.string(element, kAXRoleAttribute) else { return .unknown }
        if Self.textRoles.contains(role) { return .text }
        if Self.isEditable(element) { return .text }
        if Self.browsingRoles.contains(role) { return .browsing }
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
