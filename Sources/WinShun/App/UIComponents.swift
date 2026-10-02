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
