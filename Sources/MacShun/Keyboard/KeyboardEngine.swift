// SPDX-License-Identifier: MIT

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
    /// 按下时已消费并应吞掉后续重复与松键的物理键码（例如 Alt+Tab 期间按 Esc 关闭切换器后继续按住 Esc）。
    private var swallowedKeys: Set<CGKeyCode> = []
    /// Finder 剪切状态（仅在主线程访问，避免事件线程读 NSPasteboard）。
    private var finderCutGeneration = 0
    private var finderCutPending: (generation: Int, before: Int, startedAt: TimeInterval)?
    private var finderCutChangeCount: Int?
    private var finderCutPollWork: DispatchWorkItem?
    /// 连按两下 Ctrl 呼出文件搜索（F1）
    private var doubleControl = DoubleTapDetector()
    /// 最近一次同步到 environment.keyboardLayout 的值，避免每次按键都获取写锁。
    private var lastPublishedLayout: KeyboardLayoutKind?

    /// 滚轮缩放或鼠标按键打断连按 Ctrl，避免 Ctrl+滚轮误呼出文件搜索。
    func cancelDoubleControl() {
        _ = doubleControl.feed(.other, at: 0)
    }

    init(config: Locked<AppConfig>, environment: FrontAppTracker, onCommand: @escaping (SystemCommand) -> Void) {
        self.config = config
        self.environment = environment
        self.onCommand = onCommand
    }

    /// 只看不改：连按两下 Ctrl 时通知主线程打开文件搜索。远程桌面、虚拟机里不响应，Ctrl 留给里面的系统。
    private func watchDoubleControl(_ event: CGEvent, appConfig: AppConfig) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == KeyCode.control || keyCode == KeyCode.rightControl else {
            _ = doubleControl.feed(.other, at: 0)
            return
        }
        guard appConfig.fileSearch.enabled else {
            _ = doubleControl.feed(.other, at: 0)
            return
        }
        let down = event.flags.contains(.maskControl)
        let now = ProcessInfo.processInfo.systemUptime
        // 按着 Ctrl 点了鼠标（Mac 上的右键）：不算单按一下 Ctrl，免得连着两次 Ctrl+点击打开搜索
        if !down, let start = doubleControl.pressStart {
            let sinceClick = min(
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
                min(
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown),
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .otherMouseDown)
                )
            )
            if sinceClick < now - start {
                _ = doubleControl.feed(.other, at: 0)
                return
            }
        }
        let input = DoubleTapDetector.Input.control(down: down, flags: event.flags)
        guard doubleControl.feed(input, at: now) else { return }
        guard AppCatalog.kind(of: environment.current.get(), userExcluded: appConfig.keyboard.excludedApps) != .excluded
        else { return }
        DispatchQueue.main.async { [onCommand] in onCommand(.fileSearch) }
    }

    /// 当前这把键盘的布局（任何线程都可以调用，自测与鼠标侧键用）。
    func currentLayout() -> KeyboardLayoutKind {
        config.get().keyboard.layout(for: devices.activeDevice)
    }

    func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let appConfig = config.get()
        var cfg = appConfig.keyboard
        let device = devices.activeDevice
        var layout = cfg.layout(for: device)
        if lastPublishedLayout != layout {
            lastPublishedLayout = layout
            environment.keyboardLayout.set(layout)
        }
        // 设置里正在录快捷键：原样放行，录下实际按的键（也不算连按 Ctrl）
        if environment.recordingShortcut.get() && !switcherOpen {
            return Unmanaged.passUnretained(event)
        }

        // 只要 Alt 已经松开，切换器就该关了。万一漏掉了松开 Alt 的事件（例如拦截被系统暂停过），
        // 在这里补上，否则之后每个键都会被加上 ⌘。
        if switcherOpen && !event.flags.contains(switcherAltFlag) {
            closeSwitcher(proxy: proxy)
        }

        if type == .flagsChanged {
            if !environment.captureActive.get() { watchDoubleControl(event, appConfig: appConfig) }
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

        // 选区面板处理自己的键；热键本身的松键仍由上面的 handleKeyUp 配对。
        if environment.captureActive.get() {
            if isRepeat, let previous = activeKeys[keyCode], previous != .pass { return nil }
            return Unmanaged.passUnretained(event)
        }

        let clipboardPanelActive = environment.clipboardPanelActive.get()
        // 历史面板里 F3 留给选中的图片，即使用户把 F3 录成了全局截图键。
        if clipboardPanelActive, keyCode == KeyCode.f3,
           event.flags.intersection(.modifierKeys).isEmpty {
            return Unmanaged.passUnretained(event)
        }

        let fileSearchPanelActive = environment.fileSearchPanelActive.get()
        let searchPanelActive = clipboardPanelActive || fileSearchPanelActive
        let panelActive = searchPanelActive || environment.snapAssistActive.get()
        let frontApp = environment.current.get()
        let frontAppKind = AppCatalog.kind(of: frontApp, userExcluded: cfg.excludedApps)

        // 从按法学习外部键盘的 Win/Mac 模式（键盘功能关闭、苹果自带/妙控键盘或排除应用内不学习）。
        if cfg.enabled && cfg.autoDetectLayout && learningEnabled.get() && !isRepeat
            && device?.isApple != true && (panelActive || frontAppKind != .excluded),
           let learned = inference.observe(keyCode: keyCode, flags: event.flags, current: layout, device: device?.key) {
            layout = learned
            if lastPublishedLayout != layout {
                lastPublishedLayout = layout
                environment.keyboardLayout.set(layout)
            }
            record(learned, for: device)
        }
        cfg.layout = layout
        let mapper = KeyMapper(config: cfg)
        let action: KeyAction
        if isRepeat, swallowedKeys.contains(keyCode) {
            return nil
        }
        if isRepeat, let previous = activeKeys[keyCode] {
            action = previous
        } else if environment.scrollingCaptureActive.get(), event.flags.intersection(.modifierKeys).isEmpty,
                  [KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.escape].contains(keyCode) {
            // 接住完整的按下/松开，避免结束长截图的回车同时发到下面的聊天窗口。
            action = .command(keyCode == KeyCode.escape ? .cancelScrollingCapture : .finishScrollingCapture)
        } else {
            let context: KeyContext
            if panelActive {
                // 剪贴板面板、文件搜索框或贴靠助手开着时，按键在本程序的面板里，不按后面那个应用的规则处理。
                context = KeyContext(
                    appKind: .normal,
                    clipboardEnabled: appConfig.clipboard.enabled,
                    inputSourceID: environment.inputSourceID.get(),
                    searchPanelActive: searchPanelActive,
                    fileSearchPanelActive: fileSearchPanelActive && !clipboardPanelActive,
                    windowShortcuts: appConfig.window.enabled,
                    focus: { .text }
                )
            } else {
                context = KeyContext(
                    appKind: frontAppKind,
                    isBrowser: AppCatalog.isBrowser(frontApp),
                    clipboardEnabled: appConfig.clipboard.enabled,
                    inputSourceID: environment.inputSourceID.get(),
                    windowShortcuts: appConfig.window.enabled,
                    hasCopiedScreenshot: { CaptureClipboard.general.containsScreenshot },
                    focus: { [focusInspector] in focusInspector.focusKind() }
                )
            }
            action = mapper.action(keyCode: keyCode, flags: event.flags, context: context)
        }

        switch action {
        case .pass:
            activeKeys[keyCode] = .pass
            if keyCode == KeyCode.c && event.flags.contains(.maskCommand) {
                DispatchQueue.main.async { [weak self] in self?.cancelFinderCutOnMain() }
            }
            return Unmanaged.passUnretained(event)

        case .send(let stroke):
            activeKeys[keyCode] = action
            if stroke == KeyStroke(KeyCode.c, .maskCommand) {
                DispatchQueue.main.async { [weak self] in self?.cancelFinderCutOnMain() }
            }
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
            if !isRepeat {
                DispatchQueue.main.async { [weak self] in self?.performFinderCutOnMain() }
            }
            return nil

        case .finderPaste:
            activeKeys[keyCode] = action
            DispatchQueue.main.async { [weak self] in self?.performFinderPasteOnMain(isRepeat: isRepeat) }
            return nil
        }
    }

    private func handleKeyUp(keyCode: CGKeyCode, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        if swallowedKeys.remove(keyCode) != nil {
            activeKeys.removeValue(forKey: keyCode)
            return nil
        }
        guard let action = activeKeys.removeValue(forKey: keyCode), action != .pass else {
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
        cancelDoubleControl()
        closeSwitcher(proxy: proxy)
        for stroke in sentStrokes.values {
            post(Synthetic.keyEvent(stroke, down: false), proxy: proxy)
        }
        sentStrokes.removeAll()
        activeKeys.removeAll()
        swallowedKeys.removeAll()
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
            if keyCode == KeyCode.escape {
                // 按 Esc 会立刻关闭系统切换器；同步释放合成的 ⌘，避免松开 Alt 前后续按键误带 ⌘。
                // 记入 swallowedKeys，吞掉继续按住 Esc 产生的重复与最终松键，不向前台应用泄漏 ⌘+Esc。
                post(Synthetic.keyEvent(stroke, down: true, original: event), proxy: proxy)
                post(Synthetic.keyEvent(stroke, down: false, original: event), proxy: proxy)
                closeSwitcher(proxy: proxy)
                swallowedKeys.insert(keyCode)
                return nil
            }
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

    // MARK: - Finder 剪切（主线程）

    private func cancelFinderCutOnMain() {
        finderCutGeneration += 1
        finderCutPollWork?.cancel()
        finderCutPollWork = nil
        finderCutPending = nil
        finderCutChangeCount = nil
    }

    /// 记下 Ctrl+X 之后的剪贴板计数。如果 ⌘C 没有复制到东西（例如没选中文件），计数不变，就不算剪切，
    /// 否则随后的 Ctrl+V 会把更早复制的文件“移动”过来。
    private func performFinderCutOnMain() {
        cancelFinderCutOnMain()
        let generation = finderCutGeneration
        let before = NSPasteboard.general.changeCount
        finderCutPending = (generation, before, ProcessInfo.processInfo.systemUptime)
        Synthetic.tap(KeyStroke(KeyCode.c, .maskCommand))
        pollFinderCutOnMain(generation: generation, before: before, remainingDelays: [0.04, 0.08, 0.18, 0.30])
    }

    private func pollFinderCutOnMain(generation: Int, before: Int, remainingDelays: [TimeInterval]) {
        guard let delay = remainingDelays.first else {
            if finderCutGeneration == generation {
                finderCutPending = nil
                finderCutPollWork = nil
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.finderCutGeneration == generation else { return }
            let now = NSPasteboard.general.changeCount
            if now != before {
                self.finderCutChangeCount = now
                self.finderCutPending = nil
                self.finderCutPollWork = nil
            } else {
                self.pollFinderCutOnMain(generation: generation, before: before, remainingDelays: Array(remainingDelays.dropFirst()))
            }
        }
        finderCutPollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performFinderPasteOnMain(isRepeat: Bool, waitRemaining: Int = 4) {
        if isRepeat {
            cancelFinderCutOnMain()
            Synthetic.tap(KeyStroke(KeyCode.v, .maskCommand))
            return
        }
        let now = NSPasteboard.general.changeCount
        if let pending = finderCutPending,
           now == pending.before,
           waitRemaining > 0,
           ProcessInfo.processInfo.systemUptime - pending.startedAt < 0.15 {
            let expectedGeneration = pending.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self else { return }
                if self.finderCutGeneration == expectedGeneration {
                    self.performFinderPasteOnMain(isRepeat: false, waitRemaining: waitRemaining - 1)
                } else {
                    Synthetic.tap(KeyStroke(KeyCode.v, .maskCommand))
                }
            }
            return
        }
        let isMove: Bool
        if let cut = finderCutChangeCount, cut == now {
            isMove = true
        } else if let pending = finderCutPending, now != pending.before {
            isMove = true
        } else {
            isMove = false
        }
        cancelFinderCutOnMain()
        let stroke = isMove
            ? KeyStroke(KeyCode.v, [.maskCommand, .maskAlternate])
            : KeyStroke(KeyCode.v, .maskCommand)
        Synthetic.tap(stroke)
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
