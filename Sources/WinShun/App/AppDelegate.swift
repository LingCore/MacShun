// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore.shared
    private let environment = FrontAppTracker.shared
    private let state = AppState()
    private lazy var clipboard: ClipboardController = {
        // 自测时用临时目录，不碰真正的剪贴板历史。
        guard SelfTest.isRequested else { return ClipboardController(configStore: configStore) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WinShun自测剪贴板-\(UUID().uuidString)")
        return ClipboardController(configStore: configStore, store: ClipboardStore(directory: dir))
    }()
    private let pointer = PointerAccelerationController()
    private let cursor = CursorSizeController()
    private lazy var fileSearch = FileSearchController(configStore: configStore)
    private lazy var windowSnapper = WindowSnapper(configStore: configStore)
    private var knownKeyboards: ([InputDevice], Set<String>) = ([], [])
    private var eventTaps: EventTapService!
    private var statusMenu: StatusMenu!
    private var settingsWindow: SettingsWindowController!

    private var permissionTimer: Timer?
    private var maintenanceTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignal()
        CapsLockLeftovers.restore()
        MainMenu.install()
        environment.start()

        let keyboard = KeyboardEngine(config: configStore.snapshot, environment: environment) { [weak self] command in
            self?.run(command)
        }
        let mouse = MouseEngine(config: configStore.snapshot, frontApp: environment.current)
        keyboard.devices.onDevicesChanged = { [weak self] list, seen in
            self?.knownKeyboards = (list, seen)
            self?.updateKeyboardList()
        }
        keyboard.onLayoutLearned = { [weak self] device, layout in self?.layoutLearned(device, layout) }
        mouse.devices.onDevicesChanged = { [weak self] mice, _ in
            self?.state.mice = mice
            // 新接上的鼠标要过一会儿才能设置。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.applyPointer() }
        }
        eventTaps = EventTapService(keyboard: keyboard, mouse: mouse)

        settingsWindow = SettingsWindowController(configStore: configStore, state: state, clipboard: clipboard)
        statusMenu = StatusMenu(
            configStore: configStore, state: state,
            openSettings: { [weak self] in self?.settingsWindow.show() },
            openClipboard: { [weak self] in self?.clipboard.show() }
        )

        configStore.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.clipboard.applyConfig()
                self?.fileSearch.applyConfig()
                self?.windowSnapper.applyConfig()
                self?.applyPointer()
            }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(forName: .openFileSearch, object: nil, queue: .main) { [weak self] _ in
            self?.clipboard.hide()
            self?.fileSearch.show()
        }

        clipboard.applyConfig()
        windowSnapper.applyConfig()
        startEventTapsIfPossible()

        if GuideTest.isRequested {
            let test = GuideTest { [weak self] in self?.settingsWindow.show(tab: .general) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await test.run(state: self.state)
                NSApp.terminate(nil)
            }
            return
        }

        if SelfTest.isRequested {
            keyboard.learningEnabled.set(false)
            startPermissionPolling()
            windowSnapper.applyConfig()
            let test = SelfTest(config: configStore.config, layout: keyboard.currentLayout(), clipboard: clipboard,
                                windowSnapper: windowSnapper, fileSearch: fileSearch) { [weak self] in
                self?.settingsWindow.show()
            }
            Task { @MainActor in
                // 等事件拦截和鼠标设备都准备好
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await test.run()
                NSApp.terminate(nil)
            }
            return
        }

        let clipboardNeedsSetup = configStore.config.clipboard.enabled && state.pasteboardAccess != .allowed
        if !state.allGood || clipboardNeedsSetup {
            if !state.accessibilityGranted { Permissions.requestAccessibility() }
            if !state.inputMonitoringGranted { Permissions.requestInputMonitoring() }
            settingsWindow.show(tab: .general)
        } else if CommandLine.arguments.contains(AppState.showSettingsArgument) {
            // 授权引导重启 Win顺 之后，回到设置窗口
            settingsWindow.show(tab: .general)
        }
        startPermissionPolling()

        // 系统偶尔会重置鼠标属性，定期检查一下。
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.applyPointer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pointer.restore()
        cursor.restore()
        ContentIndex.shared.prepareForQuit()
        if !SelfTest.isRequested { clipboard.store.saveNow() }
    }

    /// 再次打开程序（例如在“应用程序”里双击）时显示设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    /// 被 kill 等方式结束时也走正常退出流程，把鼠标设置恢复原样。
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    // MARK: - 键盘布局

    private func updateKeyboardList() {
        let (list, seen) = knownKeyboards
        let saved = configStore.config.keyboard.layouts
        state.keyboards = list.filter { seen.contains($0.key) || saved[$0.key] != nil }
    }

    /// 学到了键盘的模式（不打扰用户，只更新设置）。
    private func layoutLearned(_ device: InputDevice?, _ layout: KeyboardLayoutKind) {
        if let device {
            configStore.config.keyboard.layouts[device.key] = layout
        } else {
            configStore.config.keyboard.layout = layout
        }
        updateKeyboardList()
        Log.keyboard.notice("键盘模式：\(device?.name ?? "默认", privacy: .public) → \(layout.rawValue, privacy: .public)")
    }

    private func run(_ command: SystemCommand) {
        if command == .clipboardHistory {
            // 文件搜索框开着时，剪贴板面板叠在它上面，选中的直接填进搜索框
            if clipboard.isVisible {
                clipboard.close()
            } else if fileSearch.isVisible {
                clipboard.show(in: fileSearch.clipboardHost())
            } else {
                clipboard.show()
            }
        } else if command == .fileSearch {
            clipboard.hide()
            fileSearch.summon()
        } else if case .window(let shortcut) = command {
            windowSnapper.handle(shortcut)
        } else {
            SystemActions.run(command)
        }
    }

    private var pointerApplyScheduled = false

    /// 设置指针加速、速度和光标大小。短时间内的多次调用（例如几个鼠标接口同时连上）合并成一次。
    private func applyPointer() {
        // 光标大小不需要权限
        cursor.apply(configStore.config.mouse)
        let cursorScale = cursor.systemScale()
        if cursorScale != state.systemCursorScale { state.systemCursorScale = cursorScale }
        guard state.inputMonitoringGranted || state.accessibilityGranted, !pointerApplyScheduled else { return }
        pointerApplyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.pointerApplyScheduled = false
            self.pointer.apply(self.configStore.config.mouse)
            if let speed = self.pointer.systemSpeed(), speed != self.state.systemPointerSpeed {
                self.state.systemPointerSpeed = speed
            }
        }
    }

    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.applyPointer() }
    }

    // MARK: - 权限

    private func startEventTapsIfPossible() {
        state.refreshPermissions()
        logPermissionsIfChanged()
        guard state.accessibilityGranted else { return }
        let running = eventTaps.start()
        if running != state.eventTapRunning { state.eventTapRunning = running }
        logPermissionsIfChanged()
        applyPointer()
    }

    private var lastLoggedPermissions = ""

    /// 权限状态有变化时记一笔日志，方便排查“授权了但没生效”。
    private func logPermissionsIfChanged() {
        let summary = "辅助功能=\(state.accessibilityGranted) 输入监控=\(state.inputMonitoringGranted) "
            + "读取剪贴板=\(state.pasteboardAccess) 事件拦截=\(state.eventTapRunning)"
        guard summary != lastLoggedPermissions else { return }
        lastLoggedPermissions = summary
        Log.app.notice("权限状态：\(summary, privacy: .public)")
    }

    /// 每秒检查一次权限，授权后马上启用，不用重启程序。
    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = (self.state.accessibilityGranted, self.state.inputMonitoringGranted)
            self.state.refreshPermissions()
            let after = (self.state.accessibilityGranted, self.state.inputMonitoringGranted)
            if before != after || !self.state.eventTapRunning {
                self.startEventTapsIfPossible()
            }
            // macOS 27：刚开了“设备控制和数据访问”（不管是在引导里还是在系统弹窗里开的），
            // 输入监控要重启才生效，直接重启，不用用户再点
            if PermissionKind.accessibilityCoversInputMonitoring, !before.0, after.0, !after.1, !GuideTest.isRequested {
                PermissionGuide.shared.start([.inputMonitoring], state: self.state)
            }
            self.logPermissionsIfChanged()
        }
    }
}
