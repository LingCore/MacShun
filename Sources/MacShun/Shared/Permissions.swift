// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices

/// 系统权限：
/// - 辅助功能：改写按键、模拟粘贴、查询光标位置
/// - 输入监控：识别是哪个鼠标在滚动
/// - 读取剪贴板：见 PasteboardAccess
/// - 完全磁盘访问（可选）：改系统设置里的指针大小
enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var allGranted: Bool { accessibility && inputMonitoring }

    /// 完全磁盘访问权限。问 TCC 的未公开接口 TCCAccessPreflight：0 是已授权，1 是没授权，2 是还没问过。
    /// 找不到这个接口时退回老办法：能打开用户的 TCC.db 就是有权限（macOS 27 上这个文件已经没有了）。
    static var fullDiskAccess: Bool {
        if let preflight = tccAccessPreflight {
            return preflight("kTCCServiceSystemPolicyAllFiles" as CFString, nil) == 0
        }
        let fd = Darwin.open(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    private typealias TCCAccessPreflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let tccAccessPreflight: TCCAccessPreflight? = {
        let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)
        return dlsym(handle, "TCCAccessPreflight").map { unsafeBitCast($0, to: TCCAccessPreflight.self) }
    }()

    /// 弹出系统的授权提示，同时把本程序加进“辅助功能”列表。
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 把本程序加进“输入监控”列表，系统会弹出提示。
    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func openPasteboardSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    fileprivate static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 读取剪贴板的权限。
///
/// 从 macOS 15.4 起系统可以限制程序自动读取剪贴板：第一次读取时弹出询问，之后用户在
/// “系统设置 → 隐私与安全性 → 粘贴”里为每个程序选择“询问 / 始终允许 / 始终拒绝”。
/// 剪贴板历史要在后台记录每次复制，必须是“始终允许”，否则每次复制都会弹窗。
enum PasteboardAccess {
    enum Status: Equatable {
        case allowed
        /// 还没设置成“始终允许”
        case needsSetup
        case denied
    }

    private static let requestedKey = "pasteboardAccessRequested"

    static var status: Status {
        guard #available(macOS 15.4, *) else { return .allowed }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow:
            return .allowed
        case .alwaysDeny:
            return .denied
        case .ask:
            return .needsSetup
        case .default:
            // 从没弹过询问。旧系统上读取不会弹窗；新系统上要等用户点过“去授权”，避免一启动就弹窗。
            // 点过之后还是 default，说明这个系统读取时不会询问，可以直接读。
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 { return .allowed }
            return UserDefaults.standard.bool(forKey: requestedKey) ? .allowed : .needsSetup
        @unknown default:
            return .allowed
        }
    }

    /// 读一次剪贴板，让系统弹出询问并把本程序列进“系统设置”，再打开那一页。
    static func request() {
        UserDefaults.standard.set(true, forKey: requestedKey)
        _ = NSPasteboard.general.string(forType: .string)
        Permissions.openPasteboardSettings()
    }
}
