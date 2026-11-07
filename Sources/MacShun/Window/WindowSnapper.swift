// SPDX-License-Identifier: MIT

import AppKit

/// Win+方向键这些快捷键要做的事
enum WindowShortcut: Equatable {
    /// Win+←/→/↑/↓
    case snap(WindowLayout.Key)
    /// Win+Shift+←/→：移到左边或右边那块屏幕
    case moveToDisplay(left: Bool)
    /// Win+Shift+↑：拉到屏幕一样高
    case stretchVertically
}

/// 分屏（W1–W3）：Win+方向键、拖到屏幕边缘分屏、分好一半后在另一半列出其他窗口（贴靠助手）。只在主线程上用。
final class WindowSnapper {
    private let configStore: ConfigStore
    private let preview = SnapPreview()
    private lazy var assist = SnapAssist { [weak self] window, area in
        self?.fill(area, with: window)
    }

    /// 每个窗口分屏前的样子，和分屏后的位置，用来恢复、判断它现在是不是分着屏
    private struct Record {
        var restoreFrame: CGRect?
        var snappedFrame: CGRect?
        var position: WindowLayout.Position?
        var updated = Date()
    }
    private var history: [CGWindowID: Record] = [:]

    private var mouseMonitor: Any?
    private var drag: DragState?
    private var previewTask: DispatchWorkItem?
    private var dragGeneration = UUID()
    private var screenObserver: NSObjectProtocol?
    /// 自测用：系统自带的拖动分屏开着也照样处理拖动
    var ignoresNativeTiling = false
    /// 自测用：拖动时预览的位置（AX 坐标）
    private(set) var previewFrame: CGRect?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cancelDrag() }
    }

    deinit {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        previewTask?.cancel()
    }

    private var config: WindowConfig { configStore.config.window }

    /// 按配置开始或停止监听拖动。
    func applyConfig() {
        let wantsDrag = config.enabled && config.dragToSnap
        if wantsDrag && mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged]) { [weak self] event in
                self?.handleMouse(event)
            }
        } else if !wantsDrag, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if !wantsDrag { cancelDrag() }
        if !config.enabled || !config.snapAssist { assist.hide() }
    }

    // MARK: - 快捷键

    var isAssistVisible: Bool { assist.isVisible }

    /// 当前窗口：本程序在前台时是自己的窗口（不算浮动面板），否则问辅助功能接口
    private static func focusedWindow() -> (any SnappableWindow)? {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            guard let window, !(window is NSPanel), window.isVisible else { return nil }
            return OwnWindow(window: window)
        }
        return WindowElement.focused()
    }

    func handle(_ shortcut: WindowShortcut) {
        cancelDrag()
        guard config.enabled, let window = Self.focusedWindow(), !window.isFullScreen,
              let frame = window.frame else { return }
        let screens = ScreenGeometry.screens()
        guard let index = ScreenGeometry.index(of: frame, in: screens) else { return }
        let id = window.windowID
        let current = position(of: id, frame: frame, area: screens[index].area)
        assist.hide()

        switch shortcut {
        case .snap(let key):
            switch WindowLayout.command(for: key, current: current, screen: index, screenCount: screens.count) {
            case let .snap(position, target):
                snap(window, id: id, from: frame, fromArea: screens[index].area, to: position, on: screens[target], showAssist: true)
            case .restore:
                restore(window, id: id, area: screens[index].area)
            case .minimize:
                window.minimize()
            case .none:
                break
            }
        case .moveToDisplay(let left):
            guard screens.count > 1 else { return }
            let target = (index + (left ? -1 : 1) + screens.count) % screens.count
            if let current {
                snap(window, id: id, from: frame, fromArea: screens[index].area, to: current, on: screens[target], showAssist: false)
            } else {
                let moved = WindowLayout.moved(frame, from: screens[index].area, to: screens[target].area)
                window.setFrame(moved, resize: window.isResizable)
            }
        case .stretchVertically:
            let area = screens[index].area
            window.setFrame(CGRect(x: frame.minX, y: area.minY, width: frame.width, height: area.height))
        }
    }

    /// 窗口现在分在哪：先看是不是还在我们上次放的位置，再按大小位置判断（例如被系统或别的工具分的屏）。
    private func position(of id: CGWindowID?, frame: CGRect, area: CGRect) -> WindowLayout.Position? {
        if let id, let record = history[id], let snapped = record.snappedFrame, let position = record.position,
           Self.same(frame, snapped) {
            return position
        }
        return WindowLayout.position(of: frame, in: area)
    }

    private static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    private func snap(_ window: any SnappableWindow, id: CGWindowID?, from frame: CGRect, fromArea: CGRect,
                      to position: WindowLayout.Position, on screen: ScreenGeometry.Screen, showAssist: Bool) {
        var record = id.flatMap { history[$0] } ?? Record()
        // 从普通状态分屏时记下原来的样子；已经分着屏（换个位置）时保留最早的那个
        if self.position(of: id, frame: frame, area: fromArea) == nil { record.restoreFrame = frame }
        let target = position.frame(in: screen.area)
        var actual: CGRect?
        if window.isResizable {
            actual = window.setFrame(target)
        } else {
            // 改不了大小的窗口（例如计算器）放在那块区域的中间
            let size = frame.size
            let centered = CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2, width: size.width, height: size.height)
            actual = window.setFrame(WindowLayout.clamped(centered.integral, to: screen.area), resize: false)
        }
        // 窗口有最小尺寸、比目标大时，至少别跑出屏幕
        if let result = actual, !screen.area.insetBy(dx: -1, dy: -1).contains(result) {
            actual = window.setFrame(WindowLayout.clamped(result, to: screen.area), resize: false)
        }
        if let id {
            record.snappedFrame = actual ?? target
            record.position = position
            record.updated = Date()
            remember(id, record)
        }
        if showAssist, config.snapAssist, let opposite = position.opposite {
            assist.show(area: opposite.frame(in: screen.area), excluding: id)
        }
    }

    private func restore(_ window: any SnappableWindow, id: CGWindowID?, area: CGRect) {
        let remembered = id.flatMap { history[$0]?.restoreFrame }
        window.setFrame(WindowLayout.restoredFrame(remembered: remembered, in: area))
        if let id { history[id] = nil }
    }

    /// 贴靠助手里选了一个窗口：放进另一半，并切换到它。
    private func fill(_ area: CGRect, with window: WindowElement) {
        let screens = ScreenGeometry.screens()
        guard let frame = window.frame,
              let target = screens.first(where: { $0.area.contains(CGPoint(x: area.midX, y: area.midY)) }),
              let position = WindowLayout.position(of: area, in: target.area, tolerance: 1) else { return }
        let fromArea = ScreenGeometry.index(of: frame, in: screens).map { screens[$0].area } ?? target.area
        snap(window, id: window.windowID, from: frame, fromArea: fromArea, to: position, on: target, showAssist: false)
        window.focus()
    }

    private func remember(_ id: CGWindowID, _ record: Record) {
        history[id] = record
        // 关掉的窗口留下的记录，太多时去掉最旧的
        if history.count > 300, let oldest = history.min(by: { $0.value.updated < $1.value.updated })?.key {
            history[oldest] = nil
        }
    }

    // MARK: - 拖到屏幕边缘分屏

    private struct DragState {
        let start: CGPoint
        /// 按下时鼠标下面的窗口编号
        let windowNumber: CGWindowID?
        let screens: [ScreenGeometry.Screen]
        var intent: DragSnapIntent
        var window: WindowElement?
        var startFrame: CGRect?
        /// 已经找过窗口（只找一次）
        var resolved = false
        /// 确定是在拖窗口（位置变了、大小没变）
        var moving = false
        /// 拖之前的样子，分屏后恢复用
        var restoreFrame: CGRect?
    }

    /// 只有从窗口顶部（标题栏、工具栏、标签栏）开始的拖动才可能是在拖窗口。
    /// 在内容里拖（选文字、拖文件）不跟踪，免得每个拖动事件都去问一次窗口位置。
    private static let titleBarHeight: CGFloat = 80

    private func handleMouse(_ event: NSEvent) {
        // 事件的坐标与时间必须成对使用：主线程处理回调时，全局光标可能已经跨了屏。
        let point = event.cgEvent?.location ?? ScreenGeometry.axPoint(NSEvent.mouseLocation)
        if event.type == .keyDown {
            if event.keyCode == KeyCode.escape { cancelDrag() }
            return
        }
        if event.type == .flagsChanged {
            if yieldsToNativeTiling(event.modifierFlags) { cancelDrag() }
            return
        }
        switch event.type {
        case .leftMouseDown:
            cancelDrag()
            // 系统自带的拖动分屏开着时让它来，两个一起会打架
            guard ignoresNativeTiling || !NativeTiling.dragTilingEnabled else {
                return
            }
            assist.hide()
            let number = event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
            let screens = ScreenGeometry.screens()
            drag = DragState(start: point, windowNumber: number > 0 ? CGWindowID(number) : nil,
                             screens: screens,
                             intent: DragSnapIntent(screens: screens.map(\.frame), cursor: point, time: event.timestamp))

        case .leftMouseDragged:
            guard var state = drag else { return }
            // 系统的“按住 ⌥ 拖动平铺”开着时，按着 ⌥ 拖让给系统
            if yieldsToNativeTiling(event.modifierFlags) || state.screens != ScreenGeometry.screens() {
                cancelDrag()
                return
            }
            if !state.resolved {
                state.resolved = true
                guard let window = WindowElement.under(state.start), let frame = window.frame,
                      state.start.y - frame.minY <= Self.titleBarHeight,
                      state.windowNumber == nil || window.windowID == state.windowNumber,
                      window.isStandard, window.isMovable, !window.isFullScreen
                else {
                    cancelDrag()
                    return
                }
                state.window = window
                state.startFrame = frame
                state.restoreFrame = frame
            }
            guard let window = state.window, let startFrame = state.startFrame else { return }
            if !state.moving {
                guard let frame = window.frame, frame.size == startFrame.size else {
                    cancelDrag()   // 在改大小
                    return
                }
                guard frame.origin != startFrame.origin else {
                    drag = state
                    return
                }
                state.moving = true
                unsnapIfNeeded(window, frame: frame, cursor: point, state: &state)
            }
            updateTarget(cursor: point, time: event.timestamp, state: &state)
            drag = state

        case .leftMouseUp:
            guard var state = drag else { return }
            drag = nil
            previewTask?.cancel()
            previewTask = nil
            preview.hide()
            previewFrame = nil
            guard state.moving, state.screens == ScreenGeometry.screens(),
                  !yieldsToNativeTiling(event.modifierFlags),
                  let target = state.intent.release(cursor: point, time: event.timestamp) else { return }
            let generation = dragGeneration
            let expiresAt = ProcessInfo.processInfo.systemUptime + 0.12
            // 下一轮开始检查原生拖动是否结束；窗口位置稳定以后才写 AX，最多等约 100ms。
            DispatchQueue.main.async { [weak self] in
                self?.finishDrop(state, target: target, generation: generation, expiresAt: expiresAt)
            }

        default:
            break
        }
    }

    /// 拖动一个分着屏的窗口时，马上恢复原来的大小（Windows 也是这样），窗口跟着鼠标走。
    /// 只比大小：第一次读到位置时窗口已经被拖动了一点。
    private func unsnapIfNeeded(_ window: WindowElement, frame: CGRect, cursor: CGPoint, state: inout DragState) {
        guard let id = window.windowID, let record = history[id], let snapped = record.snappedFrame,
              let startFrame = state.startFrame,
              abs(startFrame.width - snapped.width) <= 2, abs(startFrame.height - snapped.height) <= 2,
              let restore = record.restoreFrame else { return }
        let unsnapped = WindowLayout.unsnappedFrame(current: frame, restoreSize: restore.size, cursor: cursor)
        window.setFrame(unsnapped)
        state.restoreFrame = unsnapped
        history[id] = nil
    }

    private func yieldsToNativeTiling(_ flags: NSEvent.ModifierFlags) -> Bool {
        !ignoresNativeTiling && (NativeTiling.dragTilingEnabled
            || (flags.contains(.option) && NativeTiling.optionAcceleratorEnabled))
    }

    private func cancelDrag() {
        dragGeneration = UUID()
        drag = nil
        previewTask?.cancel()
        previewTask = nil
        preview.hide()
        previewFrame = nil
    }

    private func updateTarget(cursor: CGPoint, time: TimeInterval, state: inout DragState) {
        state.intent.update(cursor: cursor, time: time)
        let frame = state.intent.target.map { $0.position.frame(in: state.screens[$0.screen].area) }
        if frame != previewFrame {
            previewFrame = frame
            if let frame {
                preview.show(ScreenGeometry.appKitRect(frame))
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            } else {
                preview.hide()
            }
        }
        previewTask?.cancel()
        previewTask = nil
        guard let deadline = state.intent.deadline else { return }
        let generation = dragGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, generation == self.dragGeneration, var state = self.drag else { return }
            guard NSEvent.pressedMouseButtons & 1 != 0, self.config.enabled, self.config.dragToSnap,
                  !self.yieldsToNativeTiling(NSEvent.modifierFlags), state.screens == ScreenGeometry.screens() else {
                self.cancelDrag()
                return
            }
            let cursor = CGEvent(source: nil)?.location ?? ScreenGeometry.axPoint(NSEvent.mouseLocation)
            self.updateTarget(cursor: cursor, time: ProcessInfo.processInfo.systemUptime, state: &state)
            self.drag = state
        }
        previewTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, deadline - ProcessInfo.processInfo.systemUptime), execute: task)
    }

    private func finishDrop(_ state: DragState, target: WindowLayout.DragTarget, generation: UUID,
                            expiresAt: TimeInterval, previousFrame: CGRect? = nil, attempt: Int = 0) {
        guard generation == dragGeneration, ProcessInfo.processInfo.systemUptime <= expiresAt,
              config.enabled, config.dragToSnap,
              NSEvent.pressedMouseButtons & 1 == 0, !yieldsToNativeTiling(NSEvent.modifierFlags),
              state.screens == ScreenGeometry.screens(), let window = state.window,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              state.windowNumber == nil || window.windowID == state.windowNumber,
              !window.isFullScreen, let frame = window.frame,
              ProcessInfo.processInfo.systemUptime <= expiresAt else { return }
        // 目标已在 mouse-up 用事件坐标重新核验。松手后正常移动鼠标不应撤销这次放置。
        if let previousFrame, Self.same(frame, previousFrame, tolerance: 1) {
            let screen = state.screens[target.screen]
            let restoreFrame = state.restoreFrame ?? state.startFrame ?? frame
            let fromArea = ScreenGeometry.index(of: restoreFrame, in: state.screens).map { state.screens[$0].area } ?? screen.area
            if let id = window.windowID { history[id]?.snappedFrame = nil }
            snap(window, id: window.windowID, from: restoreFrame, fromArea: fromArea,
                 to: target.position, on: screen, showAssist: true)
        } else if attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                self?.finishDrop(state, target: target, generation: generation, expiresAt: expiresAt,
                                 previousFrame: frame, attempt: attempt + 1)
            }
        }
    }
}

