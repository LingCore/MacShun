// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 贴靠助手（W3）：把窗口分到一半以后，在另一半列出其他窗口，点一个就放进去，像 Windows 一样。
/// 窗口标题从辅助功能接口读，不需要屏幕录制权限。只在主线程上用。
final class SnapAssist {
    private let onChoose: (WindowElement, CGRect) -> Void
    private let model = SnapAssistModel()
    private var panel: SnapAssistPanel?
    /// 要填的那一半（AX 坐标）
    private var area: CGRect = .zero

    init(onChoose: @escaping (WindowElement, CGRect) -> Void) {
        self.onChoose = onChoose
        model.onChoose = { [weak self] candidate in self?.choose(candidate) }
        model.onCancel = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(area: CGRect, excluding id: CGWindowID?) {
        let candidates = Self.candidates(excluding: id)
        guard !candidates.isEmpty else { return }
        self.area = area
        let frame = ScreenGeometry.appKitRect(area).insetBy(dx: 8, dy: 8)
        model.columns = SnapAssistView.columns(forWidth: frame.width)
        model.candidates = candidates
        model.selection = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        FrontAppTracker.shared.snapAssistActive.set(true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        FrontAppTracker.shared.snapAssistActive.set(false)
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.candidates = []
    }

    private func choose(_ candidate: SnapAssistModel.Candidate) {
        let area = self.area
        hide()
        onChoose(candidate.window, area)
    }

    private func makePanel() -> SnapAssistPanel {
        let panel = SnapAssistPanel()
        panel.contentView = NSHostingView(rootView: SnapAssistView(model: model))
        panel.onKey = { [weak self] event in self?.model.handleKey(event) ?? false }
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }

    /// 屏幕上其他的普通窗口，从前到后排。
    static func candidates(excluding excluded: CGWindowID?) -> [SnapAssistModel.Candidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = getpid()
        var elementsByPID: [pid_t: [CGWindowID: WindowElement]] = [:]
        var result: [SnapAssistModel.Candidate] = []
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? CGWindowID, number != excluded,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 120, bounds.height >= 80,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular
            else { continue }
            if elementsByPID[pid] == nil {
                var map: [CGWindowID: WindowElement] = [:]
                for window in WindowElement.windows(of: pid) {
                    if let id = window.windowID { map[id] = window }
                }
                elementsByPID[pid] = map
            }
            guard let window = elementsByPID[pid]?[number], window.isStandard, !window.isMinimized, window.isMovable else { continue }
            let appName = app.localizedName ?? ""
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? appName
            result.append(.init(id: number, window: window, title: title, appName: appName,
                                icon: app.icon ?? NSWorkspace.shared.icon(for: .application)))
            if result.count >= 12 { break }
        }
        return result
    }
}

final class SnapAssistModel: ObservableObject {
    struct Candidate: Identifiable {
        let id: CGWindowID
        let window: WindowElement
        let title: String
        let appName: String
        let icon: NSImage
    }

    @Published var candidates: [Candidate] = []
    @Published var selection = 0
    var columns = 3
    var onChoose: (Candidate) -> Void = { _ in }
    var onCancel: () -> Void = {}

    /// 方向键选，Enter 放进去，Esc 跳过。处理了返回 true。按着 ⌘ ⌃ ⌥ 的不处理。
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !candidates.isEmpty, mods.subtracting(.shift).isEmpty else { return false }
        if event.keyCode == 48 {                            // Tab、Shift+Tab
            move(mods.contains(.shift) ? -1 : 1)
            return true
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 123: move(-1)                                  // ←
        case 124: move(1)                                   // →
        case 125: move(columns)                             // ↓
        case 126: move(-columns)                            // ↑
        case 36, 76: onChoose(candidates[selection])        // Enter
        case 53: onCancel()                                 // Esc
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        let next = selection + delta
        if candidates.indices.contains(next) { selection = next }
    }
}

/// 透明、不抢走前台程序的面板，能接收按键。
final class SnapAssistPanel: NSPanel {
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onResignKey: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event) { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }
}

struct SnapAssistView: View {
    @ObservedObject var model: SnapAssistModel

    static let cardWidth: CGFloat = 176
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 24

    static func columns(forWidth width: CGFloat) -> Int {
        max(1, Int((width - padding * 2 + spacing) / (cardWidth + spacing)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("选一个窗口放在这里"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(L("Esc 跳过"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: Self.spacing),
                                         count: min(model.columns, max(model.candidates.count, 1))),
                          alignment: .center, spacing: Self.spacing) {
                    ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                        card(candidate, selected: index == model.selection)
                            .onHover { inside in if inside { model.selection = index } }
                            .onTapGesture { model.onChoose(candidate) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func card(_ candidate: SnapAssistModel.Candidate, selected: Bool) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: candidate.icon)
                .resizable()
                .frame(width: 52, height: 52)
            Text(candidate.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            Text(candidate.appName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(width: Self.cardWidth, height: 156)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}
