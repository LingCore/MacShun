// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing
@testable import MacShun

@Suite("K8 键盘模式")
struct LayoutInferenceTests {
    private let k99 = "14391:8224:MCHOSE K99 V3"

    @Test func consistentPressesChangeNothing() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskAlternate, current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskCommand, current: .mac, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.v, flags: .maskAlternate, current: .mac, device: k99) == nil)
    }

    /// 设置是 Windows 模式，键盘切到了 Mac 模式：Alt+Tab 发出 ⌘Tab，Win+V 发出 ⌥V。
    @Test func learnsMacMode() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskCommand, current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.v, flags: .maskAlternate, current: .windows, device: k99) == .mac)
    }

    /// 设置是 Mac 模式，键盘拨回了 Windows 模式：Alt+Tab 发出 ⌥Tab。
    @Test func learnsWindowsMode() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskAlternate, current: .mac, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: [.maskAlternate, .maskShift], current: .mac, device: k99) == .windows)
    }

    /// 没有 Win+F4 这个快捷键，Alt+F4 看到一次就算。
    @Test func altF4IsConclusive() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.f4, flags: .maskCommand, current: .windows, device: k99) == .mac)
        #expect(inference.observe(keyCode: KeyCode.f4, flags: .maskAlternate, current: .mac, device: k99) == .windows)
    }

    /// 中间按了一次与当前模式一致的按法，计数清零（之前那次可能是偶尔按的 Win+Tab）。
    @Test func consistentPressResetsEvidence() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskCommand, current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskAlternate, current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskCommand, current: .windows, device: k99) == nil)
    }

    @Test func evidenceIsPerKeyboard() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskAlternate, current: .mac, device: "a") == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskAlternate, current: .mac, device: "b") == nil)
    }

    @Test func otherKeysAndCombosAreIgnored() {
        var inference = LayoutInference()
        #expect(inference.observe(keyCode: KeyCode.c, flags: .maskCommand, current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.v, flags: .maskCommand, current: .mac, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: .maskControl, current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.tab, flags: [.maskCommand, .maskAlternate], current: .windows, device: k99) == nil)
        #expect(inference.observe(keyCode: KeyCode.d, flags: .maskAlternate, current: .windows, device: k99) == nil)
    }

    @Test func layoutPerKeyboard() {
        var config = KeyboardConfig()
        config.layout = .windows
        let keyboard = InputDevice(key: k99, name: "MCHOSE K99 V3", vendorID: 14391, productID: 8224)
        let apple = InputDevice(key: "1452:834:Apple Internal Keyboard / Trackpad", name: "Apple Internal Keyboard / Trackpad",
                                vendorID: 0x05AC, productID: 834)
        #expect(config.layout(for: nil) == .windows)
        #expect(config.layout(for: keyboard) == .windows)
        #expect(config.layout(for: apple) == .mac)
        config.layouts[k99] = .mac
        #expect(config.layout(for: keyboard) == .mac)
    }
}
