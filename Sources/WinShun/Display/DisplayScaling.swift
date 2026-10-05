// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import CoreGraphics

/// 显示器缩放（D1）和刷新率（D2）：每块屏幕像 Windows 那样按百分比选缩放、单独选刷新率，
/// 背后就是“系统设置 → 显示器”里的分辨率和刷新率。
///
/// 只列出清晰的档位：
/// - 100%：按屏幕原生分辨率显示；
/// - 高分屏模式（按 2 倍渲染）并且渲染出的像素不少于屏幕原生像素，系统再缩小到屏幕上，文字是清晰的。
/// 其余档位要把画面放大到屏幕上，文字发虚，不列出。2K 这类非高分屏，系统通常只给 100% 和 200% 两个清晰档位。
///
/// 改动和在系统设置里改一样，会一直保留，退出 Win顺 也不恢复。
enum DisplayScaling {
    /// 一个显示模式的尺寸，从 CGDisplayMode 读出来。单独拿出来是为了能测试。
    struct ModeSpec: Equatable {
        /// 看起来像的大小（点）
        var width: Int
        var height: Int
        /// 实际渲染的像素
        var pixelWidth: Int
        var pixelHeight: Int
        var refreshRate: Double
        var isNative = false
        /// 系统标的默认模式。同一个大小和刷新率有时有两个模式（时序不同，看不出区别），优先用默认的
        var isDefault = false
        /// 隔行扫描、拉伸、系统标着不显示的模式（电视上常见），不列出
        var isUnusual = false
        /// 系统给模式的编号，切换时按它找，不怕模式列表在这期间变了
        var modeID: Int32 = 0

        var isHiDPI: Bool { pixelWidth == width * 2 && pixelHeight == height * 2 }
    }

    /// 一个缩放档位。
    struct Option: Identifiable, Equatable {
        /// 和 Windows 一样的百分比：原生宽度 ÷ 看起来像的宽度
        var percent: Int
        var mode: ModeSpec
        /// 在模式列表里的位置，切换时用
        var index: Int

        var id: String { "\(mode.width)x\(mode.height)" }
    }

    /// 一个刷新率档位。
    struct RefreshOption: Identifiable, Equatable {
        var rate: Double
        /// 在模式列表里的位置
        var index: Int
        var modeID: Int32 = 0

        var id: String { DisplayScaling.refreshID(rate) }
        /// 144 Hz；不是整数时带小数：59.94 Hz
        var label: String { DisplayScaling.label(forRefresh: rate) }
    }

    /// 按两位小数区分，59.94 和 60 是两个档位
    static func refreshID(_ rate: Double) -> String { String(format: "%.2f", rate) }

    static func label(forRefresh rate: Double) -> String {
        abs(rate - rate.rounded()) < 0.005 ? "\(Int(rate.rounded())) Hz" : String(format: "%.2f Hz", rate)
    }

    /// 屏幕原生分辨率：标着原生的模式；没有标记时取最大的 1 倍模式。
    static func nativeSize(of modes: [ModeSpec]) -> (width: Int, height: Int)? {
        if let native = modes.first(where: { $0.isNative && !$0.isHiDPI }) {
            return (native.pixelWidth, native.pixelHeight)
        }
        let flat = modes.filter { $0.pixelWidth == $0.width }
        guard let largest = flat.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else { return nil }
        return (largest.pixelWidth, largest.pixelHeight)
    }

    /// 清晰的档位，按百分比从小到大。同一个大小有几种刷新率时，优先用 preferredRefresh（一般是现在的刷新率）。
    static func options(from modes: [ModeSpec], preferredRefresh: Double) -> [Option] {
        guard let native = nativeSize(of: modes) else { return [] }
        var best: [String: Option] = [:]
        for (index, mode) in modes.enumerated() where !mode.isUnusual {
            // 宽高比要和屏幕一样，不然画面会被拉伸或加黑边
            guard mode.width * native.height == mode.height * native.width else { continue }
            let atNative = !mode.isHiDPI && mode.pixelWidth == native.width && mode.width == native.width
            let sharpHiDPI = mode.isHiDPI && mode.pixelWidth >= native.width
            guard atNative || sharpHiDPI else { continue }
            let percent = Int((Double(native.width) / Double(mode.width) * 100).rounded())
            let option = Option(percent: percent, mode: mode, index: index)
            if let existing = best[option.id], !better(option, than: existing, preferredRefresh: preferredRefresh) { continue }
            best[option.id] = option
        }
        return best.values.sorted { $0.percent < $1.percent }
    }

