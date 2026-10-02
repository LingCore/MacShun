// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// 设置里能搜到的每一项。标题是界面文字的键（简体中文），显示时翻译；搜索时中文、英文、拼音、
/// 首字母和额外的关键词都能匹配，不管界面是哪种语言。
struct SettingsItem: Identifiable {
    enum ID: String {
        case keyboardEnabled, keyboardMode, ctrlAsCommand, textNavigation, systemShortcuts, finderShortcuts
        case chatScreenshot, terminal, remoteDesktop, excludedApps
        case mouseEnabled, linearPointer, pointerSpeed, scrollDirection, linearScroll, scrollLines, perMouse
        case sideButtons, ctrlWheelZoom
        case clipboardEnabled, maxItems, recordImages, clipboardPrivacy, showInFinder, clearHistory
        case grantAll, accessibility, inputMonitoring, pasteboardPermission, relaunch, launchAtLogin, language, version
        case works, feedback
    }

    let id: ID
    let tab: SettingsTab
    /// 界面文字的键
    let title: String
    /// 额外的搜索词：同义词、英文、快捷键，不显示
    let keywords: String

    var localizedTitle: String { L(title) }

    /// 匹配程度，越大越靠前；0 表示不匹配。
    func score(_ query: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let titles = [title, Self.english(title)].map { $0.lowercased() }
        if titles.contains(where: { $0.hasPrefix(q) }) { return 4 }
        if titles.contains(where: { $0.contains(q) }) { return 3 }
        if PinyinIndex(text: title).matches(q) { return 2 }
        if keywords.lowercased().contains(q) || PinyinIndex(text: keywords).matches(q) { return 1 }
        return 0
    }

