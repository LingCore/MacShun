// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct FileSearchTypeCapsule: View {
    @ObservedObject var model: FileSearchModel
    static let height: CGFloat = 36
    private let inset: CGFloat = 5

    var body: some View {
        let shape = Capsule(style: .continuous)
        ViewThatFits(in: .horizontal) {
            chips(withSymbols: true)
            chips(withSymbols: false)
            ScrollView(.horizontal) { chips(withSymbols: true) }
                .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, inset)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background { VisualEffectBackground().clipShape(shape) }
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("类型"))
    }

    private func chips(withSymbols: Bool) -> some View {
        let options = model.panelOptions
        let chipHeight = Self.height - 2 * inset
        return HStack(spacing: 3) {
            ForEach(FileSearchKind.allCases, id: \.self) { kind in
                let selected = options.selects(kind)
                Button {
                    model.toggleFileKind(kind, inCompactStrip: true)
                } label: {
                    HStack(spacing: 4) {
                        if withSymbols && kind != .any {
                            Image(systemName: kind.symbol).font(.system(size: 11))
                        }
                        Text(kind == .any ? L("不限") : kind.title)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: chipHeight)
                }
                .buttonStyle(.searchFilter(selected: selected, tinted: kind != .any, radius: chipHeight / 2))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct FileSearchPanelControls: View {
    @ObservedObject var model: FileSearchModel
    let onTop: Bool
    let canShowSidebar: Bool
    private let rowHeight: CGFloat = 25

    var body: some View {
        Group {
            if onTop { strip } else { sidebar }
        }
        .background(Color.primary.opacity(0.035))
        .disabled(model.effectiveScope == .system)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(L("筛选")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    tools
                }
                .padding(.leading, 8)
                .padding(.bottom, 4)

                VStack(spacing: 2) {
                    ForEach(FileSearchKind.allCases, id: \.self) { typeButton($0) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("类型"))
                segmentDivider
                dateMenu
                sizeMenu
                locationMenu
                segmentDivider
                ForEach(model.savedSearches.items) { saved in savedButton(saved) }
                if model.canSaveFilters {
                    Button(action: model.onSaveFilters) { rowLabel(L("保存当前筛选…"), symbol: "plus") }
                        .buttonStyle(.searchFilter(selected: false, tinted: false))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
    }

    private var strip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(FileSearchKind.allCases, id: \.self) { typeButton($0) }
                    Divider().frame(height: 17).padding(.horizontal, 3)
                    dateMenu
                    sizeMenu
                    locationMenu
                    if model.canSaveFilters || !model.savedSearches.items.isEmpty { savedMenu }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            tools
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    private var tools: some View {
        HStack(spacing: 3) {
            if model.hasPanelFilters {
                tool("arrow.counterclockwise", label: L("清除筛选"), action: model.clearPanelFilters)
            }
            if canShowSidebar {
                tool(onTop ? "sidebar.left" : "rectangle.topthird.inset.filled",
                     label: onTop ? L("筛选放到左侧") : L("筛选放到顶部")) {
                    model.filtersOnTop.toggle()
                    model.focusSearch()
                }
            }
        }
    }

    private func tool(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
        }
        .buttonStyle(.searchPanelTool())
        .accessibilityLabel(label)
        .help(label)
    }

    private var segmentDivider: some View { Divider().padding(.horizontal, 6).padding(.vertical, 4) }

    private func typeButton(_ kind: FileSearchKind) -> some View {
        let selected = model.appliedPanelOptions.selects(kind)
        let title = kind == .any ? L("所有类型") : kind.title
        return Button {
            model.toggleFileKind(kind)
        } label: {
            rowLabel(title, symbol: kind.symbol, checked: !onTop && selected && kind != .any)
        }
        .buttonStyle(.searchFilter(selected: selected, tinted: kind != .any))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var dateMenu: some View {
        let choice = model.panelOptions.modified
        return filterMenu(L("修改时间"), value: choice == .any ? L("不限") : choice.title,
                          symbol: "clock", active: choice != .any) {
            FileSearchModified.allCases.map { selection in
                choiceItem(selection == .any ? L("不限") : selection.title, checked: selection == choice) {
                    if selection == .custom { model.onEditBounds(.date) }
                    else { model.panelOptions.modified = selection }
                }
            }
        }
    }

    private var sizeMenu: some View {
        let choice = model.panelOptions.size
        return filterMenu(L("大小"), value: choice.title, symbol: "ruler", active: choice != .any) {
            FileSearchSize.allCases.map { selection in
                choiceItem(selection.title, checked: selection == choice) {
                    if selection == .custom { model.onEditBounds(.size) }
                    else { model.panelOptions.size = selection }
                }
            }
        }
    }

    private var locationMenu: some View {
        let path = model.filterFolder?.path
        let title = model.folder == nil ? L("所有目录") : L("当前文件夹")
        let name = path.map { $0 == "/" ? "/" : ($0 as NSString).lastPathComponent }
        return filterMenu(L("目录"), value: name ?? L("不限"), symbol: "folder", active: path != nil, help: path) {
            var items = [choiceItem(title, checked: path == nil) { model.setFilterFolder(nil) }]
            items += model.indexedLocations.map { location in
                choiceItem(location.name, checked: path == location.path) { model.setFilterFolder(location.path) }
            }
            if let name, !model.indexedLocations.contains(where: { $0.path == path }) {
                let item = choiceItem(name, checked: true) {}
                item.isEnabled = false
                items.append(item)
            }
            items.append(.separator())
            items.append(ActionMenuItem(L("只搜这一次…"), handler: model.onChooseFolder))
            if let path = path ?? model.folder?.path, model.selectedFolderIsIndexed == false {
                items.append(ActionMenuItem(L("加入搜索范围")) { model.onAddLocation(path) })
            }
            return items
        }
    }

    private var savedMenu: some View {
        filterMenu(L("常用筛选"), value: nil, symbol: "bookmark", active: false) {
            var items: [NSMenuItem] = model.savedSearches.items.map { saved in
                ActionMenuItem(saved.name) { model.applySavedFilters(saved) }
            }
            if model.canSaveFilters {
                items.append(ActionMenuItem(L("保存当前筛选…"), handler: model.onSaveFilters))
            }
            if !model.savedSearches.items.isEmpty {
                let item = NSMenuItem(title: L("移除已保存筛选"), action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: item.title)
                submenu.items = model.savedSearches.items.map { saved in
                    ActionMenuItem(saved.name) { model.removeSavedFilters(saved.id) }
                }
                item.submenu = submenu
                items.append(item)
            }
            return items
        }
    }

    private func savedButton(_ saved: SavedFileSearch) -> some View {
        let selected = model.appliedPanelOptions == saved.options && model.searchFolder?.path == saved.folder
        return Button {
            model.applySavedFilters(saved)
        } label: {
            rowLabel(saved.name, symbol: "bookmark", checked: selected)
        }
        .buttonStyle(.searchFilter(selected: selected, tinted: true))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(L("移除已保存筛选"), role: .destructive) { model.removeSavedFilters(saved.id) }
        }
    }

    private func choiceItem(_ title: String, checked: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title, handler: action)
        item.state = checked ? .on : .off
        return item
    }

    private func filterMenu(_ title: String, value: String?, symbol: String, active: Bool, help: String? = nil,
                            items: @escaping () -> [NSMenuItem]) -> some View {
        HoverReader { hovering in
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).frame(width: 15)
                Text(title).fixedSize()
                if !onTop { Spacer(minLength: 4) }
                if let value {
                    Text(value).foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: onTop ? 115 : 84, alignment: .trailing)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minHeight: onTop ? rowHeight : 28)
            .background(Color.primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            .overlay { SearchFilterMenuButton(title: title, value: value, help: help ?? title, items: items) }
        }
    }

    private func rowLabel(_ title: String, symbol: String, checked: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 15)
            Text(title).lineLimit(1).truncationMode(.middle)
            if !onTop { Spacer(minLength: 0) }
            if checked { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor) }
        }
        .padding(.horizontal, 7)
        .frame(height: rowHeight)
    }
}

