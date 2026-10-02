// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement

/// 设置界面要显示的运行状态。只在主线程上修改。
final class AppState: ObservableObject {
    @Published var accessibilityGranted = Permissions.accessibility
    @Published var inputMonitoringGranted = Permissions.inputMonitoring
    @Published var eventTapRunning = false
    @Published var mice: [MouseDevice] = []
    /// “系统设置 → 鼠标 → 跟踪速度”，指针速度没有单独调过时用它。
    @Published var systemPointerSpeed = 1.0
    /// 设置里列出的键盘：这次运行中打过字的，或者以前用过的。
    @Published var keyboards: [InputDevice] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var pasteboardAccess = PasteboardAccess.status

    var allGood: Bool { accessibilityGranted && inputMonitoringGranted && eventTapRunning }

    func refreshPermissions() {
        let ax = Permissions.accessibility
        let im = Permissions.inputMonitoring
        if ax != accessibilityGranted { accessibilityGranted = ax }
        if im != inputMonitoringGranted { inputMonitoringGranted = im }
        let pb = PasteboardAccess.status
        if pb != pasteboardAccess { pasteboardAccess = pb }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("设置开机自启失败：\(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 重新启动本程序。有时授予“输入监控”权限后要重启才生效。
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
