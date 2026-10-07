// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// README 截图：用假数据渲染设置窗口、剪贴板面板、文件搜索框和贴靠助手，不碰真实配置、剪贴板历史和系统设置。
// 由 scripts/readme-shots.sh 编译运行。
// 用法：shots <输出目录> <light|dark> <zh|en> [keyboard|mouse|display|panel|search|snap] -AppleLanguages "(en)"

/// 截图时假装程序在前台：开关、分段控件按激活的样子画，又不用真的抢走焦点。
final class ActiveApp: NSApplication {
    override var isActive: Bool { true }
}
let app = ActiveApp.shared
app.setActivationPolicy(.accessory)
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let dark = CommandLine.arguments[2] == "dark"
let en = CommandLine.arguments[3] == "en"
let only = CommandLine.arguments.count > 4 && !CommandLine.arguments[4].hasPrefix("-") ? CommandLine.arguments[4] : nil
let suffix = (dark ? "dark" : "light") + (en ? "-en" : "")
let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
NSApp.appearance = appearance
func wants(_ name: String) -> Bool { only == nil || only == name }

let suite = "winshun-readme-shots-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
let config = ConfigStore(defaults: defaults)
let state = AppState()
state.accessibilityGranted = true
state.inputMonitoringGranted = true
state.eventTapRunning = true
state.launchAtLogin = true
state.mice = [
    InputDevice(key: "1133:49271:Logitech MX Master 3S", name: "Logitech MX Master 3S", vendorID: 1133, productID: 49271),
]
state.keyboards = [
    InputDevice(key: "1452:641:Apple Internal Keyboard", name: "Apple Internal Keyboard / Trackpad", vendorID: 1452, productID: 641),
    InputDevice(key: "1133:50475:Logitech K845", name: "Logitech K845 Mechanical Keyboard", vendorID: 1133, productID: 50475),
]
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("winshun-shots-\(UUID().uuidString)")
let store = ClipboardStore(directory: scratch.appendingPathComponent("clip"))
let now = Date()
let samples: [(String, String, Double)] = en ? [
    ("Meeting notes: release planning, Friday 3 pm, Room 3", "Notes", 3600),
    ("https://github.com/LingCore/WinShun", "Safari", 1800),
    ("git commit -m \"Fix scroll direction\"", "Terminal", 900),
    ("Thank you for your email. I'll get back to you by Monday.", "Mail", 600),
    ("221B Baker Street, London NW1 6XE", "Messages", 300),
    ("ssh deploy@192.168.1.20", "Terminal", 120),
    ("Please send me the design draft before Tuesday. Thanks!", "Slack", 30),
] : [
    ("会议纪要：周五下午三点在 3 号会议室讨论新版发布计划", "备忘录", 3600),
    ("https://github.com/LingCore/WinShun", "Safari 浏览器", 1800),
    ("git commit -m \"修复滚轮方向\"", "终端", 900),
    ("Thank you for your email. I'll get back to you by Monday.", "邮件", 600),
    ("北京市朝阳区建国路 88 号", "微信", 300),
    ("ssh deploy@192.168.1.20", "终端", 120),
    ("下周二之前把设计稿发给我，谢谢！", "飞书", 30),
]
for (i, s) in samples.enumerated() {
    let cap = ClipboardCapture(kind: .text, text: s.0, fingerprint: "sample-\(i)", sourceApp: s.1)
    store.add(cap, maxItems: 200, now: now.addingTimeInterval(-s.2))
}

func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// 程序不在前台时，左上角三个圆点是灰的；截图里按前台窗口的颜色画上去。
func paintTrafficLights(_ view: NSView, _ rep: NSBitmapImageRep) {
    guard let window = view.window, window.styleMask.contains(.closable) else { return }
    let colors: [(NSWindow.ButtonType, NSColor)] = [
        (.closeButton, NSColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1)),
        (.miniaturizeButton, NSColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1)),
        (.zoomButton, NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)),
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (type, color) in colors {
        guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
        var r = button.convert(button.bounds, to: view)
        if view.isFlipped { r.origin.y = view.bounds.height - r.maxY }
        let side = min(r.width, r.height) - 2
        let dot = NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        color.blended(withFraction: 0.25, of: .black)!.setStroke()
        let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
        ring.lineWidth = 0.5
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// 截下视图（只要 area 那一块）
func capture(_ view: NSView, area: NSRect? = nil) -> NSBitmapImageRep {
    let area = area ?? view.bounds
    let full = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: full)
    paintTrafficLights(view, full)
    let s0 = CGFloat(full.pixelsWide) / view.bounds.width
    let flippedY = view.isFlipped ? area.minY : view.bounds.height - area.maxY
    let crop = full.cgImage!.cropping(to: CGRect(x: area.minX * s0, y: flippedY * s0, width: area.width * s0, height: area.height * s0))!
    let rep = NSBitmapImageRep(cgImage: crop)
    rep.size = area.size
    return rep
}

