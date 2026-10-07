// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation

/// 键盘的布局，看紧挨空格键左边的键发出什么（K8）。
enum KeyboardLayoutKind: String, Codable, CaseIterable, Identifiable {
    /// 那个键发出 ⌥：普通模式的 Windows 键盘。Ctrl 键 = control，Win 键 = command，Alt 键 = option。
    case windows
    /// 那个键发出 ⌘：Mac 键盘，或切到 Mac 模式的 Windows 键盘。
    /// 按位置对应：control = Ctrl，option = Win，command（紧挨空格）= Alt。
    case mac

    var id: String { rawValue }
}

struct KeyboardConfig: Codable, Equatable {
    var enabled = true
    var layout: KeyboardLayoutKind = .windows
    /// K1：Ctrl+键 当作 ⌘+键
    var ctrlAsCommand = true
    /// K2：Home/End、Ctrl+←/→ 等文字光标移动
    var textNavigation = true
    /// K3：Alt+Tab、Alt+F4、Win+E/D/L/S
    var systemShortcuts = true
    /// K4：Finder 里的剪切移动、F2、Enter、Delete、Backspace
    var finderShortcuts = true
    /// K9：微信、QQ 运行时，Alt+A、Ctrl+Alt+A 换成它们的截图快捷键 ⌃⌘A
    var chatScreenshot = true
    /// 每把键盘的布局，键是 InputDevice.key。没识别过的键盘用上面的 `layout`。
    var layouts: [String: KeyboardLayoutKind] = [:]
    /// 从按法自动学习键盘的 Win/Mac 模式（见 LayoutInference）
    var autoDetectLayout = true
    /// 用户自己加的“不改写按键”的应用（应用标识）。内置名单见 AppCatalog。
    var excludedApps: [String] = []

    init() {}

    /// 某把键盘用哪种布局：学到过的按记录；苹果键盘一定是 ⌘ 紧挨空格；其他用默认值。
    func layout(for device: InputDevice?) -> KeyboardLayoutKind {
        guard let device else { return layout }
        if let known = layouts[device.key] { return known }
        return device.isApple ? .mac : layout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeyboardConfig()
        enabled = c.value(.enabled, default: d.enabled)
        layout = c.value(.layout, default: d.layout)
        ctrlAsCommand = c.value(.ctrlAsCommand, default: d.ctrlAsCommand)
        textNavigation = c.value(.textNavigation, default: d.textNavigation)
        systemShortcuts = c.value(.systemShortcuts, default: d.systemShortcuts)
        finderShortcuts = c.value(.finderShortcuts, default: d.finderShortcuts)
        chatScreenshot = c.value(.chatScreenshot, default: d.chatScreenshot)
        layouts = c.value(.layouts, default: d.layouts)
        autoDetectLayout = c.value(.autoDetectLayout, default: d.autoDetectLayout)
        excludedApps = c.value(.excludedApps, default: d.excludedApps)
    }
}

/// 一个鼠标的设置（M1–M3）。
struct MouseDeviceSettings: Codable, Equatable {
    /// M1：指针没有加速
    var linearPointer = true
    /// M1：指针速度，指针移动距离是鼠标移动计数的几倍（只在没有加速时有效）。
    /// nil 表示和“系统设置 → 鼠标 → 跟踪速度”一样。
    var pointerSpeed: Double?
    /// M2：滚轮方向和 Windows 一致
    var windowsScrollDirection = true
    /// M3：滚轮按行滚动，没有滚动加速
    var linearScroll = true
    /// M3：每格滚动的行数，Windows 默认 3 行
    var scrollLines = 3

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MouseDeviceSettings()
        linearPointer = c.value(.linearPointer, default: d.linearPointer)
        pointerSpeed = c.value(.pointerSpeed, default: d.pointerSpeed).map(PointerSpeed.clamp)
        windowsScrollDirection = c.value(.windowsScrollDirection, default: d.windowsScrollDirection)
        linearScroll = c.value(.linearScroll, default: d.linearScroll)
        scrollLines = min(max(c.value(.scrollLines, default: d.scrollLines), 1), 20)
    }
}

/// 指针速度滑块的档位。系统设置最快是 3 倍，这里放到 8 倍，给低 DPI 的鼠标留余地。
enum PointerSpeed {
    static let steps: [Double] = [0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4, 5, 6, 8]

    static func clamp(_ value: Double) -> Double {
        min(max(value, steps[0]), steps[steps.count - 1])
    }

    /// 最接近的档位。
    static func nearestStep(to value: Double) -> Int {
        steps.indices.min { abs(steps[$0] - value) < abs(steps[$1] - value) } ?? 0
    }

    /// 界面上显示的倍数，例如 “1.5 倍”。
    static func describe(_ value: Double) -> String {
        let text = String(format: "%.3f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return L("%@ 倍", text)
    }
}

struct MouseConfig: Codable, Equatable {
    var enabled = true
    /// 没有单独设置过的鼠标使用这一组设置。
    var defaults = MouseDeviceSettings()
    /// 按设备单独的设置，键是 InputDevice.key。
    var devices: [String: MouseDeviceSettings] = [:]
    /// M4：侧键（第 4 键后退键、第 5 键前进键）做什么
    var backButton = SideButtonSetting(.back)
    var forwardButton = SideButtonSetting(.forward)
    /// M5：Ctrl+滚轮缩放
    var ctrlWheelZoom = true
    /// M6：光标大小，1 到 4 倍。nil 表示和“系统设置 → 辅助功能 → 显示 → 指针大小”一样。
    var cursorScale: Double?

