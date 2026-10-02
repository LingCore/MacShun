// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices

/// 把本程序的窗口带到最前面。
///
/// macOS 14 起是“协作式激活”：程序只能请求激活，系统觉得不该切时就不切。菜单栏程序从自己的菜单里
/// 打开窗口，常常因此被挡在别的程序的窗口后面。先正常请求；没成功时用辅助功能接口把本程序设为前台
/// （本程序本来就需要辅助功能权限）。
enum Foreground {
    static func bring(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 即使没能激活，窗口也先摆到最上面，不会被挡住。
        window.orderFrontRegardless()
        // 菜单关闭、激活请求生效都要一点时间，稍后再看。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard window.isVisible, !NSApp.isActive else { return }
            let me = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let result = AXUIElementSetAttributeValue(me, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if result != .success { Log.app.error("无法把窗口切到前台：\(result.rawValue)") }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
