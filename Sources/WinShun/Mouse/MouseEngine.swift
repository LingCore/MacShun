// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics

/// 在事件拦截线程上处理鼠标事件：滚轮方向和步长（M2、M3）、侧键（M4）、Ctrl+滚轮缩放（M5）。
final class MouseEngine {
    private let config: Locked<AppConfig>
    private let frontApp: Locked<AppIdentity>
    let devices = InputDeviceMonitor.mice()

    /// 被换成快捷键的侧键，松开时也要吞掉。
    private var swallowedButtons: Set<Int64> = []

    init(config: Locked<AppConfig>, frontApp: Locked<AppIdentity>) {
        self.config = config
        self.frontApp = frontApp
    }

    func handle(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let cfg = config.get()
        switch type {
        case .scrollWheel:
            return handleScroll(event: event, config: cfg, proxy: proxy)
        case .otherMouseDown, .otherMouseUp:
            return handleButton(event: event, isDown: type == .otherMouseDown, config: cfg, proxy: proxy)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 滚轮

    private func handleScroll(event: CGEvent, config cfg: AppConfig, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard cfg.mouse.enabled else { return pass }
        // 触控板、妙控鼠标是连续滚动，交给系统自己的设置。
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return pass }

        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        let vertical = axis(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        let horizontal = axis(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)

        // M5：Ctrl+滚轮缩放，换成 ⌘= / ⌘-。
        if cfg.mouse.ctrlWheelZoom,
           event.flags.intersection(.modifierKeys) == .maskControl,
           !isExcluded(cfg),
           let up = ScrollTransform.isPhysicallyUp(vertical, invertedFromDevice: inverted) {
            let stroke = KeyStroke(up ? KeyCode.equal : KeyCode.minus, .maskCommand)
            Synthetic.keyEvent(stroke, down: true)?.tapPostEvent(proxy)
            Synthetic.keyEvent(stroke, down: false)?.tapPostEvent(proxy)
            return nil
        }

        let settings = cfg.mouse.settings(forDevice: devices.activeKey)
        let result = ScrollTransform.apply(
            vertical: vertical, horizontal: horizontal,
            invertedFromDevice: inverted, settings: settings
        )
        if result.vertical != vertical {
            setAxis(event, result.vertical, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
        }
        if result.horizontal != horizontal {
            setAxis(event, result.horizontal, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        }
        return pass
    }

    private func axis(_ event: CGEvent, _ lines: CGEventField, _ fixed: CGEventField, _ points: CGEventField) -> ScrollAxis {
        ScrollAxis(
            lines: event.getIntegerValueField(lines),
            fixed: event.getDoubleValueField(fixed),
            points: event.getIntegerValueField(points)
        )
    }

    /// 三个值都要改，不同的应用读的值不一样。
    private func setAxis(_ event: CGEvent, _ value: ScrollAxis, _ lines: CGEventField, _ fixed: CGEventField, _ points: CGEventField) {
        event.setIntegerValueField(lines, value: value.lines)
        event.setDoubleValueField(fixed, value: value.fixed)
        event.setIntegerValueField(points, value: value.points)
    }

    // MARK: - 侧键

    /// 第 4、5 键（编号 3、4）：后退、前进。
    /// 浏览器等本身支持侧键的应用原样放行；其他应用（例如 Finder）换成 ⌘[ / ⌘]。
    private func handleButton(event: CGEvent, isDown: Bool, config cfg: AppConfig, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button == 3 || button == 4 else { return pass }

        if !isDown {
            return swallowedButtons.remove(button) != nil ? nil : pass
        }
        guard cfg.mouse.enabled, cfg.mouse.sideButtons, !isExcluded(cfg) else { return pass }
        guard !AppCatalog.handlesSideButtonsNatively(frontApp.get()) else { return pass }

        swallowedButtons.insert(button)
        let stroke = KeyStroke(button == 3 ? KeyCode.leftBracket : KeyCode.rightBracket, .maskCommand)
        Synthetic.keyEvent(stroke, down: true)?.tapPostEvent(proxy)
        Synthetic.keyEvent(stroke, down: false)?.tapPostEvent(proxy)
        return nil
    }

    private func isExcluded(_ cfg: AppConfig) -> Bool {
        AppCatalog.kind(of: frontApp.get(), userExcluded: cfg.keyboard.excludedApps) == .excluded
    }
}