    /// 和 current 一样大小的模式能用哪些刷新率，从高到低。只有一个时界面上不给选。
    static func refreshOptions(from modes: [ModeSpec], current: ModeSpec) -> [RefreshOption] {
        var best: [String: RefreshOption] = [:]
        func isCurrent(_ mode: ModeSpec) -> Bool { mode.modeID != 0 && mode.modeID == current.modeID }
        for (index, mode) in modes.enumerated() where !mode.isUnusual {
            // 有的内建屏幕读不到刷新率，是 0
            guard mode.refreshRate > 0, mode.width == current.width, mode.height == current.height,
                  mode.pixelWidth == current.pixelWidth, mode.pixelHeight == current.pixelHeight else { continue }
            let option = RefreshOption(rate: mode.refreshRate, index: index, modeID: mode.modeID)
            if let existing = best[option.id] {
                // 现在用的模式代表它那个刷新率，重新选同一个刷新率时不换成另一个模式
                let old = modes[existing.index]
                if isCurrent(old) || (!isCurrent(mode) && !preferred(mode, over: old)) { continue }
            }
            best[option.id] = option
        }
        return best.values.sorted { $0.rate > $1.rate }
    }

    private static func better(_ a: Option, than b: Option, preferredRefresh: Double) -> Bool {
        // 刷新率一样的最好，差不到 0.5 的其次：59.94 Hz 换缩放后还是 59.94，不变成 60
        func closeness(_ rate: Double) -> Int {
            abs(rate - preferredRefresh) < 0.005 ? 2 : abs(rate - preferredRefresh) < 0.5 ? 1 : 0
        }
        let aCloseness = closeness(a.mode.refreshRate)
        let bCloseness = closeness(b.mode.refreshRate)
        if aCloseness != bCloseness { return aCloseness > bCloseness }
        if abs(a.mode.refreshRate - b.mode.refreshRate) >= 0.005 { return a.mode.refreshRate > b.mode.refreshRate }
        return preferred(a.mode, over: b.mode)
    }

    /// 大小和刷新率都一样的两个模式选哪个（a 在列表里排在 b 后面）：先选系统标的默认模式，
    /// 都不是就选后面那个。在 2K 144Hz 屏上看到系统自己选的也是后面那个。
    private static func preferred(_ a: ModeSpec, over b: ModeSpec) -> Bool {
        a.isDefault || !b.isDefault
    }
}

/// 一块显示器和它能选的缩放档位。
struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool
    let nativeWidth: Int
    let nativeHeight: Int
    let options: [DisplayScaling.Option]
    /// 现在这个大小能用的刷新率，从高到低
    let refreshOptions: [DisplayScaling.RefreshOption]
    /// 现在用的模式
    let current: DisplayScaling.ModeSpec
    /// 现在用的是哪个清晰档位；现在的模式不在清晰档位里时为 nil
    var currentOption: DisplayScaling.Option? {
        options.first { $0.mode.width == current.width && $0.mode.height == current.height && $0.mode.isHiDPI == current.isHiDPI }
    }
    var currentRefresh: DisplayScaling.RefreshOption? {
        refreshOptions.first { $0.id == DisplayScaling.refreshID(current.refreshRate) }
    }
}

/// 读取显示器、切换缩放和刷新率。显示器接上、拔掉或者分辨率变了会自动刷新。只在主线程上使用。
final class DisplayScalingModel: ObservableObject {
    static let shared = DisplayScalingModel()