/// macOS 15 起系统自带的拖动分屏（“系统设置 → 桌面与程序坞 → 将窗口拖到屏幕边缘以平铺”）。
/// 和我们的拖动分屏同时开着会打架：两边都去摆窗口。
enum NativeTiling {
    private static let domain = "com.apple.WindowManager"

    /// 拖到左右边、四个角平铺，或者拖到上边（菜单栏）填满屏幕，开着任何一个都会和我们抢
    static var dragTilingEnabled: Bool {
        guard #available(macOS 15, *) else { return false }
        return enabled("EnableTilingByEdgeDrag") || enabled("EnableTopTilingByEdgeDrag")
    }

    /// 按住 ⌥ 拖动时平铺。只在按着 ⌥ 时起作用，那时让给系统
    static var optionAcceleratorEnabled: Bool {
        guard #available(macOS 15, *) else { return false }
        return enabled("EnableTilingOptionAccelerator")
    }

    /// 没写过就是开着（系统默认）
    private static func enabled(_ key: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: domain), defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    /// 用户在设置里点了按钮才调用：关掉系统自带的拖动分屏（和在系统设置里关掉一样）
    static func disableDragTiling() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        for key in ["EnableTilingByEdgeDrag", "EnableTopTilingByEdgeDrag", "EnableTilingOptionAccelerator"] {
            defaults.set(false, forKey: key)
        }
        defaults.synchronize()
        Log.app.notice("分屏：关掉了系统自带的拖动分屏")
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 拖动时显示要分到哪里的半透明框。
final class SnapPreview {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        tint.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        tint.layer?.borderWidth = 2
        tint.layer?.cornerRadius = 12
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)
        panel.contentView = effect
        return panel
    }()

    func show(_ frame: CGRect) {
        let inset = frame.insetBy(dx: 6, dy: 6)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(inset, display: true)
            }
        } else {
            panel.setFrame(inset, display: true)
            panel.contentView?.subviews.first?.frame = panel.contentView?.bounds ?? .zero
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
