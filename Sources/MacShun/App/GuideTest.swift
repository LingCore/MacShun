// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices

/// 授权引导的真机自测：真的打开“系统设置”、真的显示浮窗，检查浮窗贴的位置、每一页里有没有 Mac顺、
/// 授权后会不会自动进入下一项、做完会不会回到设置窗口。
///
/// 不会去关任何权限：“还没授权”和“授权成功”都是假装的（PermissionGuide.grantedOverride），
/// 对“系统设置”只读不写。用 scripts/guide-test.sh 运行，大约半分钟，期间不要操作鼠标键盘。
@MainActor
final class GuideTest {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--guide-test") }

    private let openSettings: () -> Void
    private let guide = PermissionGuide.shared
    private var missing: Set<PermissionKind> = []
    private var passed = 0
    private var failed = 0
    private let shotDir = FileManager.default.temporaryDirectory.appendingPathComponent("MacShun引导自测")

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }

    func run(state: AppState) async {
        say("授权引导自测开始")
        guard Permissions.accessibility else {
            fail("权限", "没有辅助功能权限，读不了“系统设置”的界面")
            return finish()
        }
        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        let settingsWasRunning = Self.systemSettings != nil

        openSettings()
        await pause(800)

        // 一键授权：三项依次走一遍
        missing = Set(PermissionKind.allCases)
        guide.grantedOverride = { [unowned self] in !self.missing.contains($0) }
        let plan = guide.plan(PermissionKind.allCases)
        say("   步骤：" + plan.map(\.paneTitle).joined(separator: " → "))
        check("macOS 27 上不单独走“输入监控”", !PermissionKind.accessibilityCoversInputMonitoring || !plan.contains(.inputMonitoring),
              "步骤里还有“输入监控”")
        guide.start(PermissionKind.allCases, state: state)
        for (index, kind) in plan.enumerated() {
            await checkStep(kind, step: index + 1, total: plan.count)
            // 走完这一步之后，被它一并授权的也算开了
            if kind == .accessibility && PermissionKind.accessibilityCoversInputMonitoring { missing.remove(.inputMonitoring) }
        }
        let back = await waitUntil(timeout: 3) {
            self.guide.visiblePanel == nil && NSApp.isActive
                && NSApp.keyWindow?.identifier == SettingsWindowController.windowID
        }
        check("全部完成后收起浮窗、回到 Mac顺 设置窗口", back,
              "浮窗\(guide.visiblePanel == nil ? "已收起" : "还在")，Mac顺\(NSApp.isActive ? "在" : "不在")前台")

        // 点 × 关掉引导
        missing = [.pasteboard]
        guide.start([.pasteboard], state: state)
        _ = await waitUntil(timeout: 5) { self.guide.visiblePanel != nil }
        guide.stop()
        check("点 × 关掉引导", guide.visiblePanel == nil, "浮窗还在")

        // 用户关掉“系统设置”时引导跟着收起。原来就开着的不关它，免得打断用户。
        if !settingsWasRunning {
            missing = [.accessibility]
            guide.start([.accessibility], state: state)
            _ = await waitUntil(timeout: 5) { PermissionGuide.settingsWindowFrame() != nil }
            Self.systemSettings?.terminate()
            let closed = await waitUntil(timeout: 5) { self.guide.visiblePanel == nil }
            check("关掉“系统设置”后引导跟着收起", closed, "浮窗还在")
        } else {
            say("“系统设置”原来就开着，不测“关掉后引导收起”")
        }

        guide.stop()
        guide.grantedOverride = nil
        finish()
    }

    /// 一项授权：等“系统设置”打开到这一页，检查浮窗，再假装用户打开了开关。
    private func checkStep(_ kind: PermissionKind, step: Int, total: Int) async {
        let name = kind.title
        let model = guide.currentModel
        let shown = await waitUntil(timeout: 8) {
            self.guide.visiblePanel != nil && model.kind == kind && !model.granted
                && PermissionGuide.settingsWindowFrame() != nil
        }
        guard shown else {
            return fail("\(name)：浮窗", "8 秒内没等到“系统设置”和浮窗都出现（当前第 \(model.step) 步：\(model.kind.title)）")
        }
        // 浮窗跟随有 0.25 秒间隔，“系统设置”打开时还会动一下，稍等它停稳
        await pause(1200)
        check("\(name)：步骤显示 \(step)/\(total)", model.step == step && model.total == total,
              "显示的是 \(model.step)/\(model.total)")

        if let settings = PermissionGuide.settingsWindowFrame(), let panel = guide.visiblePanel?.frame {
            let near = settings.insetBy(dx: -30, dy: -30).intersects(panel)
            let covers = settings.intersects(panel)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(panel) }
            let side = panel.maxY <= settings.minY ? "下方" : panel.minX >= settings.maxX ? "右边"
                : panel.maxX <= settings.minX ? "左边" : panel.minY >= settings.maxY ? "上方" : "里面"
            check("\(name)：浮窗贴在“系统设置”窗口\(side)、不挡住它、没出屏幕",
                  near && !covers && onScreen,
                  "系统设置 \(Self.describe(settings))，浮窗 \(Self.describe(panel))")
            say("   系统设置 \(Self.describe(settings))，浮窗 \(Self.describe(panel))，屏幕可用区 "
                + NSScreen.screens.map { Self.describe($0.visibleFrame) }.joined(separator: " "))
        }

        let window = Self.settingsAXWindow()
        let title = window.flatMap { Self.string($0, kAXTitleAttribute) } ?? "（读不到）"
        let expected = Self.paneTitles[kind] ?? []
        check("\(name)：“系统设置”打开到了对应那一页（\(title)）", expected.contains(title) && title == kind.paneTitle,
              "窗口标题是“\(title)”。窗口里的文字：" + (window.map { Self.texts($0).prefix(40).joined(separator: " | ") } ?? ""))
        // 有的列表是打开后再慢慢加载的，多等一会儿
        let listed = await waitUntil(timeout: 5) { window.map { Self.containsText($0, "Mac顺") } ?? false }
        // 系统问过之后 Mac顺 才会出现在“粘贴”列表里；没问过（读剪贴板不弹窗）时列表本来就是空的
        if #available(macOS 15.4, *), kind == .pasteboard {
            say("   剪贴板 accessBehavior = \(NSPasteboard.general.accessBehavior.rawValue)（0 默认 1 询问 2 始终允许 3 始终拒绝），状态 \(PasteboardAccess.status)")
        }
        if kind == .pasteboard, Self.pasteboardNeverAsked {
            say("   “粘贴”列表：系统没问过 Mac顺，列表里没有它是正常的（\(listed ? "实际有" : "实际没有")）")
        } else if kind == .pasteboard, !listed, PasteboardAccess.status == .allowed {
            // macOS 27 上见过：已经是“始终允许”，那一页却一个程序都不列
            say("   “\(kind.paneTitle)”列表里没有 Mac顺，但 Mac顺 已经是“始终允许”，读剪贴板不受影响")
        } else if kind == .inputMonitoring, !listed, Permissions.inputMonitoring, Permissions.accessibility {
            // macOS 27：“设备控制和数据访问”包含了监控键盘，授了它就不会再列在“输入监控”里，引导也会跳过这一步
            say("   “输入监控”列表里没有 Mac顺，但已经能监控键盘（由“\(PermissionKind.accessibility.paneTitle)”一并授权），真实使用时这一步会被跳过")
        } else {
            check("\(name)：那一页的列表里有 Mac顺", listed,
              "没在窗口里找到“Mac顺”。窗口里的文字：" + (window.map { Self.texts($0).joined(separator: " | ") } ?? ""))
        }

        snapshot("\(step)-\(name)")
        missing.remove(kind)
        guide.checkGranted()
        let ticked = await waitUntil(timeout: 1) { model.granted }
        check("\(name)：授权后浮窗打勾", ticked, "没有打勾")
        await pause(500)
        snapshot("\(step)-\(name)-已开启")
    }

    // MARK: - 读“系统设置”的界面（只读）

    private static let paneTitles: [PermissionKind: Set<String>] = [
        .accessibility: ["辅助功能", "设备控制和数据访问", "Accessibility"],
        .inputMonitoring: ["输入监控", "Input Monitoring"],
        .pasteboard: ["粘贴", "从其他App粘贴", "Paste", "Pasteboard"],
    ]

    private static var pasteboardNeverAsked: Bool {
        guard #available(macOS 15.4, *) else { return true }
        return NSPasteboard.general.accessBehavior == .default
    }

    private static var systemSettings: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
    }

    private static func settingsAXWindow() -> AXUIElement? {
        guard let pid = systemSettings?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// 在界面树里找一段文字，最多看 4000 个元素。
    private static func containsText(_ root: AXUIElement, _ text: String) -> Bool {
        var stack = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 4000 {
            visited += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if string(element, attribute)?.contains(text) == true { return true }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                stack.append(contentsOf: list)
            }
        }
        return false
    }

    /// 窗口里所有的文字，排查用。
    private static func texts(_ root: AXUIElement) -> [String] {
        var stack = [root]
        var found: [String] = []
        var visited = 0
        while let element = stack.popLast(), visited < 4000 {
            visited += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(element, attribute), !text.isEmpty, !found.contains(text) { found.append(text) }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                stack.append(contentsOf: list.reversed())
            }
        }
        return found
    }

    // MARK: - 工具

    /// 把浮窗画成图片存下来，方便看样子（只画自己的窗口，不用录屏权限）。
    private func snapshot(_ name: String) {
        guard let view = guide.visiblePanel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = shotDir.appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func describe(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
    }

    private func finish() {
        say("授权引导自测结束：通过 \(passed) 项，失败 \(failed) 项。浮窗截图在 \(shotDir.path)")
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            passed += 1
            say("✅ \(name)")
        } else {
            failed += 1
            say("❌ \(name)：\(detail)")
        }
    }

    private func fail(_ name: String, _ detail: String) { check(name, false, detail) }

    private func say(_ line: String) {
        print(line)
        fflush(stdout)
        Log.app.notice("引导自测：\(line, privacy: .public)")
    }

    private func pause(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(100)
        }
        return condition()
    }
}
