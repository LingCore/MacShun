// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case keyboard, mouse, clipboard, fileSearch, window, display, general
    /// 作者的其他作品，见 Gleaning
    case gleaning

    var id: Self { self }

    /// 侧栏上半部分的设置项，“拾穗”单独放在下面。
    static let settings: [SettingsTab] = [.keyboard, .mouse, .clipboard, .fileSearch, .window, .display, .general]

    /// 侧边栏里的名字
    var title: String {
        switch self {
        case .keyboard: L("键盘")
        case .mouse: L("鼠标")
        case .clipboard: L("剪贴板")
        case .fileSearch: L("文件搜索")
        case .window: L("分屏")
        case .display: L("显示器")
        case .general: L("通用")
        case .gleaning: Gleaning.title
        }
    }

    /// 页面顶部的标题
    var headline: String {
        switch self {
        case .keyboard: L("快捷键像 Windows")
        case .mouse: L("鼠标像 Windows")
        case .clipboard: L("剪贴板历史")
        case .fileSearch: L("文件搜索")
        case .window: L("分屏像 Windows")
        case .display: L("显示器缩放和刷新率")
        case .general: L("通用")
        case .gleaning: Gleaning.title
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .fileSearch: "doc.text.magnifyingglass"
        case .window: "rectangle.split.2x1.fill"
        case .display: "display"
        case .general: "gearshape.fill"
        case .gleaning: Gleaning.symbol
        }
    }

    var tint: Color {
        switch self {
        case .keyboard: .blue
        case .mouse: .indigo
        case .clipboard: .orange
        case .fileSearch: .green
        case .window: .purple
        case .display: .teal
        case .general: .gray
        case .gleaning: Gleaning.tint
        }
    }
}

