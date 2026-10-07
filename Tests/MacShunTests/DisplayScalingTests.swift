// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import MacShun

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

    /// 2K 144Hz 屏真实读到的 2560×1440 和 1280×720@2x 模式：144Hz 各有两个，其中 2560×1440 有一个标着默认
    private var screen2KRefresh: [DisplayScaling.ModeSpec] {
        func mode(_ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double, isDefault: Bool = false) -> DisplayScaling.ModeSpec {
            DisplayScaling.ModeSpec(width: w, height: h, pixelWidth: pw, pixelHeight: ph, refreshRate: hz, isDefault: isDefault)
        }
        return [
            mode(1280, 720, 2560, 1440, 144), mode(1280, 720, 2560, 1440, 144), mode(1280, 720, 2560, 1440, 120),
            mode(1280, 720, 2560, 1440, 60), mode(1280, 720, 1280, 720, 50),
            mode(2560, 1440, 2560, 1440, 144), mode(2560, 1440, 2560, 1440, 144, isDefault: true),
            mode(2560, 1440, 2560, 1440, 120), mode(2560, 1440, 2560, 1440, 60),
        ]
    }

    @Test func refreshRatesForCurrentSizeHighestFirst() {
        let list = screen2KRefresh
        let options = DisplayScaling.refreshOptions(from: list, current: list[0])
        #expect(options.map(\.rate) == [144, 120, 60])            // 不混进 1280×720 1 倍模式的 50Hz
        #expect(options.map(\.label) == ["144 Hz", "120 Hz", "60 Hz"])
    }

    @Test func duplicateRefreshPrefersDefaultThenLater() {
        let list = screen2KRefresh
        // 都不是默认：用后面那个（系统自己选的也是它）
        #expect(DisplayScaling.refreshOptions(from: list, current: list[0]).first?.index == 1)
        // 有默认的用默认的，不管前后
        #expect(DisplayScaling.refreshOptions(from: list, current: list[5]).first?.index == 6)
        var swapped = list
        swapped.swapAt(5, 6)
        #expect(DisplayScaling.refreshOptions(from: swapped, current: swapped[6]).first?.index == 5)
    }

    @Test func scalingKeepsRefreshAndPrefersDefaultMode() {
        let options = DisplayScaling.options(from: screen2KRefresh, preferredRefresh: 144)
        #expect(options.map(\.percent) == [100, 200])
        #expect(options.map(\.mode.refreshRate) == [144, 144])
        #expect(options.first?.index == 6)
    }

    @Test func fractionalRatesAreSeparate() {
        var list = modes(["3024x1964@3024x1964"], refresh: 120)
        list += modes(["3024x1964@3024x1964"], refresh: 60)
        list += modes(["3024x1964@3024x1964"], refresh: 59.94)
        list += modes(["3024x1964@3024x1964"], refresh: 0)       // 读不到刷新率的不列出
        let options = DisplayScaling.refreshOptions(from: list, current: list[0])
        #expect(options.map(\.label) == ["120 Hz", "60 Hz", "59.94 Hz"])
    }

    @Test func currentModeRepresentsItsRefreshRate() {
        var list = screen2KRefresh
        for i in list.indices { list[i].modeID = Int32(i + 1) }
        // 现在用的是第一个 144Hz 模式：重新选 144 时还是它，不换成另一个
        #expect(DisplayScaling.refreshOptions(from: list, current: list[0]).first?.modeID == 1)
        #expect(DisplayScaling.refreshOptions(from: list, current: list[5]).first?.modeID == 6)
    }

    @Test func skipsInterlacedAndStretchedModes() {
        var list = screen2KRefresh
        list[7].isUnusual = true   // 2560×1440 120Hz 隔行
        #expect(DisplayScaling.refreshOptions(from: list, current: list[6]).map(\.rate) == [144, 60])
    }

    @Test func scalingKeepsExactFractionalRefresh() {
        var list = modes(["1920x1080@3840x2160", "3840x2160@3840x2160"], refresh: 60, native: "3840x2160@3840x2160")
        list += modes(["1920x1080@3840x2160", "3840x2160@3840x2160"], refresh: 59.94, native: "3840x2160@3840x2160")
        let options = DisplayScaling.options(from: list, preferredRefresh: 59.94)
        #expect(options.map(\.mode.refreshRate) == [59.94, 59.94])
    }

    @Test func currentRefreshMatchesByOption() {
        let list = modes(["2560x1440@2560x1440"], refresh: 60.004) + modes(["2560x1440@2560x1440"], refresh: 144)
        var current = list[0]
        current.refreshRate = 59.996   // 同一档（60.00），只是读数有一点差别
        let info = DisplayInfo(id: 1, name: "", isMain: true, nativeWidth: 2560, nativeHeight: 1440, options: [],
                               refreshOptions: DisplayScaling.refreshOptions(from: list, current: current), current: current)
        #expect(info.currentRefresh?.rate == 60.004)
    }

    @Test func skipsOtherAspectRatios() {
        let list = modes(["2560x1440@2560x1440", "1280x1024@2560x2048"])
        #expect(DisplayScaling.options(from: list, preferredRefresh: 60).map(\.mode.width) == [2560])
    }
}