    @Published private(set) var displays: [DisplayInfo] = []

    /// 每块显示器的模式列表，和 DisplayInfo.options 里的 index 对应
    private var modes: [CGDirectDisplayID: [CGDisplayMode]] = [:]
    private var observer: NSObjectProtocol?

    private var refreshScheduled = false

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // 只改刷新率时不一定有上面的通知（例如在系统设置里改），另外听一下显示器配置的变化
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { DisplayScalingModel.shared.scheduleRefresh() }
        }, nil)
        refresh()
    }

    /// 一次配置变化会对每块显示器各回调一次，合并成一次刷新
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    #if DEBUG
    /// 截图用：显示给定的显示器，不再读真的
    private var preview: [DisplayInfo]?

    func showPreview(_ displays: [DisplayInfo]) {
        preview = displays
        self.displays = displays
    }
    #endif

    func refresh() {
        #if DEBUG
        if let preview {
            displays = preview
            return
        }
        #endif
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return }
        var result: [DisplayInfo] = []
        var allModes: [CGDirectDisplayID: [CGDisplayMode]] = [:]
        for id in ids.prefix(Int(count)) {
            // 镜像的副屏跟着主屏走，不单独列出
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay, let current = CGDisplayCopyDisplayMode(id) else { continue }
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let list = ((CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []).filter { $0.isUsableForDesktopGUI() }
            let specs = list.map(Self.spec)
            guard let native = DisplayScaling.nativeSize(of: specs) else { continue }
            let currentSpec = Self.spec(current)
            allModes[id] = list
            result.append(DisplayInfo(
                id: id,
                name: Self.name(of: id),
                isMain: CGDisplayIsMain(id) != 0,
                nativeWidth: native.width,
                nativeHeight: native.height,
                options: DisplayScaling.options(from: specs, preferredRefresh: current.refreshRate),
                refreshOptions: DisplayScaling.refreshOptions(from: specs, current: currentSpec),
                current: currentSpec
            ))
        }
        modes = allModes
        // 主显示器排在前面
        displays = result.sorted { $0.isMain && !$1.isMain }
    }

    /// 切换到某个缩放档位。和系统设置里改分辨率一样，会一直保留。
    func select(_ option: DisplayScaling.Option, for display: DisplayInfo) {
        apply(modeID: option.mode.modeID, to: display)
    }

    /// 切换刷新率，大小不变。和系统设置里改一样，会一直保留。
    func select(_ option: DisplayScaling.RefreshOption, for display: DisplayInfo) {
        apply(modeID: option.modeID, to: display)
    }

    private func apply(modeID: Int32, to display: DisplayInfo) {
        guard let mode = modes[display.id]?.first(where: { $0.ioDisplayModeID == modeID }) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        let error = CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil)
        if error == .success {
            let done = CGCompleteDisplayConfiguration(config, .permanently)
            if done != .success { Log.app.error("切换显示模式失败：\(done.rawValue, privacy: .public)") }
            else { Log.app.notice("显示器 \(display.id, privacy: .public) 切换到 \(mode.width, privacy: .public)×\(mode.height, privacy: .public) \(mode.refreshRate, privacy: .public)Hz") }
        } else {
            CGCancelDisplayConfiguration(config)
            Log.app.error("切换显示模式失败：\(error.rawValue, privacy: .public)")
        }
        refresh()
    }

    private static func spec(_ mode: CGDisplayMode) -> DisplayScaling.ModeSpec {
        DisplayScaling.ModeSpec(
            width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            isNative: mode.ioFlags & 0x0200_0000 != 0,  // kDisplayModeNativeFlag
            isDefault: mode.ioFlags & 0x4 != 0,         // kDisplayModeDefaultFlag
            // kDisplayModeInterlacedFlag、kDisplayModeNeverShowFlag、kDisplayModeStretchedFlag
            isUnusual: mode.ioFlags & (0x40 | 0x80 | 0x800) != 0,
            modeID: mode.ioDisplayModeID
        )
    }

    private static func name(of id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? L("显示器")
    }
}
