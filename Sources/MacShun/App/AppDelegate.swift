// SPDX-License-Identifier: MIT

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore.shared
    private let environment = FrontAppTracker.shared
    private let state = AppState()
    @MainActor private lazy var clipboard: ClipboardController = {
        // 自测时用临时目录，不碰真正的剪贴板历史。
        guard SelfTest.isRequested else { return ClipboardController(configStore: configStore) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacShun自测剪贴板-\(UUID().uuidString)")
        return ClipboardController(configStore: configStore, store: ClipboardStore(directory: dir))
    }()
    private let pointer = PointerAccelerationController()
    private let cursor = CursorSizeController.shared
    @MainActor private lazy var fileSearch = FileSearchController(configStore: configStore)
    @MainActor private lazy var screenCapture = ScreenCaptureController()
    private lazy var windowSnapper = WindowSnapper(configStore: configStore)
    private var knownKeyboards: ([InputDevice], Set<String>) = ([], [])
    private var eventTaps: EventTapService!
    private var statusMenu: StatusMenu!
    private var settingsWindow: SettingsWindowController!

    private var permissionTimer: Timer?
    private var permissionTimerInterval: TimeInterval = 0
    private var maintenanceTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var terminationSignal: DispatchSourceSignal?
    private var asleep = false
    private var screenAsleep = false
    private var sessionInactive = false
    private var pollingEnabled = false
    private var maintenanceEnabled = false
    private var timersPaused: Bool { asleep || screenAsleep || sessionInactive }

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignal()
        CapsLockLeftovers.restore()
        MainMenu.install()
        environment.onApplicationWillSwitch = { [weak self] previous in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.configStore.config.clipboard.enabled {
                    self.clipboard.recordBeforeAppSwitch(from: previous)
                }
                CaptureClipboard.general.refreshIfNeeded()
            }
        }
        environment.start()

        let keyboard = KeyboardEngine(config: configStore.snapshot, environment: environment) { [weak self] command in
            self?.run(command)
        }
        let mouse = MouseEngine(
            config: configStore.snapshot,
            environment: environment,
            keyboardLayout: { keyboard.currentLayout() }
        ) { [weak self] command in
            self?.run(command)
        }
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
        eventTaps.onStateChanged = { [weak self] running in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.state.eventTapRunning != running {
                    self.state.eventTapRunning = running
                    self.logPermissionsIfChanged()
                    self.schedulePermissionTimer()
                }
            }
        }

        settingsWindow = SettingsWindowController(configStore: configStore, state: state, clipboard: clipboard)
        statusMenu = StatusMenu(
            configStore: configStore, state: state, clipboard: clipboard,
            openSettings: { [weak self] in
                self?.refreshPermissionsNow()
                self?.settingsWindow.show()
            },
            openPerformance: { [weak self] in
                self?.refreshPermissionsNow()
                self?.settingsWindow.show(tab: .performance)
            },
            openClipboard: { [weak self] in self?.showClipboard() },
            capture: { [weak self] mode in self?.screenCapture.start(mode) }
        )

        // 发现新版本时弹出“软件更新”窗口。自动检查发现的不抢键盘
        Updater.shared.onFound = { _, manual in UpdateWindowController.shared.showNewVersion(activate: manual) }
        PermissionGuide.shared.onActiveChanged = { [weak self] in self?.schedulePermissionTimer() }

        configStore.$config
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in
                self?.applyConfig(config)
            }
            .store(in: &subscriptions)

        installLifecycleObservers()
        appObservers.append(NotificationCenter.default.addObserver(forName: .openFileSearch, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clipboard.hide()
                self?.fileSearch.show()
            }
        })

        applyConfig(configStore.config, includePointer: false)
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
            let test = SelfTest(config: configStore.config, layout: keyboard.currentLayout(), clipboard: clipboard,
                                windowSnapper: windowSnapper, fileSearch: fileSearch,
                                updateConfig: { [weak self] change in self.map { change(&$0.configStore.config) } }) { [weak self] tab in
                self?.settingsWindow.show(tab: tab)
            }
            Task { @MainActor in
                // 等事件拦截和鼠标设备都准备好
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await test.run()
                NSApp.terminate(nil)
            }
            return
        }

        // 匿名装机报告（自测和授权引导测试已经在上面返回了）
        InstallReport.start()

        let clipboardNeedsSetup = configStore.config.clipboard.enabled && state.pasteboardAccess != .allowed
        if !state.allGood || clipboardNeedsSetup {
            if !state.accessibilityGranted { Permissions.requestAccessibility() }
            if !state.inputMonitoringGranted { Permissions.requestInputMonitoring() }
            settingsWindow.show(tab: .general)
        } else if CommandLine.arguments.contains(AppState.showSettingsArgument) {
            // 授权引导重启 Mac顺 之后，回到设置窗口
            settingsWindow.show(tab: .general)
        }
        startPermissionPolling()

        // 系统偶尔会重置鼠标属性，定期检查一下。
        maintenanceEnabled = true
        scheduleMaintenanceTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers.removeAll()
        eventTaps?.stop()
        PerformanceMonitor.shared.stop()
        pointer.restore()
        cursor.restore()
        ContentIndex.shared.prepareForQuit()
        ContentExtractor.terminateAllHelpers()
        if !SelfTest.isRequested { clipboard.store.saveNow() }
    }

    /// 再次打开程序（例如在“应用程序”里双击）时显示设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshPermissionsNow()
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

    /// 打开剪贴板历史（Win+V、菜单栏）。文件搜索框开着时叠在它上面，选中的直接填进搜索框
    @MainActor private func showClipboard() {
        if fileSearch.isVisible {
            clipboard.show(in: fileSearch.clipboardHost())
        } else {
            clipboard.show()
        }
    }

    /// 键盘、鼠标引擎都先切回主线程再调用这里
    @MainActor private func run(_ command: SystemCommand) {
        if command == .clipboardHistory {
            if clipboard.isVisible { clipboard.close() } else { showClipboard() }
        } else if command == .fileSearch {
            clipboard.hide()
            fileSearch.summon()
        } else if command == .finishScrollingCapture {
            screenCapture.finishScrolling()
        } else if command == .cancelScrollingCapture {
            screenCapture.cancelScrolling()
        } else if case .capture(let mode) = command {
            screenCapture.start(mode)
        } else if case .window(let shortcut) = command {
            windowSnapper.handle(shortcut)
        } else {
            SystemActions.run(command)
        }
    }

    @MainActor private func applyConfig(_ config: AppConfig, includePointer: Bool = true) {
        clipboard.applyConfig()
        fileSearch.applyConfig()
        windowSnapper.applyConfig()
        if includePointer { applyPointer() }
        Updater.shared.setAutomatic(config.update.automatic)
        schedulePermissionTimer()
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.updateBackgroundTimers()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.asleep = false
            self.updateBackgroundTimers()
            self.eventTaps?.verifyActive()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.applyPointer() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenAsleep = true
            self?.updateBackgroundTimers()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.screenAsleep = false
            self.updateBackgroundTimers()
            self.eventTaps?.verifyActive()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionInactive = true
            self?.updateBackgroundTimers()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionInactive = false
            self.updateBackgroundTimers()
            self.eventTaps?.verifyActive()
        })
    }

    private func updateBackgroundTimers() {
        if timersPaused {
            permissionTimer?.invalidate()
            permissionTimer = nil
            permissionTimerInterval = 0
            maintenanceTimer?.invalidate()
            maintenanceTimer = nil
        } else {
            if pollingEnabled {
                pollPermissions()
                schedulePermissionTimer()
            }
            if maintenanceEnabled {
                scheduleMaintenanceTimer()
            }
        }
    }

    private func scheduleMaintenanceTimer() {
        guard maintenanceEnabled, !timersPaused else { return }
        guard maintenanceTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.applyPointer()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .default)
        maintenanceTimer = timer
    }

    private var pointerApplyScheduled = false

    /// 设置指针加速、速度和光标大小。短时间内的多次调用（例如几个鼠标接口同时连上）合并成一次。
    private func applyPointer() {
        // 光标大小不需要权限。以前的版本把光标大小存在 Mac顺 自己的设置里，能写进系统设置就搬过去
        if let scale = configStore.config.mouse.cursorScale, !cursor.writeDenied, cursor.setSystemScale(scale) {
            configStore.config.mouse.cursorScale = nil
        }
        let cursorScale = cursor.systemScale()
        cursor.apply(configStore.config.mouse, systemScale: cursorScale)
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

    // MARK: - 权限

    private func startEventTapsIfPossible() {
        state.refreshPermissions()
        logPermissionsIfChanged()
        if state.accessibilityGranted {
            let running = eventTaps.start()
            if running != state.eventTapRunning { state.eventTapRunning = running }
            logPermissionsIfChanged()
        }
        applyPointer()
        schedulePermissionTimer()
    }

    private var lastLoggedPermissions = ""

    /// 权限状态有变化时记一笔日志，方便排查“授权了但没生效”。
    private func logPermissionsIfChanged() {
        let summary = "辅助功能=\(state.accessibilityGranted) 输入监控=\(state.inputMonitoringGranted) "
            + "读取剪贴板=\(state.pasteboardAccess) 完全磁盘访问=\(state.fullDiskAccessGranted) 事件拦截=\(state.eventTapRunning)"
        guard summary != lastLoggedPermissions else { return }
        lastLoggedPermissions = summary
        Log.app.notice("权限状态：\(summary, privacy: .public)")
    }

    private var tapRetryTicks = 0

    private var needsFastPermissionPolling: Bool {
        !state.allGood
            || (configStore.config.clipboard.enabled && state.pasteboardAccess != .allowed)
            || PermissionGuide.shared.isActive
            || SelfTest.isRequested
    }

    /// 缺少必需权限或事件拦截未就绪时每秒轮询，授权后马上启用；一切正常时降频到 15 秒省电。
    private func startPermissionPolling() {
        pollingEnabled = true
        schedulePermissionTimer()
    }

    private func schedulePermissionTimer() {
        guard pollingEnabled, !timersPaused else { return }
        let desired: TimeInterval = needsFastPermissionPolling ? 1 : 15
        guard permissionTimer == nil || permissionTimerInterval != desired else { return }
        permissionTimer?.invalidate()
        permissionTimerInterval = desired
        let timer = Timer(timeInterval: desired, repeats: true) { [weak self] _ in
            self?.pollPermissions()
        }
        timer.tolerance = desired >= 10 ? 3 : 0.2
        RunLoop.main.add(timer, forMode: .default)
        permissionTimer = timer
    }

    private func refreshPermissionsNow() {
        pollPermissions()
        schedulePermissionTimer()
    }

    private func pollPermissions() {
        let before = (state.accessibilityGranted, state.inputMonitoringGranted)
        state.refreshPermissions()

        let after = (state.accessibilityGranted, state.inputMonitoringGranted)
        if before != after {
            tapRetryTicks = 0
            startEventTapsIfPossible()
        } else if !state.eventTapRunning, after.0 {
            // 辅助功能已授予但事件拦截暂未拉起时退避重试，避免每秒空转刷日志
            tapRetryTicks += 1
            if tapRetryTicks >= 5 {
                tapRetryTicks = 0
                startEventTapsIfPossible()
            }
        } else {
            tapRetryTicks = 0
        }
        // macOS 27：刚开了“设备控制和数据访问”（不管是在引导里还是在系统弹窗里开的），
        // 输入监控要重启才生效，直接重启，不用用户再点
        if PermissionKind.accessibilityCoversInputMonitoring, !before.0, after.0, !after.1, !GuideTest.isRequested {
            PermissionGuide.shared.start([.inputMonitoring], state: state)
        }
        logPermissionsIfChanged()
        schedulePermissionTimer()
    }
}