/// 切成圆角，四周留白加上阴影（像系统截图那样），存成 PNG。
func save(_ rep: NSBitmapImageRep, _ name: String, radius: CGFloat) {
    let scale = CGFloat(rep.pixelsWide) / rep.size.width
    let pad: CGFloat = 40
    let w = rep.size.width, h = rep.size.height
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((w + 2 * pad) * scale), pixelsHigh: Int((h + 2 * pad) * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: w + 2 * pad, height: h + 2 * pad)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let rect = NSRect(x: pad, y: pad, width: w, height: h)
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    rep.draw(in: rect)
    // 细边框，深色模式下边缘才看得清
    NSColor(white: dark ? 1 : 0, alpha: dark ? 0.18 : 0.12).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
    border.lineWidth = 0.5
    border.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

/// 截图时假装是当前窗口：开关、选中色和左上角三个圆点都显示成激活的样子，又不用真的抢走焦点。
final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 设置窗口某一页
func settingsWindow(_ tab: SettingsTab, size: NSSize) -> NSBitmapImageRep {
    let selection = SettingsSelection()
    selection.tab = tab
    selection.windowVisible = false   // 麦田背景不动，截图稳定
    let root = SettingsView(configStore: config, state: state, clipboardStore: store, selection: selection)
        .environment(\.controlActiveState, .key)
        .environmentObject(selection)
    let win = ActiveWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
    win.appearance = appearance
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.contentViewController = NSHostingController(rootView: root)
    win.setContentSize(size)
    win.setFrameOrigin(NSPoint(x: -4000, y: 0))
    win.orderFrontRegardless()
    win.makeKey()
    win.makeMain()
    pump(1.0)
    win.makeFirstResponder(nil)           // 搜索框不要显示光标
    pump(0.3)
    let rep = capture(win.contentView!.superview!)
    win.orderOut(nil)
    return rep
}

/// 桌面背景：一张柔和的渐变
var desktop: LinearGradient {
    LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.14, blue: 0.22), Color(red: 0.25, green: 0.18, blue: 0.3)]
                                : [Color(red: 0.62, green: 0.75, blue: 0.95), Color(red: 0.95, green: 0.8, blue: 0.75)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 把一个 SwiftUI 视图画在无边框窗口里截下来
func render<V: View>(_ view: V, size: NSSize, wait: Double = 0.8) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = appearance
    win.contentView = host
    win.setFrameOrigin(NSPoint(x: -4000, y: 0))
    win.orderFrontRegardless()
    pump(wait)
    let rep = capture(host)
    win.orderOut(nil)
    return rep
}

// MARK: - 设置窗口

