// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// 圆角方块里的白色图标，和“系统设置”侧边栏的图标一个样式。
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// 设置页顶部的大标题卡片：图标、标题、一句话说明，右边是总开关。
struct SettingsPageHeader<Accessory: View>: View {
    let tab: SettingsTab
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: tab.symbol, tint: tab.tint, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.headline)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 6)
    }
}

extension SettingsPageHeader where Accessory == EmptyView {
    init(tab: SettingsTab, subtitle: String) {
        self.init(tab: tab, subtitle: subtitle) { EmptyView() }
    }
}

/// 只用来说明、没有开关的一行：左边小图标，标题和说明。
struct InfoRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 鼠标停在上面

/// 鼠标停在上面没有。不能用 @State（命令行工具缺宏插件），每个用到的视图自带一个 @StateObject
final class HoverState: ObservableObject {
    @Published var isHovered = false
    #if DEBUG
    /// 截图用：所有按钮都画成鼠标停在上面的样子
    static var previewAll = false
    #endif
}

/// 把“鼠标停在上面没有”交给里面的视图。不能点（disabled）时当作没停在上面
struct HoverReader<Content: View>: View {
    @StateObject private var state = HoverState()
    @Environment(\.isEnabled) private var isEnabled
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    private var hovering: Bool {
        #if DEBUG
        if HoverState.previewAll { return isEnabled }
        #endif
        return state.isHovered && isEnabled
    }

    var body: some View {
        content(hovering)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { inside in
                if state.isHovered != inside { state.isHovered = inside }
            }
    }
}

/// 浅灰底的小按钮（结果上的“定位”、剪贴板的“全部清除”、引导的 ×）：鼠标停在上面底色深一点、字变清楚，按下再深一点。
/// destructive 是红底白字（“确定删除”“再点一次清除”）
struct ChipButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(foreground(hovering || configuration.isPressed))
                .background(shape.fill(fill(hovering, pressed: configuration.isPressed)))
                .contentShape(shape)
        }
    }

    private func fill(_ hovering: Bool, pressed: Bool) -> Color {
        if destructive { return Color.red.opacity(pressed ? 1 : hovering ? 0.95 : 0.8) }
        return Color.primary.opacity(pressed ? 0.2 : hovering ? 0.14 : 0.08)
    }

    private func foreground(_ active: Bool) -> AnyShapeStyle {
        if destructive { return AnyShapeStyle(Color.white) }
        return active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

extension ButtonStyle where Self == ChipButtonStyle<RoundedRectangle> {
    static func chip(cornerRadius: CGFloat = 6, destructive: Bool = false) -> Self {
        ChipButtonStyle(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), destructive: destructive)
    }
}

/// 文字链接（“打开系统设置”）：鼠标停在上面加下划线、换成手形指针，按下变淡。
/// color 为 nil 时用外面给的颜色
struct HoverLinkStyle: ButtonStyle {
    var color: Color? = Color(nsColor: .linkColor)

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(ifGiven: color)
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .linkCursor()
        }
    }
}

extension ButtonStyle where Self == HoverLinkStyle {
    static var hoverLink: Self { HoverLinkStyle() }
}

/// 只有图标的按钮（列表里的 ⊖ 移除）：平时灰色，鼠标停在上面变成 color
struct HoverIconStyle: ButtonStyle {
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(hovering ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// 有颜色的按钮（“作者主页”、发邮件）：鼠标停在上面时盖一层和按钮一样形状的颜色，深色模式亮一点、浅色模式暗一点，按下再多一点
struct HoverTintStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(HoverTint(shape: shape, pressed: configuration.isPressed))
    }
}

private struct HoverTint<S: Shape>: ViewModifier {
    let shape: S
    var pressed = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        HoverReader { hovering in
            let level: Double = pressed ? 2 : hovering ? 1 : 0
            content.overlay(
                shape.fill(colorScheme == .dark ? Color.white.opacity(0.1 * level) : Color.black.opacity(0.06 * level))
                    .allowsHitTesting(false)
            )
        }
    }
}

/// 系统样式的按钮（“添加应用…”“一键授权”）本身没有悬停效果，盖一层和 HoverTintStyle 一样的颜色。
/// 形状照 macOS 26 起的按钮量的：按钮的大小正好是底板，普通的圆角 6，小号 5，大号是胶囊
private struct NativeButtonHover: ViewModifier {
    @Environment(\.controlSize) private var controlSize

    func body(content: Content) -> some View {
        content.modifier(HoverTint(shape: shape))
    }

    private var shape: AnyShape {
        switch controlSize {
        case .mini: AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .small: AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .large, .extraLarge: AnyShape(Capsule())
        default: AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

extension View {
    /// 系统样式的按钮加上悬停效果（见 NativeButtonHover）。更早的系统按钮形状不一样，不加。
    /// 要放在 .controlSize 前面，才知道按钮多大
    @ViewBuilder func nativeButtonHover() -> some View {
        if #available(macOS 26.0, *) {
            modifier(NativeButtonHover())
        } else {
            self
        }
    }

    /// 给了颜色才设，没给就用外面的
    @ViewBuilder func foregroundStyle(ifGiven color: Color?) -> some View {
        if let color {
            foregroundStyle(color)
        } else {
            self
        }
    }

    /// 手形指针（macOS 15 起才有，14 上不换）
    @ViewBuilder func linkCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}

/// 毛玻璃背景，透出窗口后面的内容。
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// 应用的图标和名字，按应用标识查，查过的记下来。只在主线程上使用。
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    static func name(_ bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
        }
        names[bundleID] = name
        return name
    }
}
