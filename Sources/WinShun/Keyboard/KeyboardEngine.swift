// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics

/// 在事件拦截线程上处理键盘事件：按 KeyMapper 的规则改写，并记住每个按下的键是怎么处理的，
/// 松开时按同样的方式处理。每个按键按它所来自的那把键盘的布局处理。
final class KeyboardEngine {
    private let config: Locked<AppConfig>
    private let environment: FrontAppTracker
    private let focusInspector = FocusInspector()
    private let onCommand: (SystemCommand) -> Void
    let devices = InputDeviceMonitor.keyboards()

    /// 学到键盘的模式后在主线程上调用。设备为 nil 表示不知道是哪把键盘，改的是默认布局。
    var onLayoutLearned: ((InputDevice?, KeyboardLayoutKind) -> Void)?
    /// 是否从按法学习键盘模式。自测时关掉：自测会故意模拟另一种模式的按法。
    let learningEnabled = Locked(true)
    private var inference = LayoutInference()

    /// 按下时做出的决定，松开时照着做。键是物理键码。
    private var activeKeys: [CGKeyCode: KeyAction] = [:]
    /// 已发出的替换按键，松开时发同一个键的松开事件。
    private var sentStrokes: [CGKeyCode: KeyStroke] = [:]
    /// Alt+Tab 打开的应用切换器是否还开着。
    private var switcherOpen = false
    /// 打开切换器时 Alt 键对应的修饰键。之后按这个判断 Alt 是否松开，不受布局随后变化的影响。
    private var switcherAltFlag: CGEventFlags = .maskAlternate
    /// Finder 里按 Ctrl+X 之后剪贴板的变化计数，用来判断随后的 Ctrl+V 是不是“移动”。
    private let finderCutChangeCount = Locked<Int?>(nil)
    /// 连按两下 Ctrl 呼出文件搜索（F1）
    private var doubleControl = DoubleTapDetector()

    init(config: Locked<AppConfig>, environment: FrontAppTracker, onCommand: @escaping (SystemCommand) -> Void) {
        self.config = config
        self.environment = environment
        self.onCommand = onCommand
    }

    /// 只看不改：连按两下 Ctrl 时通知主线程打开文件搜索。远程桌面、虚拟机里不响应，Ctrl 留给里面的系统。
    private func watchDoubleControl(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == KeyCode.control || keyCode == KeyCode.rightControl else {
            _ = doubleControl.feed(.other, at: 0)
            return
        }
        let input = DoubleTapDetector.Input.control(down: event.flags.contains(.maskControl), flags: event.flags)
        guard doubleControl.feed(input, at: ProcessInfo.processInfo.systemUptime) else { return }
        let cfg = config.get()
        guard cfg.fileSearch.enabled,
              AppCatalog.kind(of: environment.current.get(), userExcluded: cfg.keyboard.excludedApps) != .excluded
        else { return }
        DispatchQueue.main.async { [onCommand] in onCommand(.fileSearch) }
    }

    /// 当前这把键盘的布局（任何线程都可以调用，自测用）。
    func currentLayout() -> KeyboardLayoutKind {
        config.get().keyboard.layout(for: devices.activeDevice)
    }

    func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        var cfg = config.get().keyboard
        let device = devices.activeDevice
        var layout = cfg.layout(for: device)

        // 只要 Alt 已经松开，切换器就该关了。万一漏掉了松开 Alt 的事件（例如拦截被系统暂停过），
        // 在这里补上，否则之后每个键都会被加上 ⌘。
        if switcherOpen && !event.flags.contains(switcherAltFlag) {
            closeSwitcher(proxy: proxy)
        }

