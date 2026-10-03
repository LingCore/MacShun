// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import CoreGraphics

/// 显示器缩放（D1）：每块屏幕像 Windows 那样按百分比选缩放，背后就是“系统设置 → 显示器”里的分辨率。
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
        for (index, mode) in modes.enumerated() {
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

    private static func better(_ a: Option, than b: Option, preferredRefresh: Double) -> Bool {
        let aMatches = abs(a.mode.refreshRate - preferredRefresh) < 0.5
        let bMatches = abs(b.mode.refreshRate - preferredRefresh) < 0.5
        if aMatches != bMatches { return aMatches }
        return a.mode.refreshRate > b.mode.refreshRate
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
    /// 现在用的模式
    let current: DisplayScaling.ModeSpec
    /// 现在用的是哪个清晰档位；现在的模式不在清晰档位里时为 nil
    var currentOption: DisplayScaling.Option? {
        options.first { $0.mode.width == current.width && $0.mode.height == current.height && $0.mode.isHiDPI == current.isHiDPI }
    }
}

/// 读取显示器、切换缩放。显示器接上、拔掉或者分辨率变了会自动刷新。只在主线程上使用。
final class DisplayScalingModel: ObservableObject {
    static let shared = DisplayScalingModel()

    @Published private(set) var displays: [DisplayInfo] = []

    /// 每块显示器的模式列表，和 DisplayInfo.options 里的 index 对应
    private var modes: [CGDirectDisplayID: [CGDisplayMode]] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
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
            allModes[id] = list
            result.append(DisplayInfo(
                id: id,
                name: Self.name(of: id),
                isMain: CGDisplayIsMain(id) != 0,
                nativeWidth: native.width,
                nativeHeight: native.height,
                options: DisplayScaling.options(from: specs, preferredRefresh: current.refreshRate),
                current: Self.spec(current)
            ))
        }
        modes = allModes
        // 主显示器排在前面
        displays = result.sorted { $0.isMain && !$1.isMain }
    }

    /// 切换到某个档位。和系统设置里改分辨率一样，会一直保留。
    func select(_ option: DisplayScaling.Option, for display: DisplayInfo) {
        guard let list = modes[display.id], list.indices.contains(option.index) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        let error = CGConfigureDisplayWithDisplayMode(config, display.id, list[option.index], nil)
        if error == .success {
            let done = CGCompleteDisplayConfiguration(config, .permanently)
            if done != .success { Log.app.error("切换显示器缩放失败：\(done.rawValue, privacy: .public)") }
        } else {
            CGCancelDisplayConfiguration(config)
            Log.app.error("切换显示器缩放失败：\(error.rawValue, privacy: .public)")
        }
        refresh()
    }

    private static func spec(_ mode: CGDisplayMode) -> DisplayScaling.ModeSpec {
        DisplayScaling.ModeSpec(
            width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            isNative: mode.ioFlags & 0x0200_0000 != 0   // kDisplayModeNativeFlag
        )
    }

    private static func name(of id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? L("显示器")
    }
}
