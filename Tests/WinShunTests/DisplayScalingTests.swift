// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import WinShun

@Suite("D1 显示器缩放")
struct DisplayScalingTests {
    /// "看起来像的宽x高@像素宽x像素高"，和 macOS 27 实际读到的模式列表一样
    private func modes(_ list: [String], refresh: Double = 60, native: String? = nil) -> [DisplayScaling.ModeSpec] {
        list.map { item in
            let parts = item.split(separator: "@")
            let points = parts[0].split(separator: "x").map { Int($0)! }
            let pixels = parts[1].split(separator: "x").map { Int($0)! }
            return DisplayScaling.ModeSpec(width: points[0], height: points[1], pixelWidth: pixels[0], pixelHeight: pixels[1],
                                           refreshRate: refresh, isNative: item == native)
        }
    }

    /// LG UltraFine 4K（3840×2160）
    private var lg4K: [DisplayScaling.ModeSpec] {
        modes([
            "800x600@1600x1200", "960x540@1920x1080", "1280x720@2560x1440", "1280x720@1280x720",
            "1504x846@3008x1692", "1600x900@3200x1800", "1680x945@3360x1890", "1920x1080@3840x2160",
            "1920x1080@1920x1080", "2048x1152@4096x2304", "2304x1296@4608x2592", "2560x1440@5120x2880",
            "2560x1440@2560x1440", "3008x1692@6016x3384", "3200x1800@6400x3600", "3360x1890@6720x3780",
            "3840x2160@3840x2160",
        ])
    }

    /// 25 寸 2K 屏（2560×1440，144Hz）：系统给的高分屏模式都比原生像素少
    private var screen2K: [DisplayScaling.ModeSpec] {
        modes([
            "800x600@1600x1200", "960x540@1920x1080", "1024x576@2048x1152", "1280x720@2560x1440",
            "1280x720@1280x720", "1600x900@1600x900", "1920x1080@1920x1080", "2048x1152@2048x1152",
            "2560x1440@2560x1440",
        ], refresh: 144)
    }

    @Test func listsSharpOptionsFor4K() {
        let options = DisplayScaling.options(from: lg4K, preferredRefresh: 60)
        #expect(options.map(\.percent) == [100, 114, 120, 128, 150, 167, 188, 200])
        #expect(options.first?.mode.isHiDPI == false)          // 100% 是原生分辨率
        #expect(options.last?.mode.width == 1920)              // 200% 看起来像 1920×1080
    }

    @Test func nonRetinaScreenOnlyHas100And200() {
        let options = DisplayScaling.options(from: screen2K, preferredRefresh: 144)
        #expect(options.map(\.percent) == [100, 200])
        #expect(options.map(\.mode.width) == [2560, 1280])
    }

    @Test func skipsBlurryUpscaledModes() {
        // 1920×1080 的 1 倍模式在 2K 屏上要放大显示，发虚
        let options = DisplayScaling.options(from: screen2K, preferredRefresh: 144)
        #expect(!options.contains { $0.mode.width == 1920 })
    }

    @Test func prefersCurrentRefreshRate() {
        var list = modes(["2560x1440@2560x1440"], refresh: 60)
        list += modes(["2560x1440@2560x1440"], refresh: 144)
        list += modes(["2560x1440@2560x1440"], refresh: 120)
        let options = DisplayScaling.options(from: list, preferredRefresh: 120)
        #expect(options.count == 1)
        #expect(options.first?.mode.refreshRate == 120)
        #expect(options.first?.index == 2)
    }

    @Test func usesNativeFlagWhenPresent() {
        let list = modes(["1920x1080@1920x1080", "2560x1440@2560x1440", "3840x2160@3840x2160"], native: "2560x1440@2560x1440")
        #expect(DisplayScaling.nativeSize(of: list)! == (2560, 1440))
    }

    @Test func skipsOtherAspectRatios() {
        let list = modes(["2560x1440@2560x1440", "1280x1024@2560x2048"])
        #expect(DisplayScaling.options(from: list, preferredRefresh: 60).map(\.mode.width) == [2560])
    }
}