/// AppKit supplies menu tracking and accessibility while the SwiftUI label controls the whole row's layout.
private struct SearchFilterMenuButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let value: String?
    let help: String
    let items: () -> [NSMenuItem]

    func makeNSView(context: Context) -> Trigger {
        let button = Trigger()
        button.isTransparent = true
        button.target = button
        button.action = #selector(Trigger.openMenu)
        button.setAccessibilityRole(.menuButton)
        return button
    }

    func updateNSView(_ button: Trigger, context: Context) {
        button.items = items
        button.isEnabled = isEnabled
        button.toolTip = help
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(value)
    }

    final class Trigger: NSButton {
        var items: () -> [NSMenuItem] = { [] }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        @objc func openMenu() {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.items = items()
            menu.minimumWidth = bounds.width
            let below = isFlipped ? bounds.maxY + 3 : bounds.minY - 3
            menu.popUp(positioning: nil, at: CGPoint(x: bounds.minX, y: below), in: self)
        }
    }
}

private struct SearchFilterStyle: ButtonStyle {
    let selected: Bool
    let tinted: Bool
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(selected ? (tinted ? Color.accentColor.opacity(0.19) : Color.primary.opacity(0.10))
                              : Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == SearchPanelToolStyle {
    static func searchPanelTool(active: Bool = false) -> Self { Self(active: active) }
}

struct SearchPanelToolStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        HoverReader { hovering in
            configuration.label
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.accentColor.opacity(0.15)
                              : Color.primary.opacity(configuration.isPressed ? 0.13 : hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
    }
}

private extension ButtonStyle where Self == SearchFilterStyle {
    static func searchFilter(selected: Bool, tinted: Bool, radius: CGFloat = 5) -> Self {
        Self(selected: selected, tinted: tinted, radius: radius)
    }
}