    /// 英文译文，界面是中文时也要能用英文搜到
    private static let englishBundle = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))

    static func english(_ key: String) -> String {
        englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

extension SettingsItem {
    // keywords: 后面是搜索用的词，不是界面文字
    static let all: [SettingsItem] = [
        .init(id: .keyboardEnabled, tab: .keyboard, title: "快捷键像 Windows",
              keywords: "keyboard 键盘 开关 shortcuts enable"),
        .init(id: .keyboardMode, tab: .keyboard, title: "键盘模式",
              keywords: "win mac 模式 布局 layout type"),
        .init(id: .ctrlAsCommand, tab: .keyboard, title: "Ctrl 组合键",
              keywords: "复制 粘贴 剪切 撤销 重做 全选 保存 查找 copy paste cut undo redo save find select command ⌘"),
        .init(id: .textNavigation, tab: .keyboard, title: "文字光标",
              keywords: "home end 行首 行尾 删词 按词移动 cursor word backspace"),
        .init(id: .systemShortcuts, tab: .keyboard, title: "系统快捷键",
              keywords: "alt+tab alt+f4 win+e win+d win+l win+s 切换程序 关闭窗口 显示桌面 锁屏 输入法 switch apps close lock desktop input source"),
        .init(id: .finderShortcuts, tab: .keyboard, title: "Finder",
              keywords: "访达 文件 剪切 移动 重命名 删除 f2 files rename move"),
        .init(id: .chatScreenshot, tab: .keyboard, title: "微信、QQ 截图",
              keywords: "wechat qq screenshot 截屏 alt+a"),
        .init(id: .terminal, tab: .keyboard, title: "终端",
              keywords: "terminal iterm 命令行 ctrl+shift+c"),
        .init(id: .remoteDesktop, tab: .keyboard, title: "远程桌面、虚拟机",
              keywords: "todesk 向日葵 parallels vmware rdp remote vm"),
        .init(id: .excludedApps, tab: .keyboard, title: "另外不改写按键的应用",
              keywords: "例外 排除 忽略 添加应用 exclude ignore apps"),

        .init(id: .mouseEnabled, tab: .mouse, title: "鼠标像 Windows",
              keywords: "mouse 鼠标 开关 enable"),
        .init(id: .linearPointer, tab: .mouse, title: "指针不加速",
              keywords: "加速 鼠标加速 精确 acceleration linear precise"),
        .init(id: .pointerSpeed, tab: .mouse, title: "指针速度",
              keywords: "速度 灵敏度 跟踪速度 快 慢 dpi speed sensitivity tracking"),
        .init(id: .scrollDirection, tab: .mouse, title: "滚轮方向和 Windows 一致",
              keywords: "自然滚动 反向 滚轮 natural reverse wheel direction"),
        .init(id: .linearScroll, tab: .mouse, title: "按行滚动",
              keywords: "滚动加速 平滑 滚轮 smooth scroll acceleration wheel"),
        .init(id: .scrollLines, tab: .mouse, title: "每格滚动",
              keywords: "行数 滚动速度 lines notch scroll speed"),
        .init(id: .perMouse, tab: .mouse, title: "按鼠标单独设置",
              keywords: "多个鼠标 每个鼠标 设备 multiple mice device"),
        .init(id: .sideButtons, tab: .mouse, title: "侧键前进、后退",
              keywords: "侧键 第4键 第5键 back forward side buttons"),
        .init(id: .ctrlWheelZoom, tab: .mouse, title: "Ctrl+滚轮缩放",
              keywords: "缩放 放大 缩小 zoom"),

        .init(id: .clipboardEnabled, tab: .clipboard, title: "剪贴板历史",
              keywords: "win+v clipboard history 历史 复制记录"),
        .init(id: .maxItems, tab: .clipboard, title: "最多保存",
              keywords: "数量 条数 上限 limit count"),
        .init(id: .recordImages, tab: .clipboard, title: "记录图片",
              keywords: "截图 图片 images screenshots"),
        .init(id: .clipboardPrivacy, tab: .clipboard, title: "只保存在这台电脑上",
              keywords: "隐私 本地 联网 账号 密码 privacy local password"),
        .init(id: .showInFinder, tab: .clipboard, title: "在 Finder 中显示",
              keywords: "文件夹 位置 folder location"),
        .init(id: .clearHistory, tab: .clipboard, title: "清空历史…",
              keywords: "删除 清除 clear delete erase"),

        .init(id: .grantAll, tab: .general, title: "一键授权",
              keywords: "权限 授权 permissions grant access"),
        .init(id: .accessibility, tab: .general, title: "辅助功能",
              keywords: "accessibility 设备控制和数据访问 device control 权限 permission"),
        .init(id: .inputMonitoring, tab: .general, title: "输入监控",
              keywords: "input monitoring 权限 permission"),
        .init(id: .pasteboardPermission, tab: .general, title: "读取剪贴板",
              keywords: "粘贴 始终允许 paste always allow 权限 permission"),
        .init(id: .relaunch, tab: .general, title: "重新启动 Win顺",
              keywords: "重启 restart relaunch"),
        .init(id: .launchAtLogin, tab: .general, title: "登录时自动启动",
              keywords: "开机 启动 自启 login startup boot"),
        .init(id: .language, tab: .general, title: "语言",
              keywords: "language english chinese 中文 英文 简体"),
        .init(id: .version, tab: .general, title: "版本",
              keywords: "version 关于 about 更新 update"),

        .init(id: .works, tab: .gleaning, title: "拾穗计划",
              keywords: "作品 开源 作者 lingcore projects author gleaning"),
        .init(id: .feedback, tab: .gleaning, title: "您的建议非常重要",
              keywords: "反馈 建议 邮箱 联系 feedback email contact"),
    ]

    static func search(_ query: String) -> [SettingsItem] {
        all.map { ($0, $0.score(query)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

// MARK: - 跳到某一项

extension View {
    /// 设置里能被搜到的一行：搜索结果点过来时滚到这里，闪一下高亮。
    /// 传 nil 时什么也不做（同一组设置出现在好几处时，只让第一处能被搜到）。
    @ViewBuilder
    func settingsAnchor(_ id: SettingsItem.ID?) -> some View {
        if let id { modifier(SettingsAnchor(id: id)) } else { self }
    }
}

private struct SettingsAnchor: ViewModifier {
    let id: SettingsItem.ID
    @EnvironmentObject private var selection: SettingsSelection

    func body(content: Content) -> some View {
        content
            .id(id)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(selection.highlight == id ? 0.18 : 0))
                    .padding(-6)
                    .animation(.easeOut(duration: 0.3), value: selection.highlight)
            )
    }
}

/// 把设置页的 Form 包起来：搜索结果要求跳到某一项时滚过去。
struct SearchableForm<Content: View>: View {
    @EnvironmentObject private var selection: SettingsSelection
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .onAppear { reveal(proxy) }
                .onChange(of: selection.highlight) { reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = selection.highlight else { return }
        // 页面刚换过来时布局还没完成，等一下再滚
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

// MARK: - 搜索框

/// 系统的搜索框：带放大镜和清除按钮。回车打开第一个结果，Esc 清空。
struct SettingsSearchField: NSViewRepresentable {
    @ObservedObject var selection: SettingsSelection
    /// 在“拾穗”页：不画系统的边框和底色，由外面铺一层跟场景同色调的底
    var warm = false
    let onSubmit: () -> Void

    /// ⌘F 时让它获得焦点
    static weak var current: NSSearchField?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = L("搜索设置")
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        field.controlSize = .large
        Self.current = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != selection.query { field.stringValue = selection.query }
        if field.isBezeled == warm {
            field.isBezeled = !warm
            field.drawsBackground = !warm
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField

        init(_ parent: SettingsSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            parent.selection.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.selection.query = ""
                return false
            default:
                return false
            }
        }
    }
}

/// 侧栏里的搜索结果。
struct SettingsSearchResults: View {
    @ObservedObject var selection: SettingsSelection
    let results: [SettingsItem]
    let warm: Bool
    let palette: WarmPalette
    let open: (SettingsItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if results.isEmpty {
                Text(L("没有找到相关设置"))
                    .font(.callout)
                    .foregroundStyle(warm ? palette.inkSoft : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
            ForEach(results) { item in
                let selected = selection.opened == item.id
                Button { open(item) } label: {
                    HStack(spacing: 8) {
                        IconBadge(symbol: item.tab.symbol, tint: item.tab.tint, size: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.localizedTitle)
                                .lineLimit(1)
                            Text(item.tab.title)
                                .font(.caption)
                                .opacity(0.7)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selected ? Color.white : (warm ? palette.ink : Color.primary))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? (warm ? AnyShapeStyle(palette.accent.gradient) : AnyShapeStyle(Color.accentColor))
                                  : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
