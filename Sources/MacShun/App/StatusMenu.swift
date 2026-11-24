// SPDX-License-Identifier: MIT

import AppKit
import Combine

/// 菜单栏图标和菜单。
final class StatusMenu: NSObject, NSMenuDelegate, NSViewToolTipOwner {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let configStore: ConfigStore
    private let state: AppState
    private let clipboard: ClipboardController
    private let openSettings: () -> Void
    private let openPerformance: () -> Void
    private let performance = PerformanceMonitor.shared
    private var performanceConfig = PerformanceConfig()
    private let openClipboard: () -> Void
    private let capture: (CaptureMode) -> Void
    private var subscriptions: Set<AnyCancellable> = []

    private struct LayoutKey: Equatable {
        let active: Bool
        let visual: PerformanceConfig.VisualSignature
    }

    private struct ImageKey: Equatable {
        let active: Bool
        let needsAttention: Bool
        let visual: PerformanceMenuBarImage.VisualKey?
    }

    private struct AccessibilityKey: Equatable {
        let allGood: Bool
        let values: [String]
    }

    private var lastLayoutKey: LayoutKey?
    private var lastImageKey: ImageKey?
    private var lastAllGood: Bool?
    private var lastAccessibilityKey: AccessibilityKey?
    private var toolTipTag: NSView.ToolTipTag?
    private var screenObserver: NSObjectProtocol?

