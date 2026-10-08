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
    /// “系统设置 → 辅助功能 → 显示 → 指针大小”，光标大小没单独调过时用它。
    @Published var systemCursorScale = 1.0
    /// 设置里列出的键盘：这次运行中打过字的，或者以前用过的。
    @Published var keyboards: [InputDevice] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var pasteboardAccess = PasteboardAccess.status
    /// 可选：有了它才能改系统设置里的指针大小。在系统设置里开关它，要重启 Mac顺 才生效，
    /// 所以只在启动时查一次，和 Mac顺 实际能不能用它一致
    let fullDiskAccessGranted = Permissions.fullDiskAccess

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

    /// 重启后要打开设置窗口时带的参数
    static let showSettingsArgument = "--show-settings"

    /// 重新启动本程序。有时授予“输入监控”权限后要重启才生效；更新装好后也用它打开新版本。
    static func relaunch(showSettings: Bool = false) {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let args = showSettings ? " --args \(showSettingsArgument)" : ""
        // 等这个进程真的退出了（最多 10 秒）再打开：还没退出时 open 只会把旧的切到前台
        let wait = "i=0; while /bin/kill -0 $1 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done"
        task.arguments = ["-c", "\(wait); /usr/bin/open \"$0\"\(args)", path, "\(getpid())"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