if wants("keyboard") { save(settingsWindow(.keyboard, size: NSSize(width: 720, height: 600)), "keyboard-\(suffix).png", radius: 16) }
// 底边落在“光标”和下一节之间的空白里
if wants("mouse") { save(settingsWindow(.mouse, size: NSSize(width: 720, height: 590)), "mouse-\(suffix).png", radius: 16) }
if wants("display") {
    // 两块假的显示器：一块 4K 高分屏，一块 2K 高刷屏
    func mode(_ w: Int, _ h: Int, hiDPI: Bool, _ hz: Double) -> DisplayScaling.ModeSpec {
        DisplayScaling.ModeSpec(width: w, height: h, pixelWidth: hiDPI ? w * 2 : w, pixelHeight: hiDPI ? h * 2 : h, refreshRate: hz)
    }
    let fourK = [(100, mode(3840, 2160, hiDPI: false, 60)), (125, mode(3072, 1728, hiDPI: true, 60)),
                 (150, mode(2560, 1440, hiDPI: true, 60)), (200, mode(1920, 1080, hiDPI: true, 60))]
    let twoK = [(100, mode(2560, 1440, hiDPI: false, 144)), (200, mode(1280, 720, hiDPI: true, 144))]
    func options(_ list: [(Int, DisplayScaling.ModeSpec)]) -> [DisplayScaling.Option] {
        list.enumerated().map { DisplayScaling.Option(percent: $1.0, mode: $1.1, index: $0) }
    }
    func rates(_ list: [Double]) -> [DisplayScaling.RefreshOption] {
        list.enumerated().map { DisplayScaling.RefreshOption(rate: $1, index: $0) }
    }
    DisplayScalingModel.shared.showPreview([
        DisplayInfo(id: 1, name: "LG ULTRAFINE", isMain: true, nativeWidth: 3840, nativeHeight: 2160,
                    options: options(fourK), refreshOptions: rates([60, 30]), current: mode(2560, 1440, hiDPI: true, 60)),
        DisplayInfo(id: 2, name: "UF255S PLUS", isMain: false, nativeWidth: 2560, nativeHeight: 1440,
                    options: options(twoK), refreshOptions: rates([144, 120, 60]), current: mode(2560, 1440, hiDPI: false, 144)),
    ])
    save(settingsWindow(.display, size: NSSize(width: 720, height: 700)), "display-\(suffix).png", radius: 16)
}

// MARK: - 剪贴板面板

if wants("panel") {
    let model = ClipboardPanelModel(store: store)
    model.prepareForShow()
    let panel = ClipboardPanel()
    panel.appearance = appearance
    let host = NSHostingView(rootView: ClipboardPanelView(model: model).environment(\.controlActiveState, .key))
    host.safeAreaRegions = []
    panel.contentView = host
    panel.setFrameOrigin(NSPoint(x: -4000, y: 0))
    panel.orderFrontRegardless()
    pump(1.0)
    save(capture(host), "panel-\(suffix).png", radius: 12)
    panel.orderOut(nil)
}

// MARK: - 文件搜索

if wants("search") {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let contentIndex = ContentIndex(directory: scratch.appendingPathComponent("content"))
    let model = FileSearchModel(index: FileIndex.shared, contentIndex: contentIndex)
    model.searchesContent = true
    model.isShown = true
    let query: String
    let results: [FileSearchResult]
    if en {
        query = "invoice"
        results = [
            FileSearchResult(path: home + "/Documents/Finance/Invoice 2026-09.pdf", name: "Invoice 2026-09.pdf", isDirectory: false, score: 90),
            FileSearchResult(path: home + "/Documents/Templates/Invoice template.docx", name: "Invoice template.docx", isDirectory: false, score: 85),
            FileSearchResult(path: "/Volumes/Data/Archive/Invoices", name: "Invoices", isDirectory: true, score: 80),
            FileSearchResult(path: home + "/Documents/Projects/Budget 2026.xlsx", name: "Budget 2026.xlsx", isDirectory: false, score: 0,
                             snippet: "Client: Northwind Ltd. Payment due 30 days after the invoice date, in three installments"),
            FileSearchResult(path: home + "/Desktop/Meeting notes.txt", name: "Meeting notes.txt", isDirectory: false, score: 0,
                             snippet: "…ask finance whether the September invoice was paid, then send the updated contract on Monday"),
            FileSearchResult(path: home + "/Downloads/Purchasing guide.pdf", name: "Purchasing guide.pdf", isDirectory: false, score: 0,
                             snippet: "3.2 Every invoice over $5,000 must be approved by the department head and finance"),
        ]
    } else {
        query = "合同"
        results = [
            FileSearchResult(path: home + "/Documents/工作/2026 合同模板.docx", name: "2026 合同模板.docx", isDirectory: false, score: 90),
            FileSearchResult(path: home + "/Documents/工作/租房合同.pdf", name: "租房合同.pdf", isDirectory: false, score: 85),
            FileSearchResult(path: "/Volumes/数据/资料/合同", name: "合同", isDirectory: true, score: 80),
            FileSearchResult(path: home + "/Documents/项目/报价单-华东.xlsx", name: "报价单-华东.xlsx", isDirectory: false, score: 0,
                             snippet: "客户 上海某某科技有限公司 合同金额 128,000 元 付款方式 分三期"),
            FileSearchResult(path: home + "/Desktop/会议记录.txt", name: "会议记录.txt", isDirectory: false, score: 0,
                             snippet: "…周三和法务过了一遍，合同第 7 条违约责任要改成双方对等，下周一前发回给对方"),
            FileSearchResult(path: home + "/Downloads/采购流程说明.pdf", name: "采购流程说明.pdf", isDirectory: false, score: 0,
                             snippet: "3.2 合同审批：金额超过 5 万元的合同须经部门负责人和财务共同审批"),
        ]
    }
    // 假文件不存在，系统只给空白图标：按扩展名给
    var icons: [String: NSImage] = [:]
    for r in results {
        let type = r.isDirectory ? UTType.folder : (UTType(filenameExtension: (r.name as NSString).pathExtension) ?? .data)
        icons[r.path] = NSWorkspace.shared.icon(for: type)
    }
    model.scope = .all
    pump(0.3)   // 等初始化时的那次空搜索回来
    model.showPreview(query: query, results: results, icons: icons)
    pump(0.3)
    let height = FileSearchView.height(resultCount: results.count, hasContentSection: model.contentStart != nil, showsStatus: false)
    let size = NSSize(width: FileSearchPanel.width + 80, height: height + 56)
    let view = ZStack(alignment: .top) {
        desktop
        FileSearchView(model: model, index: FileIndex.shared, contentIndex: contentIndex)
            .frame(width: FileSearchPanel.width, height: height)
            .padding(.top, 28)
    }
    save(render(view, size: size), "search-\(suffix).png", radius: 12)
}