    init(configStore: ConfigStore, state: AppState, clipboard: ClipboardController, openSettings: @escaping () -> Void,
         openPerformance: @escaping () -> Void, openClipboard: @escaping () -> Void,
         capture: @escaping (CaptureMode) -> Void) {
        self.configStore = configStore
        self.state = state
        self.clipboard = clipboard
        self.openSettings = openSettings
        self.openPerformance = openPerformance
        self.openClipboard = openClipboard
        self.capture = capture
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        item.button?.imageScaling = .scaleNone

        configStore.$config
            .map(\.performance)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] perf in
                guard let self else { return }
                self.performanceConfig = perf
                self.performance.apply(perf)
                self.updateIcon()
            }
            .store(in: &subscriptions)
        performance.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &subscriptions)

        Publishers.Merge3(
            state.$accessibilityGranted.removeDuplicates(),
            state.$inputMonitoringGranted.removeDuplicates(),
            state.$eventTapRunning.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateIcon() }
        .store(in: &subscriptions)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastLayoutKey = nil
            self.lastImageKey = nil
            self.updateIcon()
        }
    }

    deinit {
        if let tag = toolTipTag { item.button?.removeToolTip(tag) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let name = state.allGood ? L("Mac顺") : L("Mac顺：需要授权")
        let values = performanceConfig.isActive
            ? performanceConfig.metrics.map { "\($0.title)：\(performance.snapshot.text($0))" }
            : []
        return ([name] + values).joined(separator: "\n")
    }

    private func refreshToolTipRegion(on button: NSStatusBarButton) {
        if let tag = toolTipTag { button.removeToolTip(tag) }
        toolTipTag = button.addToolTip(button.bounds, owner: self, userData: nil)
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        let active = performanceConfig.isActive
        let needsAttention = !state.allGood
        let effectiveConfig = active ? performanceConfig : PerformanceConfig()
        let layoutKey = LayoutKey(active: active, visual: effectiveConfig.visualSignature)
        let visual = active
            ? PerformanceMenuBarImage.visualKey(
                snapshot: performance.snapshot, history: performance.history,
                configuration: performanceConfig, needsAttention: needsAttention
            )
            : nil
        let imageKey = ImageKey(active: active, needsAttention: needsAttention, visual: visual)
        let layoutChanged = layoutKey != lastLayoutKey

        if layoutChanged || imageKey != lastImageKey {
            lastImageKey = imageKey
            let image = active
                ? PerformanceMenuBarImage.make(snapshot: performance.snapshot, history: performance.history,
                                               configuration: performanceConfig, needsAttention: needsAttention)
                : BrandMark.menuBarImage(needsAttention: needsAttention)
            if layoutChanged {
                lastLayoutKey = layoutKey
                if active {
                    // 配置变化时先按系统默认边距量一次实际宽度，再锁定为固定宽度，避免后续每次刷新都触发 AutoLayout 和状态栏几何 IPC。
                    item.length = NSStatusItem.variableLength
                    button.image = image
                    let measured = button.frame.width
                    item.length = ceil(measured >= image.size.width ? measured : image.size.width + 16)
                } else {
                    item.length = NSStatusItem.squareLength
                    button.image = image
                }
                refreshToolTipRegion(on: button)
            } else {
                button.image = image
            }
        }

        if lastAllGood != state.allGood {
            lastAllGood = state.allGood
            button.setAccessibilityLabel(state.allGood ? L("Mac顺") : L("Mac顺：需要授权"))
        }
        // 悬停提示改由 NSViewToolTipOwner 按需生成，避免每 2 秒无悬停时频繁重建提示与追踪区域；
        // 无障碍读数仅在配置变更或开启旁白时同步更新。
        if layoutChanged || NSWorkspace.shared.isVoiceOverEnabled {
            let values = active ? performanceConfig.metrics.map { "\($0.title)：\(performance.snapshot.text($0))" } : []
            let accessibilityKey = AccessibilityKey(allGood: state.allGood, values: values)
            if accessibilityKey != lastAccessibilityKey {
                lastAccessibilityKey = accessibilityKey
                button.setAccessibilityValue(values.joined(separator: ", "))
            }
        }
    }

    @MainActor func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = configStore.config

        menu.addItem(action(L("性能监控设置…"), #selector(showPerformance), symbol: "gauge.with.dots.needle.50percent"))
        menu.addItem(.separator())

        let updater = Updater.shared
        if let release = updater.available, !updater.isSkipped(release) {
            menu.addItem(action(L("更新到 Mac顺 %@…", release.version), #selector(showUpdate), symbol: "arrow.down.circle.fill"))
            menu.addItem(.separator())
        }

        if !state.allGood {
            menu.addItem(action(L("需要授权才能工作…"), #selector(showSettings), symbol: "exclamationmark.triangle.fill"))
            menu.addItem(.separator())
        } else if cfg.clipboard.enabled && state.pasteboardAccess != .allowed {
            menu.addItem(action(L("剪贴板历史需要授权…"), #selector(showSettings), symbol: "exclamationmark.triangle.fill"))
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: L("Mac顺 %@", AppVersion.display)))
        menu.addItem(toggle(L("快捷键像 Windows"), cfg.keyboard.enabled, #selector(toggleKeyboard), symbol: "keyboard"))
        menu.addItem(toggle(L("鼠标像 Windows"), cfg.mouse.enabled, #selector(toggleMouse), symbol: "computermouse"))
        menu.addItem(toggle(L("记录剪贴板历史"), cfg.clipboard.enabled, #selector(toggleClipboard), symbol: "doc.on.clipboard"))
        menu.addItem(.separator())

        let history = action(L("打开剪贴板历史"), #selector(showClipboard), symbol: "clock.arrow.circlepath")
        history.isEnabled = cfg.clipboard.enabled
        menu.addItem(history)
        if cfg.clipboard.enabled {
            let paused = clipboard.isRecordingPaused
            menu.addItem(action(paused ? L("恢复剪贴板记录") : L("暂停剪贴板记录"),
                                #selector(toggleClipboardPause), symbol: paused ? "play.circle" : "pause.circle"))
            if cfg.clipboard.sync.enabled {
                let syncPaused = clipboard.sync.isPaused
                let count = clipboard.sync.connectedPeers.count
                let syncTitle = syncPaused
                    ? L("恢复剪贴板共享")
                    : (count > 0 ? L("暂停剪贴板共享（已连接 %ld 台）", count) : L("暂停剪贴板共享"))
                menu.addItem(action(syncTitle,
                                    #selector(toggleClipboardSyncPause),
                                    symbol: syncPaused ? "play.circle" : "arrow.triangle.2.circlepath.circle"))
            }
        }
        menu.addItem(action(CaptureMode.image.title, #selector(startCapture), symbol: "viewfinder"))
        menu.addItem(action(CaptureMode.text.title, #selector(readText), symbol: "text.viewfinder"))
        menu.addItem(action(L("贴出剪贴板图片"), #selector(pinClipboard), symbol: "macwindow.on.rectangle"))
        if !ScreenPins.shared.windows.isEmpty {
            menu.addItem(action(L("关闭全部贴图"), #selector(closePins), symbol: "xmark.rectangle"))
        }
        menu.addItem(action(L("设置…"), #selector(showSettings), key: ",", symbol: "gearshape"))
        menu.addItem(action(L("检查更新…"), #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        menu.addItem(action(L("退出 Mac顺"), #selector(quit), key: "q", symbol: "power"))
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector, symbol: String) -> NSMenuItem {
        let item = action(title, selector, symbol: symbol)
        item.state = on ? .on : .off
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func toggleKeyboard() { configStore.config.keyboard.enabled.toggle() }
    @objc private func toggleMouse() { configStore.config.mouse.enabled.toggle() }
    @objc private func toggleClipboard() { configStore.config.clipboard.enabled.toggle() }
    @MainActor @objc private func toggleClipboardPause() { clipboard.toggleRecordingPause() }
    @MainActor @objc private func toggleClipboardSyncPause() { clipboard.toggleSyncPause() }
    @objc private func startCapture() { capture(.image) }
    @MainActor @objc private func pinClipboard() { ScreenPins.shared.showClipboard() }
    @MainActor @objc private func closePins() { ScreenPins.shared.closeAll() }
    @objc private func readText() { capture(.text) }
    @objc private func showClipboard() { openClipboard() }
    @objc private func showSettings() { openSettings() }
    @objc private func showPerformance() { openPerformance() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showUpdate() { UpdateWindowController.shared.show(activate: true) }

    @objc private func checkForUpdates() {
        // 用户主动点“检查更新…”时总是重新查一次，避免停留在旧的 available 提示上错过更新版本
        if Updater.shared.activity == .none { Updater.shared.check(manual: true) }
        UpdateWindowController.shared.show(activate: true)
    }
}
