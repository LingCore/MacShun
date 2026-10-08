// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

/// 取 AX 窗口对应的窗口编号（系统私有函数，Rectangle 等窗口管理工具都在用）。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 能分屏的窗口：别的程序的窗口用辅助功能接口（WindowElement），本程序自己的窗口直接用 NSWindow（OwnWindow）。
/// 坐标都是 AX 坐标。
protocol SnappableWindow {
    var windowID: CGWindowID? { get }
    var frame: CGRect? { get }
    var isResizable: Bool { get }
    var isFullScreen: Bool { get }
    /// 改大小和位置，返回改完以后实际的大小和位置。resize 为 false 时只挪位置
    @discardableResult func setFrame(_ frame: CGRect, resize: Bool) -> CGRect?
    func minimize()
    func focus()
}

extension SnappableWindow {
    @discardableResult func setFrame(_ frame: CGRect) -> CGRect? { setFrame(frame, resize: true) }
}

/// 本程序自己的窗口（例如设置窗口）。对自己的程序调用辅助功能接口要等主线程回应，而调用方就在主线程上，会卡到超时。
struct OwnWindow: SnappableWindow {
    let window: NSWindow

    var windowID: CGWindowID? { CGWindowID(window.windowNumber) }
    var frame: CGRect? { ScreenGeometry.appKitRect(window.frame) }
    var isResizable: Bool { window.styleMask.contains(.resizable) }
    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    func setFrame(_ frame: CGRect, resize: Bool) -> CGRect? {
        var target = ScreenGeometry.appKitRect(frame)
        if !resize { target.size = window.frame.size }
        window.setFrame(target, display: true)
        return self.frame
    }

    func minimize() { window.miniaturize(nil) }

    func focus() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// 别的程序的一个窗口，通过辅助功能接口读写位置和大小。只在主线程上用。
///
/// 处理过的几个坑（参考了 Rectangle，MIT 许可）：
/// - 先设大小再设位置、最后再设一次大小：窗口移到另一块屏幕时，系统会按原来那块屏幕限制大小；
/// - 程序开着 AXEnhancedUserInterface（有的辅助工具会打开）时，改窗口大小会很卡还有动画，改之前临时关掉；
/// - 程序没响应时 AX 调用默认要等 6 秒，这里只等 0.5 秒，免得卡住界面。
struct WindowElement: SnappableWindow {
    let element: AXUIElement
    let pid: pid_t

    private static let timeout: Float = 0.5

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
        AXUIElementSetMessagingTimeout(element, Self.timeout)
    }

    /// 最前面程序的当前窗口
    static func focused() -> WindowElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        guard let window: AXUIElement = appElement.value(kAXFocusedWindowAttribute) else { return nil }
        return WindowElement(element: window, pid: app.processIdentifier)
    }

    /// 某个位置下面的窗口
    static func under(_ point: CGPoint) -> WindowElement? {
        // 不给系统级元素设超时：那会改掉整个程序的默认超时，键盘那边查焦点要靠更短的超时
        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        // 点到的是按钮、文字这些，往上找到窗口
        for _ in 0 ..< 30 {
            if current.string(kAXRoleAttribute) == kAXWindowRole as String { break }
            if let window: AXUIElement = current.value(kAXWindowAttribute) {
                current = window
                break
            }
            guard let parent: AXUIElement = current.value(kAXParentAttribute) else { return nil }
            current = parent
        }
        guard current.string(kAXRoleAttribute) == kAXWindowRole as String else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(current, &pid)
        return WindowElement(element: current, pid: pid)
    }

    /// 某个程序的所有窗口
    static func windows(of pid: pid_t) -> [WindowElement] {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        let list: [AXUIElement] = appElement.value(kAXWindowsAttribute) ?? []
        return list.map { WindowElement(element: $0, pid: pid) }
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    var frame: CGRect? {
        guard let position: CGPoint = element.axValue(kAXPositionAttribute, type: .cgPoint),
              let size: CGSize = element.axValue(kAXSizeAttribute, type: .cgSize) else { return nil }
        return CGRect(origin: position, size: size)
    }

    var title: String? { element.string(kAXTitleAttribute) }

    /// 普通的文稿窗口（不是对话框、浮动面板、表单）
    var isStandard: Bool {
        element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole as String
    }

    var isResizable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    var isMovable: Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
    }

    var isFullScreen: Bool {
        let value: Bool? = element.value("AXFullScreen")
        return value == true
    }

    var isMinimized: Bool {
        let value: Bool? = element.value(kAXMinimizedAttribute)
        return value == true
    }

    /// 改大小和位置。返回改完以后实际的大小和位置（有的窗口有最小尺寸，或者按字符调整）。
    @discardableResult
    func setFrame(_ frame: CGRect, resize: Bool) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.timeout)
        let enhanced: Bool? = appElement.value("AXEnhancedUserInterface")
        if enhanced == true { AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced == true { AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        if resize { setSize(frame.size) }
        setPosition(frame.origin)
        if resize { setSize(frame.size) }
        return self.frame
    }

    func minimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// 放到最前面并让它的程序成为当前程序
    func focus() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private func setSize(_ size: CGSize) {
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
        }
    }

    private func setPosition(_ point: CGPoint) {
        var value = point
        if let axValue = AXValueCreate(.cgPoint, &value) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
        }
    }
}

extension AXUIElement {
    func value<T>(_ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func string(_ attribute: String) -> String? { value(attribute) }

    func axValue<T>(_ attribute: String, type: AXValueType) -> T? {
        guard let raw: CFTypeRef = value(attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        return AXValueGetValue(axValue, type, pointer) ? pointer.pointee : nil
    }
}

/// 屏幕的位置换成 AX 坐标，排好顺序。
enum ScreenGeometry {
    struct Screen {
        /// 整块屏幕（含菜单栏）
        let frame: CGRect
        /// 去掉菜单栏和程序坞的可用区域
        let area: CGRect
    }

    /// 所有屏幕，从左到右（左右一样时从上到下）
    static func screens() -> [Screen] {
        guard let primary = NSScreen.screens.first else { return [] }
        let height = primary.frame.maxY
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens
            .map { Screen(frame: flip($0.frame), area: flip($0.visibleFrame)) }
            .sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
    }

    /// AX 坐标换成 AppKit 坐标（原点在主屏幕左下角，y 向上），用来摆放本程序的窗口
    static func appKitRect(_ rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func axPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    /// 窗口在哪块屏幕上：和哪块重叠最多
    static func index(of frame: CGRect, in screens: [Screen]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = screen.frame.intersection(frame)
            let size = overlap.isNull ? 0 : overlap.width * overlap.height
            if size > (best?.area ?? 0) { best = (index, size) }
        }
        return best?.index ?? screens.indices.first { screens[$0].frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }
}
