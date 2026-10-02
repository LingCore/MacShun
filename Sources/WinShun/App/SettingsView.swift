// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case keyboard, mouse, clipboard, general
    /// 作者的其他作品，见 Gleaning
    case gleaning

    var id: Self { self }

    /// 侧栏上半部分的设置项，“拾穗”单独放在下面。
    static let settings: [SettingsTab] = [.keyboard, .mouse, .clipboard, .general]

    /// 侧边栏里的名字
    var title: String {
        switch self {
        case .keyboard: "键盘"
        case .mouse: "鼠标"
        case .clipboard: "剪贴板"
        case .general: "通用"
        case .gleaning: Gleaning.title
        }
    }

    /// 页面顶部的标题
    var headline: String {
        switch self {
        case .keyboard: "快捷键像 Windows"
        case .mouse: "鼠标像 Windows"
        case .clipboard: "剪贴板历史"
        case .general: "通用"
        case .gleaning: Gleaning.title
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .general: "gearshape.fill"
        case .gleaning: Gleaning.symbol
        }
    }

    var tint: Color {
        switch self {
        case .keyboard: .blue
        case .mouse: .indigo
        case .clipboard: .orange
        case .general: .gray
        case .gleaning: Gleaning.tint
        }
    }
}

final class SettingsWindowController {
    private let configStore: ConfigStore
    private let state: AppState
    private let clipboard: ClipboardController
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(configStore: ConfigStore, state: AppState, clipboard: ClipboardController) {
        self.configStore = configStore
        self.state = state
        self.clipboard = clipboard
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let root = SettingsView(
                configStore: configStore, state: state,
                clipboardStore: clipboard.store, selection: selection
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Win顺 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("SettingsWindow")
            if !window.setFrameUsingName("SettingsWindow") { window.center() }
            // 窗口关掉、被挡住或最小化时，“拾穗”页的动画停下来。
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [selection] note in
                guard let window = note.object as? NSWindow else { return }
                let visible = window.occlusionState.contains(.visible)
                if selection.windowVisible != visible { selection.windowVisible = visible }
            }
            self.window = window
        }
        if let window { Foreground.bring(window) }
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .keyboard
    /// 设置窗口现在看不看得见
    @Published var windowVisible = true
}

struct SettingsView: View {
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var state: AppState
    let clipboardStore: ClipboardStore
    @ObservedObject var selection: SettingsSelection

    @Environment(\.colorScheme) private var colorScheme

    static let sidebarWidth: CGFloat = 190

    /// 在“拾穗”页时，整个窗口（连同侧栏）铺满暖色场景。
    private var warm: Bool { selection.tab == .gleaning }
    private var palette: WarmPalette { .current(colorScheme) }

