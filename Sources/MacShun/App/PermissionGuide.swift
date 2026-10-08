// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI

/// 授权引导：打开“系统设置”对应的那一页，再在它的窗口下面贴一块小浮窗，告诉用户该点哪里。
/// 浮窗里的 Mac顺 图标可以直接拖进列表（列表里没有 Mac顺 时用）。每一项授权成功后打个勾，
/// 自动换到下一项；全部做完把设置窗口带回前台。
enum PermissionKind: CaseIterable {
    case accessibility, inputMonitoring, pasteboard, fullDiskAccess

    /// Mac顺 工作必需的几项，“一键授权”只走这些。完全磁盘访问是可选的：只用来改系统设置里的指针大小
    static let required: [PermissionKind] = [.accessibility, .inputMonitoring, .pasteboard]

    var title: String {
        switch self {
        case .accessibility: L("辅助功能")
        case .inputMonitoring: L("输入监控")
        case .pasteboard: L("读取剪贴板")
        case .fullDiskAccess: L("完全磁盘访问权限")
        }
    }

    /// macOS 27 起“辅助功能”那一页改叫“设备控制和数据访问”，并且包含了监控键盘：“输入监控”列表里
    /// 不会再出现 Mac顺，开了前者、重启 Mac顺 后输入监控就生效。
    static let accessibilityCoversInputMonitoring = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    /// “系统设置”里这一页的名字，浮窗上用它，和用户看到的一致。macOS 27 改了两页的名字。
    var paneTitle: String {
        let modern = Self.accessibilityCoversInputMonitoring
        switch self {
        case .accessibility: return modern ? L("设备控制和数据访问") : L("辅助功能")
        case .inputMonitoring: return L("输入监控")
        case .pasteboard: return modern ? L("从其他App粘贴") : L("粘贴")
        case .fullDiskAccess: return L("完全磁盘访问权限")
        }
    }

    var instruction: String {
        switch self {
        case .accessibility, .inputMonitoring: L("在列表里找到 Mac顺，打开右边的开关")
        // 这个权限要重启 Mac顺 才生效，系统打开开关后会问要不要“退出并重新打开”
        case .fullDiskAccess: L("打开 Mac顺 的开关，再点“退出并重新打开”")
        case .pasteboard: L("在列表里找到 Mac顺，选择“始终允许”")
        }
    }

    /// 列表里可能还没有 Mac顺，这时可以把图标拖进去。“粘贴”那一页不接受拖入。
    var acceptsDrop: Bool { self != .pasteboard }

    func isGranted(_ state: AppState) -> Bool {
        switch self {
        case .accessibility: state.accessibilityGranted
        case .inputMonitoring: state.inputMonitoringGranted
        case .pasteboard: state.pasteboardAccess == .allowed
        case .fullDiskAccess: state.fullDiskAccessGranted
        }
    }

    /// 让系统把 Mac顺 列进这一页，再打开它。
    fileprivate func open() {
        switch self {
        case .accessibility:
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        case .inputMonitoring:
            Permissions.requestInputMonitoring()
            Permissions.openInputMonitoringSettings()
        case .pasteboard:
            PasteboardAccess.request()
        case .fullDiskAccess:
            // 系统不会自己把 Mac顺 列进这一页，要用户把图标拖进去
            Permissions.openFullDiskAccessSettings()
        }
    }
}

/// 浮窗显示的内容。
final class PermissionGuideModel: ObservableObject {
    @Published var kind: PermissionKind = .accessibility
    @Published var step = 1
    @Published var total = 1
    /// 当前这一项刚刚授权成功，正在打勾
    @Published var granted = false
    /// 授权要重启 Mac顺 才生效，正在重启
    @Published var relaunching = false
}

/// 只在主线程上使用。
final class PermissionGuide {
    static let shared = PermissionGuide()

    private let model = PermissionGuideModel()
    private var panel: NSPanel?
    private var state: AppState?
    private var queue: [PermissionKind] = []
    private var subscription: AnyCancellable?
    private var followTimer: Timer?
    /// 见过“系统设置”的窗口之后它又没了，说明用户关掉了，引导也跟着收起来
    private var sawSettingsWindow = false

    /// 自测用：替换“是否已授权”的判断，不用真的去关权限
    var grantedOverride: ((PermissionKind) -> Bool)?
    /// 自测用：浮窗显示的内容和位置
    var currentModel: PermissionGuideModel { model }
    var visiblePanel: NSPanel? { panel?.isVisible == true ? panel : nil }

    private init() {}

    private func isGranted(_ kind: PermissionKind) -> Bool {
        if let grantedOverride { return grantedOverride(kind) }
        guard let state else { return false }
        return kind.isGranted(state)
    }

    /// 实际要走的步骤：去掉已经授权的；macOS 27 上“输入监控”换成“设备控制和数据访问”那一步。
    func plan(_ kinds: [PermissionKind]) -> [PermissionKind] {
        var plan: [PermissionKind] = []
        for kind in kinds where !isGranted(kind) {
            var kind = kind
            if kind == .inputMonitoring && PermissionKind.accessibilityCoversInputMonitoring {
                // 已经开了“设备控制和数据访问”，只差重启，不用再去“系统设置”
                guard !isGranted(.accessibility) else { continue }
                kind = .accessibility
            }
            if !plan.contains(kind) { plan.append(kind) }
        }
        return plan
    }