final class SettingsWindowController {
    /// 设置窗口的标识。标题会随语言变，找这个窗口时用它
    static let windowID = NSUserInterfaceItemIdentifier("WinShunSettings")

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
            let window = NSWindow(contentViewController: NSHostingController(rootView: root.environmentObject(selection)))
            window.title = L("Win顺 设置")
            window.identifier = SettingsWindowController.windowID
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
            // ⌘F 到侧栏的搜索框
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
                guard event.window === window, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "f", let field = SettingsSearchField.current
                else { return event }
                window?.makeFirstResponder(field)
                return nil
            }
        }
        if let window { Foreground.bring(window) }
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .keyboard
    /// 设置窗口现在看不看得见
    @Published var windowVisible = true
    /// 侧栏搜索框里的文字；不为空时侧栏显示搜索结果
    @Published var query = ""
    /// 搜索结果里点开的那一项
    @Published var opened: SettingsItem.ID?
    /// 要滚过去并闪一下的那一项
    @Published var highlight: SettingsItem.ID?

    func open(_ item: SettingsItem) {
        tab = item.tab
        opened = item.id
        highlight = item.id
        // 高亮闪一下就收
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.highlight == item.id { self?.highlight = nil }
        }
    }
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
            SettingsSearchField(selection: selection, warm: warm) {
                if let first = searchResults.first { selection.open(first) }
            }
            // 去掉系统边框后框会变矮，固定高度，换页时侧栏不跳
            .frame(height: 26)
            .background {
                if warm {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.chip)
                }
            }
            .padding(.bottom, 8)
            if selection.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(SettingsTab.settings) { sidebarButton($0) }
                Spacer().frame(height: 16)
                sidebarButton(.gleaning)
            } else {
                SettingsSearchResults(selection: selection, results: searchResults, warm: warm, palette: palette) {
                    selection.open($0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var searchResults: [SettingsItem] {
        Array(SettingsItem.search(selection.query).prefix(12))
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
            MouseSettings(
                config: $configStore.config.mouse, mice: state.mice,
                systemSpeed: state.systemPointerSpeed, systemCursorScale: state.systemCursorScale
            )
        case .clipboard:
            ClipboardSettings(config: $configStore.config.clipboard, store: clipboardStore, state: state)
        case .fileSearch:
            FileSearchSettings(config: $configStore.config.fileSearch, index: FileIndex.shared, contentIndex: ContentIndex.shared)
        case .window:
            WindowSettings(config: $configStore.config.window, tiling: NativeTilingStatus.shared)
        case .display:
            DisplaySettings(model: DisplayScalingModel.shared)
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
                    .help(L("需要授权"))
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
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .keyboard, subtitle: L("Ctrl+C/V 复制粘贴，Alt+Tab 切换程序")) {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
                .settingsAnchor(.keyboardEnabled)
            }

            Section {
                if state.keyboards.isEmpty {
                    Text(L("打几个字，用过的键盘就会出现在这里"))
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
                Text(L("键盘模式")).settingsAnchor(.keyboardMode)
            } footer: {
                Text(L("自动识别，一般不用改。键盘切换 Win/Mac 模式后，Win顺 会从你按 Alt+Tab、Alt+F4 的方式自动跟上。"))
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section(L("改写的按键")) {
                rule(L("Ctrl 组合键"), L("Ctrl+C/V/X/Z/S/A/F 当作 ⌘ 组合键，Ctrl+Y 重做"), $config.ctrlAsCommand).settingsAnchor(.ctrlAsCommand)
                rule(L("文字光标"), L("Home/End 到行首行尾，Ctrl+←/→ 按词移动，Ctrl+Backspace 删词"), $config.textNavigation).settingsAnchor(.textNavigation)
                rule(L("系统快捷键"), L("Alt+Tab、Alt+F4、Win+E/D/L/S、Win+Space 切换输入法"), $config.systemShortcuts).settingsAnchor(.systemShortcuts)
                rule("Finder", L("Ctrl+X 剪切移动文件，F2 重命名，Enter 打开，Delete 删除"), $config.finderShortcuts).settingsAnchor(.finderShortcuts)
                rule(L("微信、QQ 截图"), L("Alt+A、Ctrl+Alt+A 截图"), $config.chatScreenshot).settingsAnchor(.chatScreenshot)
            }
            .disabled(!config.enabled)

            Section {
                InfoRow(symbol: "terminal", title: L("终端"), detail: L("Ctrl 组合键保持原样，用 Ctrl+Shift+C/V 复制粘贴"))
                    .settingsAnchor(.terminal)
                InfoRow(symbol: "display.2", title: L("远程桌面、虚拟机"), detail: L("不改写任何按键，例如 ToDesk、向日葵、微软远程桌面、Parallels"))
                    .settingsAnchor(.remoteDesktop)
                ExcludedAppsEditor(bundleIDs: $config.excludedApps)
            } header: {
                Text(L("例外的应用"))
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
                .help(L("移除"))
            }
        }
        HStack {
            Text(L("另外不改写按键的应用")).settingsAnchor(.excludedApps)
                .foregroundStyle(bundleIDs.isEmpty ? .secondary : .primary)
            Spacer()
            Button(L("添加应用…"), action: addApp)
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
    let systemCursorScale: Double

    var body: some View {
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .mouse, subtitle: L("指针不加速，滚轮方向和手感跟 Windows 一致")) {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
                .settingsAnchor(.mouseEnabled)
            }

            Section {
                DeviceSettingsEditor(settings: $config.defaults, systemSpeed: systemSpeed, searchable: true)
            } header: {
                Text(L("指针和滚轮"))
            } footer: {
                Text(L("只影响鼠标，触控板和妙控鼠标不受影响。"))
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section(L("光标")) {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(L("小")).font(.caption).foregroundStyle(.secondary)
                        Slider(value: cursorScale, in: CursorSizeController.range, step: 0.25)
                            .frame(width: 180)
                        Text(L("大")).font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text(L("光标大小"))
                    HStack(spacing: 6) {
                        Text(cursorDetail)
                        if config.cursorScale != nil {
                            Button(L("恢复成系统的指针大小")) { config.cursorScale = nil }
                                .buttonStyle(.link)
                        }
                    }
                }
                .settingsAnchor(.cursorSize)
            }
            .disabled(!config.enabled)

            Section {
                if mice.isEmpty {
                    Text(L("没有检测到鼠标（需要“输入监控”权限）"))
                        .foregroundStyle(.secondary)
                }
                ForEach(mice) { mouse in
                    let custom = config.devices[mouse.key] != nil
                    Toggle(isOn: customBinding(for: mouse)) {
                        Text(mouse.name)
                        Text(custom ? L("单独设置") : L("跟上面的设置一样"))
                    }
                    if custom {
                        DeviceSettingsEditor(settings: binding(for: mouse), systemSpeed: systemSpeed)
                            .padding(.leading, 28)
                    }
                }
            } header: {
                Text(L("按鼠标单独设置")).settingsAnchor(.perMouse)
            } footer: {
                Text(L("接了几个手感不同的鼠标时才需要。"))
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section(L("按键")) {
                Toggle(isOn: $config.sideButtons) {
                    Text(L("侧键前进、后退"))
                    Text(L("鼠标第 4、5 键在所有应用里后退、前进"))
                }
                .settingsAnchor(.sideButtons)
                Toggle(isOn: $config.ctrlWheelZoom) {
                    Text(L("Ctrl+滚轮缩放"))
                    Text(L("在网页、文档、图片里放大缩小"))
                }
                .settingsAnchor(.ctrlWheelZoom)
            }
            .disabled(!config.enabled)
        }
    }

    /// 没单独设过时，滑块停在系统设置的指针大小上
    private var cursorScale: Binding<Double> {
        Binding(
            get: { config.cursorScale ?? systemCursorScale },
            set: { config.cursorScale = abs($0 - systemCursorScale) < 0.01 ? nil : $0 }
        )
    }

    private var cursorDetail: String {
        guard let scale = config.cursorScale else {
            return L("跟系统的指针大小一样（%@）", PointerSpeed.describe(systemCursorScale))
        }
        return PointerSpeed.describe(scale)
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
    /// 默认那一组能被搜索跳到；按鼠标单独设置的几组不能（不然同一项有好几处）
    var searchable = false

    private func anchor(_ id: SettingsItem.ID) -> SettingsItem.ID? { searchable ? id : nil }

    var body: some View {
        Toggle(isOn: $settings.linearPointer) {
            Text(L("指针不加速"))
            Text(L("指针移动多远只看鼠标移动多远，跟快慢无关"))
        }
        .settingsAnchor(anchor(.linearPointer))
        LabeledContent {
            HStack(spacing: 8) {
                Text(L("慢")).font(.caption).foregroundStyle(.secondary)
                Slider(value: speedStep, in: 0...Double(PointerSpeed.steps.count - 1), step: 1)
                    .frame(width: 180)
                Text(L("快")).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Text(L("指针速度"))
            HStack(spacing: 6) {
                Text(speedDetail)
                if settings.pointerSpeed != nil {
                    Button(L("恢复成系统的跟踪速度")) { settings.pointerSpeed = nil }
                        .buttonStyle(.link)
                }
            }
        }
        .disabled(!settings.linearPointer)
        .settingsAnchor(anchor(.pointerSpeed))
        Toggle(isOn: $settings.windowsScrollDirection) {
            Text(L("滚轮方向和 Windows 一致"))
            Text(L("滚轮往下转，内容往上走"))
        }
        .settingsAnchor(anchor(.scrollDirection))
        Toggle(isOn: $settings.linearScroll) {
            Text(L("按行滚动"))
            Text(L("每转一格滚动固定的行数，没有滚动加速"))
        }
        .settingsAnchor(anchor(.linearScroll))
        LabeledContent(L("每格滚动")) {
            HStack(spacing: 8) {
                Text(L("%ld 行", settings.scrollLines))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper("", value: $settings.scrollLines, in: 1...10)
                    .labelsHidden()
            }
        }
        .disabled(!settings.linearScroll)
        .settingsAnchor(anchor(.scrollLines))
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
            return L("跟系统的跟踪速度一样（%@）", PointerSpeed.describe(systemSpeed))
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
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .clipboard, subtitle: L("按 Win+V 呼出，支持拼音全拼和首字母搜索")) {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
                .settingsAnchor(.clipboardEnabled)
                if config.enabled && state.pasteboardAccess != .allowed {
                    PasteboardPermissionRow(state: state)
                }
            }

            Section(L("记录")) {
                Picker(L("最多保存"), selection: $config.maxItems) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { Text(L("%ld 条", $0)).tag($0) }
                }
                .settingsAnchor(.maxItems)
                Toggle(isOn: $config.recordImages) {
                    Text(L("记录图片"))
                    Text(L("截图、复制的图片"))
                }
                .settingsAnchor(.recordImages)
                LabeledContent(L("已保存")) {
                    let pinned = store.items.filter(\.pinned).count
                    Text(pinned > 0 ? L("%ld 条，其中固定 %ld 条", store.items.count, pinned) : L("%ld 条", store.items.count))
                        .monospacedDigit()
                }
            }
            .disabled(!config.enabled)

            Section {
                InfoRow(
                    symbol: "lock.shield",
                    title: L("只保存在这台电脑上"),
                    detail: L("不联网，不需要账号。密码管理器标记为隐藏的内容、在 Finder 里复制的文件都不记录。")
                )
                .settingsAnchor(.clipboardPrivacy)
                HStack {
                    Button(L("在 Finder 中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
                    }
                    .settingsAnchor(.showInFinder)
                    Spacer()
                    Button(L("清空历史…"), role: .destructive, action: confirmClear)
                        .disabled(store.items.allSatisfy(\.pinned))
                        .settingsAnchor(.clearHistory)
                }
            } header: {
                Text(L("隐私"))
            }
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = L("清空剪贴板历史？")
        alert.informativeText = L("固定的条目会保留。清空后不能恢复。")
        alert.addButton(withTitle: L("清空")).hasDestructiveAction = true
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }
}

// MARK: - 文件搜索

private struct FileSearchSettings: View {
    @Binding var config: FileSearchConfig
    @ObservedObject var index: FileIndex
    @ObservedObject var contentIndex: ContentIndex

    var body: some View {
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .fileSearch, subtitle: L("连按两下 Ctrl 按文件名或内容搜索电脑里的文件，像 Everything 一样快，文件名支持拼音首字母")) {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
                .settingsAnchor(.fileSearchEnabled)
            }

            Section(L("使用")) {
                LabeledContent(L("呼出")) {
                    HStack(spacing: 10) {
                        Text(L("连按两下 Ctrl")).foregroundStyle(.secondary)
                        Button(L("现在试试")) {
                            NotificationCenter.default.post(name: .openFileSearch, object: nil)
                        }
                    }
                }
                InfoRow(
                    symbol: "keyboard",
                    title: L("Enter 打开，Ctrl+Enter 在访达中显示"),
                    detail: L("用空格分开几个词，可以同时匹配，例如 “报告 2026”。")
                )
            }
            .disabled(!config.enabled)

            Section {
                LabeledContent(L("已收录")) {
                    HStack(spacing: 8) {
                        if index.isIndexing || index.isScanningDrives { ProgressView().controlSize(.small) }
                        Text(indexSummary).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .settingsAnchor(.fileIndex)
                if !index.deniedFolders.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        InfoRow(
                            symbol: "exclamationmark.triangle",
                            title: L("搜不到“%@”里的文件", index.deniedFolders.joined(separator: L("、"))),
                            detail: L("系统询问时选了“不允许”。到“隐私与安全性 → 文件与文件夹”里给 Win顺 打开，再重新建立索引。")
                        )
                        Spacer()
                        Button(L("打开系统设置")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(L("重新建立索引")) { index.rebuild() }
                        .disabled(index.isIndexing || !config.activated)
                }
            } header: {
                Text(L("索引"))
            }
            .disabled(!config.enabled)

            Section {
                Toggle(isOn: $config.searchContents) {
                    Text(L("搜索文件内容"))
                    Text(L("文本、代码、配置、字幕，以及 Word、Excel、PowerPoint、PDF 里的文字"))
                }
                .settingsAnchor(.fileContents)
                if config.searchContents {
                    LabeledContent(L("已读取")) {
                        HStack(spacing: 8) {
                            if config.activated && contentIndex.pendingCount > 0 { ProgressView().controlSize(.small) }
                            Text(contentSummary).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    InfoRow(
                        symbol: "lock",
                        title: L("内容索引只保存在这台电脑上"),
                        detail: L("每个文件最多收录前 512 KB 文字（JSON 128 KB），PDF 只读前 100 页；太大的文件和 iCloud 里还没下载的文件不读。关掉后索引会删除。")
                    )
                }
            } header: {
                Text(L("文件内容"))
            } footer: {
                Text(L("搜索框默认只搜文件名，在右边选“全部”或“内容”（或按 Tab）才按内容搜。要搜中文，切换到中文输入法就能打字；至少输入两个汉字或三个字母才会搜内容。"))
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section {
                InfoRow(
                    symbol: "folder",
                    title: L("个人文件夹和应用程序"),
                    detail: L("不包括“资源库”、隐藏文件和应用程序包里的内容。文件名索引只放在内存里，不联网。")
                )
                Toggle(isOn: $config.includeExternalDrives) {
                    Text(L("包括外接硬盘"))
                    Text(L("在后台慢慢扫描，不影响搜索。不收录 Windows 的系统文件夹。"))
                }
                .settingsAnchor(.externalDrives)
            } header: {
                Text(L("搜索范围"))
            }
            .disabled(!config.enabled)
        }
    }

    private var indexSummary: String {
        if index.isIndexing { return L("正在建立索引…") }
        if !config.activated || index.lastIndexed == nil { return L("第一次呼出时开始建立") }
        let count = L("%ld 个文件和文件夹", index.fileCount)
        return index.isScanningDrives ? L("%@，正在扫描外接硬盘…", count) : count
    }

    private var contentSummary: String {
        if !config.activated { return L("第一次呼出时开始读取") }
        let size = ByteCountFormatter.string(fromByteCount: contentIndex.diskSize, countStyle: .file)
        if contentIndex.pendingCount > 0 {
            return L("%ld 个文件，还有 %ld 个在读…", contentIndex.documentCount, contentIndex.pendingCount)
        }
        return L("%ld 个文件，占用 %@", contentIndex.documentCount, size)
    }
}

extension Notification.Name {
    /// 设置里点“现在试试”，打开文件搜索
    static let openFileSearch = Notification.Name("WinShun.openFileSearch")
}

// MARK: - 分屏

/// 系统自带的拖动分屏开没开。设置页打开时刷新（用户可能刚在系统设置里改过）。
final class NativeTilingStatus: ObservableObject {
    static let shared = NativeTilingStatus()
    @Published private(set) var conflicting = NativeTiling.dragTilingEnabled

    func refresh() {
        let value = NativeTiling.dragTilingEnabled
        if value != conflicting { conflicting = value }
    }

    func disable() {
        NativeTiling.disableDragTiling()
        refresh()
    }
}

private struct WindowSettings: View {
    @Binding var config: WindowConfig
    @ObservedObject var tiling: NativeTilingStatus

    var body: some View {
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .window, subtitle: L("Win+方向键分屏，拖到屏幕边缘分屏，分好一半后帮你挑另一半")) {
                    Toggle("", isOn: $config.enabled).labelsHidden()
                }
                .settingsAnchor(.windowSnap)
            }

            Section(L("快捷键")) {
                shortcut("Win + ←  /  →", L("分到左半边、右半边"), L("再按一次移到隔壁屏幕，按反方向恢复原来的大小"))
                shortcut("Win + ↑", L("最大化"), L("分在半边时，变成上面的四分之一"))
                shortcut("Win + ↓", L("恢复、最小化"), L("分在半边时，变成下面的四分之一"))
                shortcut("Win + Shift + ←  /  →", L("移到另一块屏幕"), L("分好的照样分好，没分的放在差不多的位置"))
                shortcut("Win + Shift + ↑", L("拉到和屏幕一样高"), L("宽度和左右位置不变"))
            }
            .disabled(!config.enabled)

            Section {
                Toggle(isOn: $config.dragToSnap) {
                    Text(L("拖到屏幕边缘分屏"))
                    Text(L("拖到左右边分到半边，拖到上边最大化，拖到四个角分到四分之一；拖动分着屏的窗口，会恢复原来的大小"))
                }
                .settingsAnchor(.dragToSnap)
                if config.dragToSnap && tiling.conflicting {
                    HStack(alignment: .firstTextBaseline) {
                        InfoRow(
                            symbol: "exclamationmark.triangle",
                            title: L("系统自带的拖动分屏也开着"),
                            detail: L("两个一起会打架，现在拖动时用的是系统的，不会弹出贴靠助手。关掉系统的就好，Win+方向键不受影响。")
                        )
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Button(L("关掉系统的拖动分屏")) { tiling.disable() }
                            Button(L("打开系统设置")) { NativeTiling.openSystemSettings() }
                                .buttonStyle(.link)
                        }
                    }
                }
                Toggle(isOn: $config.snapAssist) {
                    Text(L("贴靠助手"))
                    Text(L("分好一半后，在另一半列出其他窗口，点一个就放进去；也可以用方向键和 Enter 选，Esc 跳过"))
                }
                .settingsAnchor(.snapAssist)
            } header: {
                Text(L("拖动和贴靠"))
            }
            .disabled(!config.enabled)
        }
        .onAppear { tiling.refresh() }
    }

    private func shortcut(_ keys: String, _ title: String, _ detail: String) -> some View {
        LabeledContent {
            Text(verbatim: keys)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - 显示器

private struct DisplaySettings: View {
    @ObservedObject var model: DisplayScalingModel

    var body: some View {
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .display, subtitle: L("每块屏幕单独设置缩放和刷新率，缩放像 Windows 那样按百分比选"))
            }

            if model.displays.isEmpty {
                Section {
                    Text(L("没有找到显示器")).foregroundStyle(.secondary)
                }
            }

            ForEach(Array(model.displays.enumerated()), id: \.element.id) { position, display in
                Section {
                    Picker(selection: selection(for: display)) {
                        if display.currentOption == nil {
                            Text(L("现在：看起来像 %@（不清晰）", Self.size(display.current.width, display.current.height)))
                                .tag(String?.none)
                        }
                        ForEach(display.options) { option in
                            Text(L("%ld%%（看起来像 %@）", option.percent, Self.size(option.mode.width, option.mode.height)))
                                .tag(Optional(option.id))
                        }
                    } label: {
                        Text(L("缩放"))
                        Text(L("越大，文字和图标越大"))
                    }
                    .settingsAnchor(position == 0 ? .displayScale : nil)
                    if display.refreshOptions.count > 1 {
                        Picker(selection: refreshSelection(for: display)) {
                            if display.currentRefresh == nil {
                                Text(verbatim: display.current.refreshRate > 0 ? DisplayScaling.label(forRefresh: display.current.refreshRate) : "—")
                                    .tag(String?.none)
                            }
                            ForEach(display.refreshOptions) { option in
                                Text(verbatim: option.label).tag(Optional(option.id))
                            }
                        } label: {
                            Text(L("刷新率"))
                            Text(L("越高，画面和鼠标越流畅"))
                        }
                        // 主显示器可能没有刷新率可选（例如内建屏幕），搜索时跳到第一个能选的
                        .settingsAnchor(position == model.displays.firstIndex(where: { $0.refreshOptions.count > 1 }) ? .refreshRate : nil)
                    }
                    LabeledContent(L("屏幕分辨率")) {
                        Group {
                            if display.refreshOptions.count == 1, let only = display.refreshOptions.first {
                                // 只有一个刷新率，不给选，顺便写在这里
                                Text(L("%@，%@", Self.size(display.nativeWidth, display.nativeHeight), only.label))
                            } else {
                                Text(verbatim: Self.size(display.nativeWidth, display.nativeHeight))
                            }
                        }
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(display.isMain ? L("%@（主显示器）", display.name) : display.name)
                } footer: {
                    if display.options.count <= 2 {
                        Text(L("这块屏幕不是高分屏，macOS 只给它 100% 和 200% 两个清晰的档位，其他档位文字会发虚，所以没有列出。"))
                            .settingsFooter()
                    }
                }
            }

            Section {
                InfoRow(
                    symbol: "info.circle",
                    title: L("和系统设置里改分辨率、刷新率一样"),
                    detail: L("只列出文字清晰的档位。改动会一直保留，退出 Win顺 也不会恢复。")
                )
            }
        }
        .onAppear { model.refresh() }
    }

    /// 分辨率不加千位分隔符：1920 × 1080
    private static func size(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }

    private func selection(for display: DisplayInfo) -> Binding<String?> {
        Binding(
            get: { display.currentOption?.id },
            set: { id in
                guard let option = display.options.first(where: { $0.id == id }) else { return }
                model.select(option, for: display)
            }
        )
    }

    private func refreshSelection(for display: DisplayInfo) -> Binding<String?> {
        Binding(
            get: { display.currentRefresh?.id },
            set: { id in
                guard let option = display.refreshOptions.first(where: { $0.id == id }) else { return }
                model.select(option, for: display)
            }
        )
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @ObservedObject var state: AppState

    /// 还没授权的几项，按页面上的顺序
    private var missingPermissions: [PermissionKind] {
        PermissionKind.allCases.filter { !$0.isGranted(state) }
    }

    var body: some View {
        SearchableForm {
            Section {
                SettingsPageHeader(
                    tab: .general,
                    subtitle: state.allGood ? L("已经授权，Win顺 正在工作") : L("还需要授权，Win顺 才能工作")
                ) {
                    if missingPermissions.isEmpty {
                        Image(systemName: state.allGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(state.allGood ? .green : .orange)
                    } else {
                        // 一项一项带着用户去“系统设置”里打开，每开好一项自动进入下一项
                        Button(L("一键授权")) {
                            PermissionGuide.shared.start(missingPermissions, state: state)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .settingsAnchor(.grantAll)
            }

            Section {
                PermissionRow(
                    symbol: "accessibility",
                    // 和“系统设置”里的名字一致：macOS 27 起叫“设备控制和数据访问”
                    title: PermissionKind.accessibility.paneTitle,
                    detail: L("改写按键、粘贴、找到文字光标的位置"),
                    granted: state.accessibilityGranted,
                    request: { PermissionGuide.shared.start([.accessibility], state: state) }
                )
                .settingsAnchor(.accessibility)
                PermissionRow(
                    symbol: "keyboard",
                    title: L("输入监控"),
                    detail: PermissionKind.accessibilityCoversInputMonitoring
                        ? L("识别是哪个鼠标、哪把键盘在输入，随“%@”一起开启", PermissionKind.accessibility.paneTitle)
                        : L("识别是哪个鼠标、哪把键盘在输入"),
                    granted: state.inputMonitoringGranted,
                    // macOS 27：开了辅助功能就只差重启
                    actionTitle: PermissionKind.accessibilityCoversInputMonitoring && state.accessibilityGranted
                        ? L("重启生效") : L("去授权"),
                    request: { PermissionGuide.shared.start([.inputMonitoring], state: state) }
                )
                .settingsAnchor(.inputMonitoring)
                PasteboardPermissionRow(state: state)
                    .settingsAnchor(.pasteboardPermission)
                if state.accessibilityGranted && !state.eventTapRunning {
                    Label(L("已经授权但还没生效，请重新启动 Win顺。"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L("权限"))
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("在“系统设置 → 隐私与安全性”里打开 Win顺 的开关，一般马上生效。"))
                        .settingsFooter()
                    Spacer()
                    Button(L("重新启动 Win顺")) { AppState.relaunch() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .settingsAnchor(.relaunch)
                }
            }

            Section {
                Toggle(L("登录时自动启动"), isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                .settingsAnchor(.launchAtLogin)
                Picker(L("语言"), selection: Binding(
                    get: { AppLanguage.current },
                    set: { language in
                        guard language != AppLanguage.current else { return }
                        language.apply()
                        AppState.relaunch(showSettings: true)
                    }
                )) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .settingsAnchor(.language)
            } footer: {
                Text(L("切换语言后 Win顺 会自动重启。"))
                    .settingsFooter()
            }

            Section {
                LabeledContent(L("版本"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("开发版"))
                    .settingsAnchor(.version)
            } footer: {
                Text(L("Windows 是微软公司的商标，Mac 是苹果公司的商标。本程序与微软、苹果没有任何关联。"))
                    .settingsFooter()
            }
        }
    }
}

private struct PasteboardPermissionRow: View {
    @ObservedObject var state: AppState
    private var status: PasteboardAccess.Status { state.pasteboardAccess }

    var body: some View {
        PermissionRow(
            symbol: "doc.on.clipboard",
            title: L("读取剪贴板"),
            detail: status == .denied
                ? L("已被拒绝。请在“粘贴”设置里把 Win顺 改成“始终允许”")
                : L("记录剪贴板历史，复制时不再每次弹出询问"),
            granted: status == .allowed,
            request: { PermissionGuide.shared.start([.pasteboard], state: state) }
        )
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    var actionTitle = L("去授权")
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
                Label(L("已授权"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button(actionTitle, action: request)
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
