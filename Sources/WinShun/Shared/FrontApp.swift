// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon

/// 记录当前在前台的应用、是否开着微信或 QQ、当前输入法。
/// 在主线程上更新，事件拦截线程随时可以读。
final class FrontAppTracker {
    static let shared = FrontAppTracker()

    let current = Locked(AppIdentity())
    /// 微信或 QQ 是否在运行（决定 Alt+A 是否换成它们的截图快捷键）。
    let chatAppRunning = Locked(false)
    /// 当前输入源的标识，例如 com.sogou.inputmethod.sogou.pinyin。
    let inputSourceID = Locked<String?>(nil)
    /// 本程序的剪贴板面板是否正在接收键盘输入。面板不会把本程序切到前台，所以要单独记。
    let clipboardPanelActive = Locked(false)
    /// 本程序的文件搜索框是否正在接收键盘输入，同上。
    let fileSearchPanelActive = Locked(false)

    private var observers: [NSObjectProtocol] = []

    func start() {
        update(NSWorkspace.shared.frontmostApplication)
        updateRunningApps()
        updateInputSource()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.update(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateRunningApps()
            })
        }
        // 输入法切换的通知。输入源接口只能在主线程上调用，所以在这里读好存起来。
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateInputSource()
        })
    }

    private func update(_ app: NSRunningApplication?) {
        current.set(AppIdentity(bundleID: app?.bundleIdentifier, name: app?.localizedName))
    }

    private func updateRunningApps() {
        let running = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map(AppCatalog.chatAppsWithControlCommandAScreenshot.contains) ?? false
        }
        chatAppRunning.set(running)
    }

    private func updateInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else {
            inputSourceID.set(nil)
            return
        }
        let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        inputSourceID.set(id)
    }
}