    /// 从这些权限里挑出还没授权的，一项一项引导。
    func start(_ kinds: [PermissionKind], state: AppState) {
        self.state = state
        guard !model.relaunching else { return }
        queue = plan(kinds)
        model.step = 0
        guard !queue.isEmpty else {
            if needsRelaunch { relaunch() }
            return
        }
        model.total = queue.count
        // 授权状态由 AppDelegate 每秒刷新一次
        subscription = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkGranted() }
        next()
    }

    func stop() {
        subscription = nil
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        queue = []
    }

    private func next() {
        // 前一项可能顺带授了后面的：macOS 27 的“设备控制和数据访问”就包含了监控键盘
        queue.removeAll { isGranted($0) }
        guard !queue.isEmpty else { finish(); return }
        let kind = queue.removeFirst()
        model.kind = kind
        model.step += 1
        model.total = model.step + queue.count
        Log.app.notice("授权引导：第 \(self.model.step)/\(self.model.total) 步，\(kind.paneTitle, privacy: .public)")
        model.granted = false
        sawSettingsWindow = false
        model.relaunching = false
        kind.open()
        showPanel()
    }

    func checkGranted() {
        guard !model.granted, panel?.isVisible == true, isGranted(model.kind) else { return }
        Log.app.notice("授权引导：\(self.model.kind.paneTitle, privacy: .public) 已开启")
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { model.granted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.model.granted else { return }
            self.next()
        }
    }

    /// 开了“设备控制和数据访问”但输入监控还没生效：macOS 要重启 Mac顺 才会应用
    private var needsRelaunch: Bool {
        guard grantedOverride == nil, let state, PermissionKind.accessibilityCoversInputMonitoring else { return false }
        return state.accessibilityGranted && !state.inputMonitoringGranted
    }

    /// 浮窗上说一声，然后重启 Mac顺，重启后自动打开设置窗口。
    private func relaunch() {
        // 引导里打勾和每秒的权限检查可能同时走到这里，只重启一次
        guard !model.relaunching else { return }
        Log.app.notice("授权引导：重启 Mac顺 让输入监控生效")
        model.relaunching = true
        showPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AppState.relaunch(showSettings: true)
        }
    }

    /// 全部做完：收起浮窗，把设置窗口带回来。要重启才生效的，先重启。
    private func finish() {
        if needsRelaunch { return relaunch() }
        Log.app.notice("授权引导：全部完成")
        stop()
        if let window = NSApp.windows.first(where: { $0.identifier == SettingsWindowController.windowID && $0.isVisible }) {
            Foreground.bring(window)
        }
    }

    // MARK: - 浮窗

    private static let size = CGSize(width: 400, height: 92)

    private func showPanel() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: Self.size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: PermissionGuideView(model: model) { [weak self] in
                self?.stop()
            })
            self.panel = panel
        }
        place()
        panel?.orderFrontRegardless()
        followTimer?.invalidate()
        // “系统设置”打开、挪动都要跟着，0.25 秒看一次就够
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.place()
        }
    }

    /// 贴在“系统设置”窗口旁边，不挡住它：先试下边正中，再试右边、左边、上边；都放不下才放进窗口里靠上
    /// （窗口底部是列表的“添加/移除”按钮，不能挡）。还没找到它时放在屏幕下方。
    private func place() {
        guard let panel else { return }
        let size = Self.size
        if let frame = Self.settingsWindowFrame() {
            sawSettingsWindow = true
            let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? frame
            let gap: CGFloat = 12
            let candidates = [
                CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - gap),
                CGPoint(x: frame.maxX + gap, y: frame.midY - size.height / 2),
                CGPoint(x: frame.minX - size.width - gap, y: frame.midY - size.height / 2),
                CGPoint(x: frame.midX - size.width / 2, y: frame.maxY + gap),
            ]
            let origin = candidates.first { visible.contains(CGRect(origin: $0, size: size)) }
                ?? CGPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 60)
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        } else if sawSettingsWindow {
            Log.app.notice("授权引导：系统设置已关闭，引导收起")
            stop()
        } else if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 40))
        }
    }

    /// “系统设置”主窗口在屏幕上的位置（换算成 AppKit 坐标）。读窗口位置不需要录屏权限。
    static func settingsWindowFrame() -> CGRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier,
            let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let frames = infos.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 300, rect.height > 200
            else { return nil }
            return rect
        }
        // 列表从前往后排，第一个就是最前面的窗口
        guard let rect = frames.first, let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - 浮窗内容

struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel
    let close: () -> Void

    private static let appIcon = NSApp.applicationIconImage ?? NSImage()

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(headline)
                        .font(.system(size: 14, weight: .semibold))
                    if model.total > 1 && !model.relaunching {
                        Text("\(model.step)/\(model.total)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !model.granted && !model.relaunching && model.kind.acceptsDrop {
                    Text(L("列表里没有 Mac顺？把左边的图标拖进列表"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(ChipButtonStyle(shape: Circle()))
            .help(L("关闭引导"))
            .padding(8)
        }
    }

    private var headline: String {
        if model.relaunching { return L("重启 Mac顺 后生效") }
        return model.granted ? L("“%@”已开启", model.kind.paneTitle) : L("开启“%@”", model.kind.paneTitle)
    }

    private var detail: String {
        if model.relaunching { return L("macOS 要重启 Mac顺 才会应用新权限，马上就好…") }
        if model.granted { return model.step < model.total ? L("马上进入下一步…") : L("全部完成，Mac顺 可以工作了") }
        return model.kind.instruction
    }

    /// 应用图标，可以拖进“系统设置”的列表。授权成功时换成绿色的勾，重启时换成转圈的箭头。
    @ViewBuilder
    private var icon: some View {
        if model.relaunching {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .transition(.scale.combined(with: .opacity))
        } else if model.granted {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .frame(width: 52, height: 52)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(nsImage: Self.appIcon)
                .resizable()
                .frame(width: 52, height: 52)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                .help(model.kind.acceptsDrop ? L("拖进“系统设置”的列表") : "")
        }
    }
}