    func settings(forDevice key: String?) -> MouseDeviceSettings {
        guard let key, let s = devices[key] else { return defaults }
        return s
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MouseConfig()
        enabled = c.value(.enabled, default: d.enabled)
        defaults = c.value(.defaults, default: d.defaults)
        devices = c.value(.devices, default: d.devices)
        backButton = c.value(.backButton, default: d.backButton)
        forwardButton = c.value(.forwardButton, default: d.forwardButton)
        // 以前只有一个“侧键前进、后退”开关，关掉的人两个侧键都不处理
        if !c.contains(.backButton), let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           (try? legacy.decode(Bool.self, forKey: .sideButtons)) == false {
            backButton = SideButtonSetting(.none)
            forwardButton = SideButtonSetting(.none)
        }
        ctrlWheelZoom = c.value(.ctrlWheelZoom, default: d.ctrlWheelZoom)
        cursorScale = c.value(.cursorScale, default: d.cursorScale)
    }

    private enum LegacyKeys: String, CodingKey {
        case sideButtons
    }
}

struct ClipboardConfig: Codable, Equatable {
    var enabled = true
    /// 最多保存多少条（固定的条目不算在内）。
    var maxItems = 200
    var recordImages = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardConfig()
        enabled = c.value(.enabled, default: d.enabled)
        maxItems = min(max(c.value(.maxItems, default: d.maxItems), 10), 1000)
        recordImages = c.value(.recordImages, default: d.recordImages)
    }
}

struct FileSearchConfig: Codable, Equatable {
    /// F1：连按两下 Ctrl 呼出文件搜索
    var enabled = true
    /// 用过一次文件搜索之后才在启动时建立索引：第一次扫描“桌面”“文稿”“下载”时系统会询问权限，
    /// 放在用户自己打开文件搜索的时候问，而不是一启动就弹出来。
    var activated = false
    /// 也搜索外接硬盘
    var includeExternalDrives = true
    /// F2：也按文件内容搜（文本、代码、Word、Excel、PowerPoint、PDF）
    var searchContents = true
    /// 也认图片（截图、照片）和扫描版 PDF 里的文字
    var searchImageText = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FileSearchConfig()
        enabled = c.value(.enabled, default: d.enabled)
        activated = c.value(.activated, default: d.activated)
        includeExternalDrives = c.value(.includeExternalDrives, default: d.includeExternalDrives)
        searchContents = c.value(.searchContents, default: d.searchContents)
        searchImageText = c.value(.searchImageText, default: d.searchImageText)
    }
}

struct WindowConfig: Codable, Equatable {
    /// W1：Win+方向键分屏
    var enabled = true
    /// W2：拖到屏幕边缘分屏（系统自带的拖动分屏开着时不生效）
    var dragToSnap = true
    /// W3：分好一半后在另一半列出其他窗口（贴靠助手）
    var snapAssist = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowConfig()
        enabled = c.value(.enabled, default: d.enabled)
        dragToSnap = c.value(.dragToSnap, default: d.dragToSnap)
        snapAssist = c.value(.snapAssist, default: d.snapAssist)
    }
}

struct UpdateConfig: Codable, Equatable {
    /// 定期到 GitHub 看有没有新版本（见 Updater）
    var automatic = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automatic = c.value(.automatic, default: UpdateConfig().automatic)
    }
}

struct AppConfig: Codable, Equatable {
    var keyboard = KeyboardConfig()
    var mouse = MouseConfig()
    var clipboard = ClipboardConfig()
    var fileSearch = FileSearchConfig()
    var window = WindowConfig()
    var update = UpdateConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboard = c.value(.keyboard, default: KeyboardConfig())
        mouse = c.value(.mouse, default: MouseConfig())
        clipboard = c.value(.clipboard, default: ClipboardConfig())
        fileSearch = c.value(.fileSearch, default: FileSearchConfig())
        window = c.value(.window, default: WindowConfig())
        update = c.value(.update, default: UpdateConfig())
    }
}

extension KeyedDecodingContainer {
    /// 读不到或格式不对时使用默认值。以后增加新的设置项时，旧的配置文件仍然能读。
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// 配置的读写。界面在主线程上修改 `config`；事件拦截线程通过 `snapshot` 读取。
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    private static let defaultsKey = "config.v1"

    /// 给事件拦截线程读的副本。
    let snapshot: Locked<AppConfig>

    @Published var config: AppConfig {
        didSet {
            guard config != oldValue else { return }
            snapshot.set(config)
            save()
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = AppConfig()
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                loaded = try JSONDecoder().decode(AppConfig.self, from: data)
            } catch {
                Log.app.error("配置读取失败，使用默认值：\(error.localizedDescription, privacy: .public)")
            }
        }
        config = loaded
        snapshot = Locked(loaded)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            Log.app.error("配置保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