        if type == .flagsChanged {
            watchDoubleControl(event)
            if switcherOpen {
                // 切换器开着时按 Shift（Alt+Shift+Tab）：保持 ⌘、去掉 Alt，免得系统以为 ⌘ 松开了。
                event.flags = Self.switcherFlags(event.flags, altFlag: switcherAltFlag)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = type == .keyDown
        if isDown { _ = doubleControl.feed(.other, at: 0) }

        if switcherOpen {
            return handleWhileSwitcherOpen(keyCode: keyCode, isDown: isDown, event: event, proxy: proxy)
        }

        if !isDown {
            return handleKeyUp(keyCode: keyCode, event: event, proxy: proxy)
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // 从按法学习键盘的 Win/Mac 模式。
        if cfg.autoDetectLayout && learningEnabled.get() && !isRepeat,
           let learned = inference.observe(keyCode: keyCode, flags: event.flags, current: layout, device: device?.key) {
            layout = learned
            record(learned, for: device)
        }
        cfg.layout = layout
        let mapper = KeyMapper(config: cfg)
        let action: KeyAction
        if isRepeat, let previous = activeKeys[keyCode] {
            action = previous
        } else {
            let context: KeyContext
            if environment.clipboardPanelActive.get() || environment.fileSearchPanelActive.get() {
                // 剪贴板面板或文件搜索框开着时，按键在本程序的搜索框里，不按后面那个应用的规则处理。
                context = KeyContext(
                    appKind: .normal, isBrowser: false,
                    clipboardEnabled: config.get().clipboard.enabled,
                    inputSourceID: environment.inputSourceID.get(),
                    windowShortcuts: config.get().window.enabled,
                    focus: { .text }
                )
            } else {
                let app = environment.current.get()
                context = KeyContext(
                    appKind: AppCatalog.kind(of: app, userExcluded: cfg.excludedApps),
                    isBrowser: AppCatalog.isBrowser(app),
                    clipboardEnabled: config.get().clipboard.enabled,
                    chatAppRunning: environment.chatAppRunning.get(),
                    inputSourceID: environment.inputSourceID.get(),
                    windowShortcuts: config.get().window.enabled,
                    focus: { [focusInspector] in focusInspector.focusKind() }
                )
            }
            action = mapper.action(keyCode: keyCode, flags: event.flags, context: context)
        }

        switch action {
        case .pass:
            activeKeys.removeValue(forKey: keyCode)
            return Unmanaged.passUnretained(event)

        case .send(let stroke):
            activeKeys[keyCode] = action
            send(stroke, down: true, original: event, physicalKey: keyCode, proxy: proxy)
            return nil

        case .command(let command):
            activeKeys[keyCode] = action
            if !isRepeat {
                DispatchQueue.main.async { [onCommand] in onCommand(command) }
            }
            return nil

        case .appSwitcher(let reverse):
            activeKeys[keyCode] = action
            // 只有 ⌥Tab 会走到这里（⌘Tab 本来就是系统的切换程序），所以按住的是 ⌥。
            openSwitcher(altFlag: .maskAlternate, proxy: proxy)
            let flags: CGEventFlags = reverse ? [.maskCommand, .maskShift] : .maskCommand
            send(KeyStroke(KeyCode.tab, flags), down: true, original: event, physicalKey: keyCode, proxy: proxy)
            return nil

        case .finderCut:
            activeKeys[keyCode] = action
            let before = NSPasteboard.general.changeCount
            send(KeyStroke(KeyCode.c, .maskCommand), down: true, original: event, physicalKey: keyCode, proxy: proxy)
            if !isRepeat { rememberFinderCut(changeCountBefore: before) }
            return nil

        case .finderPaste:
            activeKeys[keyCode] = action
            let pasteboardCount = NSPasteboard.general.changeCount
            let isMove = finderCutChangeCount.update { cut -> Bool in
                defer { if !isRepeat { cut = nil } }
                return cut == pasteboardCount
            }
            let stroke = isMove
                ? KeyStroke(KeyCode.v, [.maskCommand, .maskAlternate])
                : KeyStroke(KeyCode.v, .maskCommand)
            send(stroke, down: true, original: event, physicalKey: keyCode, proxy: proxy)
            return nil
        }
    }

    private func handleKeyUp(keyCode: CGKeyCode, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        guard activeKeys.removeValue(forKey: keyCode) != nil else {
            return Unmanaged.passUnretained(event)
        }
        if let stroke = sentStrokes.removeValue(forKey: keyCode) {
            post(Synthetic.keyEvent(stroke, down: false, original: event), proxy: proxy)
        }
        return nil
    }

    // MARK: - 键盘布局

    /// 记下布局。马上改给本线程用的配置副本，再通知主线程保存。
    private func record(_ layout: KeyboardLayoutKind, for device: InputDevice?) {
        config.update { c in
            if let device {
                c.keyboard.layouts[device.key] = layout
            } else {
                c.keyboard.layout = layout
            }
        }
        DispatchQueue.main.async { [onLayoutLearned] in onLayoutLearned?(device, layout) }
    }

    // MARK: - 状态

    /// 拦截被系统暂停后调用：之前记下的按键状态已经不可靠，补发松开事件后清空。
    func reset(proxy: CGEventTapProxy) {
        closeSwitcher(proxy: proxy)
        for stroke in sentStrokes.values {
            post(Synthetic.keyEvent(stroke, down: false), proxy: proxy)
        }
        sentStrokes.removeAll()
        activeKeys.removeAll()
    }

    // MARK: - Alt+Tab

    /// Windows 键盘上 Alt 是 ⌥，要让系统的应用切换器以为 ⌘ 一直按着，直到松开 Alt。
    private func openSwitcher(altFlag: CGEventFlags, proxy: CGEventTapProxy) {
        guard !switcherOpen else { return }
        switcherOpen = true
        switcherAltFlag = altFlag
        post(Synthetic.modifierEvent(keyCode: KeyCode.command, flags: [.maskCommand, Self.leftCommandDeviceFlag]), proxy: proxy)
    }

    private func closeSwitcher(proxy: CGEventTapProxy) {
        guard switcherOpen else { return }
        switcherOpen = false
        post(Synthetic.modifierEvent(keyCode: KeyCode.command, flags: []), proxy: proxy)
    }

    /// 切换器开着时，Tab、方向键、Esc 等都加上 ⌘、去掉 Alt，这样切换器能识别。
    private func handleWhileSwitcherOpen(
        keyCode: CGKeyCode, isDown: Bool, event: CGEvent, proxy: CGEventTapProxy
    ) -> Unmanaged<CGEvent>? {
        if !isDown, let stroke = sentStrokes.removeValue(forKey: keyCode) {
            activeKeys.removeValue(forKey: keyCode)
            post(Synthetic.keyEvent(stroke, down: false, original: event), proxy: proxy)
            return nil
        }
        let stroke = KeyStroke(keyCode, Self.switcherFlags(event.flags, altFlag: switcherAltFlag))
        if isDown {
            activeKeys[keyCode] = .send(stroke)
            send(stroke, down: true, original: event, physicalKey: keyCode, proxy: proxy)
        } else {
            activeKeys.removeValue(forKey: keyCode)
            post(Synthetic.keyEvent(stroke, down: false, original: event), proxy: proxy)
        }
        return nil
    }

    /// 左边 ⌘ 键的设备标志（NX_DEVICELCMDKEYMASK）。真实的按键事件都带这类标志。
    private static let leftCommandDeviceFlag = CGEventFlags(rawValue: 0x08)
    /// 左右 Alt（⌥）键的设备标志。
    private static let altDeviceFlags = CGEventFlags(rawValue: 0x20 | 0x40)

    /// 切换器开着时的修饰键：去掉 Alt，加上 ⌘。
    private static func switcherFlags(_ flags: CGEventFlags, altFlag: CGEventFlags) -> CGEventFlags {
        var result = flags
        result.remove(altFlag)
        if altFlag == .maskAlternate { result.remove(altDeviceFlags) }
        result.insert([.maskCommand, leftCommandDeviceFlag])
        return result
    }

    // MARK: - Finder 剪切

    /// 记下 Ctrl+X 之后的剪贴板计数。如果 ⌘C 没有复制到东西（例如没选中文件），计数不变，就不算剪切，
    /// 否则随后的 Ctrl+V 会把更早复制的文件“移动”过来。
    private func rememberFinderCut(changeCountBefore before: Int) {
        // Finder 处理完 ⌘C 后剪贴板计数才会变，稍等一下再看。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [finderCutChangeCount] in
            let now = NSPasteboard.general.changeCount
            finderCutChangeCount.set(now != before ? now : nil)
        }
    }

    // MARK: - 发送

    private func send(_ stroke: KeyStroke, down: Bool, original: CGEvent, physicalKey: CGKeyCode, proxy: CGEventTapProxy) {
        if down { sentStrokes[physicalKey] = stroke }
        post(Synthetic.keyEvent(stroke, down: down, original: original), proxy: proxy)
    }

    /// 从拦截点之后插入事件，不会再经过本程序的拦截。
    private func post(_ event: CGEvent?, proxy: CGEventTapProxy) {
        event?.tapPostEvent(proxy)
    }
}
