// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine

/// 菜单栏图标和菜单。
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let configStore: ConfigStore
    private let state: AppState
    private let openSettings: () -> Void
    private let openClipboard: () -> Void
    private var subscriptions: Set<AnyCancellable> = []

    init(configStore: ConfigStore, state: AppState, openSettings: @escaping () -> Void, openClipboard: @escaping () -> Void) {
        self.configStore = configStore
        self.state = state
        self.openSettings = openSettings
        self.openClipboard = openClipboard
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &subscriptions)
    }

    private func updateIcon() {
        item.button?.image = BrandMark.menuBarImage(needsAttention: !state.allGood)
        item.button?.toolTip = state.allGood ? L("Mac顺") : L("Mac顺：需要授权")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = configStore.config

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

        menu.addItem(.sectionHeader(title: L("Mac顺")))
        menu.addItem(toggle(L("快捷键像 Windows"), cfg.keyboard.enabled, #selector(toggleKeyboard), symbol: "keyboard"))
        menu.addItem(toggle(L("鼠标像 Windows"), cfg.mouse.enabled, #selector(toggleMouse), symbol: "computermouse"))
        menu.addItem(toggle(L("剪贴板历史"), cfg.clipboard.enabled, #selector(toggleClipboard), symbol: "doc.on.clipboard"))
        menu.addItem(.separator())

        let history = action(L("打开剪贴板历史"), #selector(showClipboard), symbol: "clock.arrow.circlepath")
        history.isEnabled = cfg.clipboard.enabled
        menu.addItem(history)
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
    @objc private func showClipboard() { openClipboard() }
    @objc private func showSettings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showUpdate() { UpdateWindowController.shared.show(activate: true) }

    @objc private func checkForUpdates() {
        // 已经知道有新版本就直接给看；否则先开始检查，窗口里显示“正在检查”
        if Updater.shared.available == nil { Updater.shared.check(manual: true) }
        UpdateWindowController.shared.show(activate: true)
    }
}