// MARK: - 分屏：左边一个窗口，右边是贴靠助手

if wants("snap") {
    // 左边窗口的底边正好在“拖到屏幕边缘分屏”这一行下面（英文字长，往下多一点）。
    // 再往下是读真实系统设置的提示，截图里不要。设置窗口最矮 500，再矮布局会挤在一起
    let screen = NSSize(width: 1440, height: en ? 622 : 592)
    let half = NSSize(width: screen.width / 2 - 12, height: screen.height - 16)
    let left = settingsWindow(.window, size: half)
    let leftImage = NSImage(size: left.size)
    leftImage.addRepresentation(left)
    let dummy = WindowElement(element: AXUIElementCreateSystemWide(), pid: 0)
    func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
    let model = SnapAssistModel()
    let apps: [(String, String, String)] = en ? [
        ("WinShun — README.md", "Visual Studio Code", "/Applications/Visual Studio Code.app"),
        ("GitHub - LingCore/WinShun", "Google Chrome", "/Applications/Google Chrome.app"),
        ("Documents", "Finder", "/System/Library/CoreServices/Finder.app"),
        ("Inbox", "Mail", "/System/Applications/Mail.app"),
        ("Shopping list", "Notes", "/System/Applications/Notes.app"),
        ("Calendar", "Calendar", "/System/Applications/Calendar.app"),
    ] : [
        ("Win顺 — README.md", "Visual Studio Code", "/Applications/Visual Studio Code.app"),
        ("LINUX DO - 新的理想型社区", "Google Chrome", "/Applications/Google Chrome.app"),
        ("文稿", "访达", "/System/Library/CoreServices/Finder.app"),
        ("微信", "微信", "/Applications/WeChat.app"),
        ("周末采购清单", "备忘录", "/System/Applications/Notes.app"),
        ("日历", "日历", "/System/Applications/Calendar.app"),
    ]
    model.candidates = apps.enumerated().map { i, a in
        .init(id: CGWindowID(i + 1), window: dummy, title: a.0, appName: a.1, icon: icon(a.2))
    }
    model.columns = SnapAssistView.columns(forWidth: half.width)
    model.selection = 1
    let view = ZStack(alignment: .topLeading) {
        desktop
        HStack(spacing: 16) {
            Image(nsImage: leftImage)
                .resizable()
                .frame(width: half.width, height: half.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(white: dark ? 1 : 0, opacity: dark ? 0.18 : 0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
            SnapAssistView(model: model)
                .frame(width: half.width, height: half.height)
        }
        .padding(8)
    }
    save(render(view, size: screen, wait: 1.0), "snap-\(suffix).png", radius: 12)
}

try? FileManager.default.removeItem(at: scratch)
defaults.removePersistentDomain(forName: suite)
exit(0)