    var body: some View {
        // 不用 NavigationSplitView：它在侧栏和内容之间画一条去不掉的分隔线。
        // 侧栏用半透明材质，和右边的底色自然分开。
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
                .background {
                    // 在“拾穗”页侧栏不加任何遮罩，直接铺在场景上。
                    if !warm {
                        VisualEffect(material: .sidebar).ignoresSafeArea()
                    }
                }

            page
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if warm {
                GleaningBackdrop(animating: selection.windowVisible, leadingInset: Self.sidebarWidth).ignoresSafeArea()
            }
        }
        .frame(minWidth: 700, idealWidth: 720, minHeight: 500, idealHeight: 580)
    }

    /// 侧栏自己画：系统侧栏的选中色固定是蓝色，在“拾穗”页要换成暖色。
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.settings) { sidebarButton($0) }
            Spacer().frame(height: 16)
            sidebarButton(.gleaning)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func sidebarButton(_ tab: SettingsTab) -> some View {
        let selected = selection.tab == tab
        return Button {
            selection.tab = tab
        } label: {
            SidebarRow(tab: tab, needsAttention: needsAttention(tab))
                .foregroundStyle(selected ? Color.white : (warm ? palette.ink : Color.primary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? (warm ? AnyShapeStyle(palette.accent.gradient) : AnyShapeStyle(Color.accentColor)) : AnyShapeStyle(Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var page: some View {
        switch selection.tab {
        case .keyboard:
            KeyboardSettings(config: $configStore.config.keyboard, state: state)
        case .mouse:
            MouseSettings(config: $configStore.config.mouse, mice: state.mice, systemSpeed: state.systemPointerSpeed)
        case .clipboard:
            ClipboardSettings(config: $configStore.config.clipboard, store: clipboardStore, state: state)
        case .general:
            GeneralSettings(state: state)
        case .gleaning:
            GleaningPage()
        }
    }

    private func needsAttention(_ tab: SettingsTab) -> Bool {
        switch tab {
        case .general: !state.allGood
        case .clipboard: configStore.config.clipboard.enabled && state.pasteboardAccess != .allowed
        default: false
        }
    }
}

private struct SidebarRow: View {
    let tab: SettingsTab
    let needsAttention: Bool

    var body: some View {
        HStack(spacing: 8) {
            if tab == .gleaning {
                // 拾穗计划用作者的会动的标志；进入拾穗计划页时播一遍；不接收点击，点图标照样是选中这一页
                AuthorMark(size: 22)
                    .allowsHitTesting(false)
            } else {
                IconBadge(symbol: tab.symbol, tint: tab.tint, size: 22)
            }
            Text(tab.title)
            Spacer(minLength: 0)
            if needsAttention {
                Circle()
                    .fill(Color.orange.gradient)
                    .frame(width: 8, height: 8)
                    .help("需要授权")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 键盘

private struct KeyboardSettings: View {
    @Binding var config: KeyboardConfig
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(tab: .keyboard, subtitle: "Ctrl+C/V 复制粘贴，Alt+Tab 切换程序") {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
            }

            Section {
                if state.keyboards.isEmpty {
                    Text("打几个字，用过的键盘就会出现在这里")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.keyboards) { keyboard in
                    LabeledContent {
                        Picker("", selection: layoutBinding(keyboard)) {
                            Text("Windows").tag(KeyboardLayoutKind.windows)
                            Text("Mac").tag(KeyboardLayoutKind.mac)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    } label: {
                        Label(keyboard.name, systemImage: "keyboard")
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("键盘模式")
            } footer: {
                Text("自动识别，一般不用改。键盘切换 Win/Mac 模式后，Win顺 会从你按 Alt+Tab、Alt+F4 的方式自动跟上。")
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section("改写的按键") {
                rule("Ctrl 组合键", "Ctrl+C/V/X/Z/S/A/F 当作 ⌘ 组合键，Ctrl+Y 重做", $config.ctrlAsCommand)
                rule("文字光标", "Home/End 到行首行尾，Ctrl+←/→ 按词移动，Ctrl+Backspace 删词", $config.textNavigation)
                rule("系统快捷键", "Alt+Tab、Alt+F4、Win+E/D/L/S、Win+Space 切换输入法", $config.systemShortcuts)
                rule("Finder", "Ctrl+X 剪切移动文件，F2 重命名，Enter 打开，Delete 删除", $config.finderShortcuts)
                rule("微信、QQ 截图", "Alt+A、Ctrl+Alt+A 截图", $config.chatScreenshot)
            }
            .disabled(!config.enabled)

            Section {
                InfoRow(symbol: "terminal", title: "终端", detail: "Ctrl 组合键保持原样，用 Ctrl+Shift+C/V 复制粘贴")
                InfoRow(symbol: "display.2", title: "远程桌面、虚拟机", detail: "不改写任何按键，例如 ToDesk、向日葵、微软远程桌面、Parallels")
                ExcludedAppsEditor(bundleIDs: $config.excludedApps)
            } header: {
                Text("例外的应用")
            }
            .disabled(!config.enabled)
        }
    }

    private func layoutBinding(_ keyboard: InputDevice) -> Binding<KeyboardLayoutKind> {
        Binding(
            get: { config.layout(for: keyboard) },
            set: { config.layouts[keyboard.key] = $0 }
        )
    }

    private func rule(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }
}

/// 用户自己添加的“不改写按键”的应用。
private struct ExcludedAppsEditor: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        ForEach(bundleIDs, id: \.self) { id in
            HStack(spacing: 10) {
                if let icon = AppInfo.icon(id) {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "app.dashed").frame(width: 22, height: 22).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.name(id)).lineLimit(1)
                    Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    bundleIDs.removeAll { $0 == id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("移除")
            }
        }
        HStack {
            Text("另外不改写按键的应用")
                .foregroundStyle(bundleIDs.isEmpty ? .secondary : .primary)
            Spacer()
            Button("添加应用…", action: addApp)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(id) {
                bundleIDs.append(id)
            }
        }
    }
}

// MARK: - 鼠标

private struct MouseSettings: View {
    @Binding var config: MouseConfig
    let mice: [MouseDevice]
    let systemSpeed: Double

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(tab: .mouse, subtitle: "指针不加速，滚轮方向和手感跟 Windows 一致") {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
            }

            Section {
                DeviceSettingsEditor(settings: $config.defaults, systemSpeed: systemSpeed)
            } header: {
                Text("指针和滚轮")
            } footer: {
                Text("只影响鼠标，触控板和妙控鼠标不受影响。")
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section {
                if mice.isEmpty {
                    Text("没有检测到鼠标（需要“输入监控”权限）")
                        .foregroundStyle(.secondary)
                }
                ForEach(mice) { mouse in
                    let custom = config.devices[mouse.key] != nil
                    Toggle(isOn: customBinding(for: mouse)) {
                        Text(mouse.name)
                        Text(custom ? "单独设置" : "跟上面的设置一样")
                    }
                    if custom {
                        DeviceSettingsEditor(settings: binding(for: mouse), systemSpeed: systemSpeed)
                            .padding(.leading, 28)
                    }
                }
            } header: {
                Text("按鼠标单独设置")
            } footer: {
                Text("接了几个手感不同的鼠标时才需要。")
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section("按键") {
                Toggle(isOn: $config.sideButtons) {
                    Text("侧键前进、后退")
                    Text("鼠标第 4、5 键在所有应用里后退、前进")
                }
                Toggle(isOn: $config.ctrlWheelZoom) {
                    Text("Ctrl+滚轮缩放")
                    Text("在网页、文档、图片里放大缩小")
                }
            }
            .disabled(!config.enabled)
        }
    }

    private func customBinding(for mouse: MouseDevice) -> Binding<Bool> {
        Binding(
            get: { config.devices[mouse.key] != nil },
            set: { on in config.devices[mouse.key] = on ? config.defaults : nil }
        )
    }

    private func binding(for mouse: MouseDevice) -> Binding<MouseDeviceSettings> {
        Binding(
            get: { config.devices[mouse.key] ?? config.defaults },
            set: { config.devices[mouse.key] = $0 }
        )
    }
}

private struct DeviceSettingsEditor: View {
    @Binding var settings: MouseDeviceSettings
    let systemSpeed: Double

    var body: some View {
        Toggle(isOn: $settings.linearPointer) {
            Text("指针不加速")
            Text("指针移动多远只看鼠标移动多远，跟快慢无关")
        }
        LabeledContent {
            HStack(spacing: 8) {
                Text("慢").font(.caption).foregroundStyle(.secondary)
                Slider(value: speedStep, in: 0...Double(PointerSpeed.steps.count - 1), step: 1)
                    .frame(width: 180)
                Text("快").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Text("指针速度")
            HStack(spacing: 6) {
                Text(speedDetail)
                if settings.pointerSpeed != nil {
                    Button("恢复成系统的跟踪速度") { settings.pointerSpeed = nil }
                        .buttonStyle(.link)
                }
            }
        }
        .disabled(!settings.linearPointer)
        Toggle(isOn: $settings.windowsScrollDirection) {
            Text("滚轮方向和 Windows 一致")
            Text("滚轮往下转，内容往上走")
        }
        Toggle(isOn: $settings.linearScroll) {
            Text("按行滚动")
            Text("每转一格滚动固定的行数，没有滚动加速")
        }
        LabeledContent("每格滚动") {
            HStack(spacing: 8) {
                Text("\(settings.scrollLines) 行")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: $settings.scrollLines, in: 1...10)
                    .labelsHidden()
            }
        }
        .disabled(!settings.linearScroll)
    }

    /// 滑块的位置是档位序号，没单独设过速度时停在系统跟踪速度最接近的档位。
    private var speedStep: Binding<Double> {
        Binding(
            get: { Double(PointerSpeed.nearestStep(to: settings.pointerSpeed ?? systemSpeed)) },
            set: { settings.pointerSpeed = PointerSpeed.steps[Int($0.rounded())] }
        )
    }

    private var speedDetail: String {
        guard let speed = settings.pointerSpeed else {
            return "跟系统的跟踪速度一样（\(PointerSpeed.describe(systemSpeed))）"
        }
        return PointerSpeed.describe(speed)
    }
}

// MARK: - 剪贴板

private struct ClipboardSettings: View {
    @Binding var config: ClipboardConfig
    @ObservedObject var store: ClipboardStore
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(tab: .clipboard, subtitle: "按 Win+V 呼出，支持拼音全拼和首字母搜索") {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
                if config.enabled && state.pasteboardAccess != .allowed {
                    PasteboardPermissionRow(status: state.pasteboardAccess)
                }
            }

            Section("记录") {
                Picker("最多保存", selection: $config.maxItems) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { Text("\($0) 条").tag($0) }
                }
                Toggle(isOn: $config.recordImages) {
                    Text("记录图片")
                    Text("截图、复制的图片")
                }
                LabeledContent("已保存") {
                    let pinned = store.items.filter(\.pinned).count
                    Text(pinned > 0 ? "\(store.items.count) 条，其中固定 \(pinned) 条" : "\(store.items.count) 条")
                        .monospacedDigit()
                }
            }
            .disabled(!config.enabled)

            Section {
                InfoRow(
                    symbol: "lock.shield",
                    title: "只保存在这台电脑上",
                    detail: "不联网，不需要账号。密码管理器标记为隐藏的内容、在 Finder 里复制的文件都不记录。"
                )
                HStack {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                    }
                    Spacer()
                    Button("清空历史…", role: .destructive, action: confirmClear)
                        .disabled(store.items.allSatisfy(\.pinned))
                }
            } header: {
                Text("隐私")
            }
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史？"
        alert.informativeText = "固定的条目会保留。清空后不能恢复。"
        alert.addButton(withTitle: "清空").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                SettingsPageHeader(
                    tab: .general,
                    subtitle: state.allGood ? "已经授权，Win顺 正在工作" : "还需要授权，Win顺 才能工作"
                ) {
                    Image(systemName: state.allGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(state.allGood ? .green : .orange)
                }
            }

            Section {
                PermissionRow(
                    symbol: "accessibility",
                    title: "辅助功能",
                    detail: "改写按键、粘贴、找到文字光标的位置",
                    granted: state.accessibilityGranted,
                    request: {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
                PermissionRow(
                    symbol: "keyboard",
                    title: "输入监控",
                    detail: "识别是哪个鼠标、哪把键盘在输入",
                    granted: state.inputMonitoringGranted,
                    request: {
                        Permissions.requestInputMonitoring()
                        Permissions.openInputMonitoringSettings()
                    }
                )
                PasteboardPermissionRow(status: state.pasteboardAccess)
                if state.accessibilityGranted && !state.eventTapRunning {
                    Label("已经授权但还没生效，请重新启动 Win顺。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("权限")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("在“系统设置 → 隐私与安全性”里打开 Win顺 的开关，一般马上生效。")
                        .settingsFooter()
                    Spacer()
                    Button("重新启动 Win顺") { AppState.relaunch() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Section {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
            }

            Section {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")
            } footer: {
                Text("Windows 是微软公司的商标，Mac 是苹果公司的商标。本程序与微软、苹果没有任何关联。")
                    .settingsFooter()
            }
        }
    }
}

private struct PasteboardPermissionRow: View {
    let status: PasteboardAccess.Status

    var body: some View {
        PermissionRow(
            symbol: "doc.on.clipboard",
            title: "读取剪贴板",
            detail: status == .denied
                ? "已被拒绝。请在“粘贴”设置里把 Win顺 改成“始终允许”"
                : "在“粘贴”设置里设为“始终允许”，复制时才不会每次弹出询问",
            granted: status == .allowed,
            request: { PasteboardAccess.request() }
        )
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(granted ? Color.secondary : Color.orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("去授权", action: request)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
